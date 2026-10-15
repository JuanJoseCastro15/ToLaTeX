import SwiftUI
@preconcurrency import AVFoundation
import ImageIO
import Observation

// Requiere iOS 18+ (Swift 6) y la clave NSCameraUsageDescription en Info.plist.
// Pruébalo en un iPhone real: el simulador no tiene cámara y mostrará "No se encontró una cámara".

// MARK: - Estado

nonisolated enum CameraSessionState: Equatable {
    case idle
    case configuring
    case running
    case capturing
    case reviewing
    case preparing
    case processing
    case failed(String)
}

nonisolated enum CameraError: LocalizedError {
    case accessDenied
    case noCamera
    case cannotConfigure
    case captureInProgress
    case invalidPhoto
    case pixelBufferFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Sin permiso para usar la cámara."
        case .noCamera: return "No se encontró una cámara disponible."
        case .cannotConfigure: return "No se pudo configurar la sesión de cámara."
        case .captureInProgress: return "Ya hay una captura en curso."
        case .invalidPhoto: return "No se pudo leer la foto capturada."
        case .pixelBufferFailed: return "No se pudo preparar la imagen."
        }
    }
}

// MARK: - Utilidad compartida

// Decodifica los datos de la foto aplicando su orientación EXIF
nonisolated private func decodeImage(from data: Data, maxPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

// MARK: - CameraService

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

// MARK: - ImagePreprocessingService

actor ImagePreprocessingService {
    static let targetWidth = 384
    static let targetHeight = 1152

    // Vista previa reducida; se decodifica fuera del hilo principal
    func makePreview(from data: Data, maxPixelSize: Int) -> sending CGImage? {
        decodeImage(from: data, maxPixelSize: maxPixelSize)
    }

    func prepareForPipeline(from data: Data) throws -> sending CVPixelBuffer {
        guard let image = decodeImage(from: data, maxPixelSize: 2048) else {
            throw CameraError.invalidPhoto
        }

        let width = Self.targetWidth
        let height = Self.targetHeight

        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attributes, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw CameraError.pixelBufferFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw CameraError.pixelBufferFailed
        }

        // Fondo blanco y la imagen ajustada al lienzo sin deformarse
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let scale = min(CGFloat(width) / CGFloat(image.width),
                        CGFloat(height) / CGFloat(image.height))
        let drawWidth = CGFloat(image.width) * scale
        let drawHeight = CGFloat(image.height) * scale
        let rect = CGRect(x: (CGFloat(width) - drawWidth) / 2,
                          y: (CGFloat(height) - drawHeight) / 2,
                          width: drawWidth,
                          height: drawHeight)
        context.draw(image, in: rect)

        return buffer
    }
}

// MARK: - CameraViewModel

@MainActor
@Observable
final class CameraViewModel {
    var sessionState: CameraSessionState = .idle
    var capturedPhotoPreview: CGImage?
    private(set) var pixelBuffer: CVPixelBuffer?

    @ObservationIgnored let cameraService = CameraService()
    @ObservationIgnored private let preprocessingService = ImagePreprocessingService()
    @ObservationIgnored private var capturedPhotoData: Data?

    func startCameraSession() async {
        sessionState = .configuring
        do {
            try await cameraService.configureSession()
            sessionState = .running
        } catch {
            sessionState = .failed(error.localizedDescription)
        }
    }

    func stopCameraSession() {
        Task { await cameraService.stopSession() }
    }

    func takePhoto() async {
        guard sessionState == .running else { return }
        sessionState = .capturing
        do {
            let data = try await cameraService.capturePhoto()
            guard let preview = await preprocessingService.makePreview(from: data,
                                                                       maxPixelSize: 1280) else {
                throw CameraError.invalidPhoto
            }
            capturedPhotoData = data
            capturedPhotoPreview = preview
            sessionState = .reviewing
        } catch {
            sessionState = .failed(error.localizedDescription)
        }
    }

    func confirmPhoto() async {
        guard sessionState == .reviewing, let data = capturedPhotoData else { return }
        sessionState = .preparing
        do {
            pixelBuffer = try await preprocessingService.prepareForPipeline(from: data)
            sessionState = .processing
        } catch {
            sessionState = .failed(error.localizedDescription)
        }
    }

    func retakePhoto() {
        capturedPhotoData = nil
        capturedPhotoPreview = nil
        pixelBuffer = nil
        sessionState = .running
    }
}

// MARK: - Vista previa de cámara

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

// MARK: - CameraView

struct CameraView: View {
    // El view model se crea una sola vez en CameraApp y se inyecta aquí
    let viewModel: CameraViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                CameraPreview(session: viewModel.cameraService.sessionBox.session)
                    .ignoresSafeArea()

                if let preview = viewModel.capturedPhotoPreview {
                    Color.black.ignoresSafeArea()
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .scaledToFit()
                }

                if viewModel.sessionState == .configuring || viewModel.sessionState == .preparing {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }

                VStack {
                    Spacer()
                    controls
                        .padding(.bottom, 32)
                }
            }
            .navigationDestination(isPresented: processingBinding) {
                ProcessingView(pixelBuffer: viewModel.pixelBuffer)
            }
        }
        .task { await viewModel.startCameraSession() }
        .onDisappear { viewModel.stopCameraSession() }
    }

    private var processingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.sessionState == .processing },
            set: { isActive in
                if !isActive { viewModel.retakePhoto() }
            }
        )
    }

    @ViewBuilder
    private var controls: some View {
        switch viewModel.sessionState {
        case .running, .capturing:
            Button {
                Task { await viewModel.takePhoto() }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(.white).frame(width: 62, height: 62)
                }
            }
            .disabled(viewModel.sessionState == .capturing)

        case .reviewing, .preparing:
            HStack(spacing: 24) {
                Button("Repetir") { viewModel.retakePhoto() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button("Confirmar Foto") {
                    Task { await viewModel.confirmPhoto() }
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(viewModel.sessionState == .preparing)

        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button("Reintentar") {
                    Task { await viewModel.startCameraSession() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

        default:
            EmptyView()
        }
    }
}

// MARK: - ProcessingView (marcador de posición)

// Reemplazar por la vista real que ejecuta la inferencia de UniMERNet
struct ProcessingView: View {
    let pixelBuffer: CVPixelBuffer?

    var body: some View {
        Text("Procesando…")
    }
}

#Preview {
    CameraView(viewModel: CameraViewModel())
}

// MARK: - App
// Si tu proyecto ya tiene un archivo con @main, borra este bloque y usa
// CameraView(viewModel: viewModel) dentro de tu WindowGroup.

@main
struct CameraApp: App {
    @State private var viewModel = CameraViewModel()

    var body: some Scene {
        WindowGroup {
            CameraView(viewModel: viewModel)
        }
    }
}
