import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class CameraViewModel {
    var sessionState: CameraSessionState = .idle
    var capturedPhotoPreview: CGImage?

    @ObservationIgnored let cameraService = CameraService()
    @ObservationIgnored private let preprocessingService = ImagePreprocessingService()
    @ObservationIgnored private var capturedPhotoData: Data?

    func startCameraSession() async {
        // Al volver a la cámara no debe quedar la foto anterior encima
        resetCapture()
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

    /// Devuelve la foto a resolución de trabajo para pasarla al recorte (CropView).
    func confirmPhoto() async -> CGImage? {
        guard sessionState == .reviewing, let data = capturedPhotoData else { return nil }
        sessionState = .preparing

        guard let image = await preprocessingService.makeWorkingImage(from: data) else {
            sessionState = .failed(CameraError.invalidPhoto.localizedDescription)
            return nil
        }
        sessionState = .processing
        return image
    }

    func retakePhoto() {
        resetCapture()
        sessionState = .running
    }

    private func resetCapture() {
        capturedPhotoData = nil
        capturedPhotoPreview = nil
    }
}
