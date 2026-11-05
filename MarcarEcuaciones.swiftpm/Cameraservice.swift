import Foundation
@preconcurrency import AVFoundation

// Envuelve la sesión para poder compartirla con la vista previa (AVCaptureSession no es Sendable)
nonisolated final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
}

// Delegate de captura. Entrega Data (Sendable) en lugar de AVCapturePhoto.
nonisolated private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let onPhoto: @Sendable (Result<Data, Error>) -> Void
    private let onFinish: @Sendable () -> Void

    init(onPhoto: @escaping @Sendable (Result<Data, Error>) -> Void,
         onFinish: @escaping @Sendable () -> Void) {
        self.onPhoto = onPhoto
        self.onFinish = onFinish
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            onPhoto(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            onPhoto(.failure(CameraError.invalidPhoto))
            return
        }
        onPhoto(.success(data))
    }

    // Llamado al terminar toda la captura: aquí ya se puede soltar el delegate
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        onFinish()
    }
}

actor CameraService {
    // Cola serial propia: startRunning() y stopRunning() son bloqueantes
    // y no deben ejecutarse en el pool cooperativo de Swift.
    private let sessionQueue = DispatchSerialQueue(label: "camera.session.queue")
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        sessionQueue.asUnownedSerialExecutor()
    }

    // nonisolated para que la vista previa pueda leer la sesión desde el hilo principal
    nonisolated let sessionBox = CaptureSessionBox()

    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false
    private var activeDelegate: PhotoCaptureDelegate?

    private var session: AVCaptureSession { sessionBox.session }

    func configureSession() async throws {
        if !isConfigured {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw CameraError.accessDenied
            }
            // Tras el await otra llamada pudo configurar la sesión; se revisa dentro
            try configureInputsAndOutputs()
        }

        if !session.isRunning {
            session.startRunning()
        }
    }

    private func configureInputsAndOutputs() throws {
        guard !isConfigured else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)

        guard session.canAddInput(input),
              session.canAddOutput(photoOutput) else {
            throw CameraError.cannotConfigure
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        isConfigured = true
    }

    func capturePhoto() async throws -> Data {
        guard activeDelegate == nil else { throw CameraError.captureInProgress }

        // Sin esto la foto sale en orientación horizontal aunque el teléfono esté en vertical
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let delegate = PhotoCaptureDelegate(
                onPhoto: { result in
                    continuation.resume(with: result)
                },
                onFinish: { [weak self] in
                    Task { await self?.clearDelegate() }
                }
            )
            // AVCapturePhotoOutput guarda el delegate de forma débil, hay que retenerlo
            activeDelegate = delegate
            photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }

    func stopSession() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func clearDelegate() {
        activeDelegate = nil
    }
}
