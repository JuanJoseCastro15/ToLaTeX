import CoreImage
import Observation
import UIKit

@MainActor
@Observable
final class CropViewModel {
    let inputImage: CIImage
    let previewImage: UIImage

    private(set) var detectedPolygon: PerspectivePolygon?
    private(set) var isProcessing = false
    private(set) var errorMessage: String?

    private let detectionService: DocumentDetectionService
    private let processingService: ImageProcessingService

    var canConfirm: Bool {
        !isProcessing && (detectedPolygon?.isValid ?? false)
    }

    init(
        inputImage: CIImage,
        detectionService: DocumentDetectionService = DocumentDetectionService(),
        processingService: ImageProcessingService = ImageProcessingService()
    ) {
        let extent = inputImage.extent
        let normalized: CIImage
        if extent.isEmpty || extent.isInfinite || extent.origin == .zero {
            normalized = inputImage
        } else {
            normalized = inputImage.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                                      y: -extent.origin.y))
        }
        self.inputImage = normalized
        self.previewImage = Self.makePreview(from: normalized)
        self.detectionService = detectionService
        self.processingService = processingService
    }

    /// Detección automática del polígono al cargar la pantalla.
    func detectDocumentBounds() async {
        guard !isProcessing, detectedPolygon == nil else { return }
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        do {
            detectedPolygon = try await detectionService.detectDocument(in: inputImage)
        } catch is CancellationError {
            // La vista desapareció; no hay nada que mostrar.
        } catch {
            detectedPolygon = nil
            errorMessage = error.localizedDescription
        }
    }

    /// `newLocation` está en coordenadas normalizadas (0...1, origen arriba-izquierda).
    func updateCorner(index: Int, newLocation: CGPoint) {
        guard let polygon = detectedPolygon, (0..<4).contains(index) else { return }
        let clamped = CGPoint(x: min(max(newLocation.x, 0), 1),
                              y: min(max(newLocation.y, 0), 1))
        // Se acepta aunque sea inválido para que el arrastre sea fluido;
        // `canConfirm` bloquea la confirmación y la vista lo pinta en rojo.
        detectedPolygon = polygon.replacingCorner(at: index, with: clamped)
    }

    /// Alternativa del caso de uso: el usuario marca el rectángulo a mano.
    func startManualSelection() {
        errorMessage = nil
        detectedPolygon = .defaultInset
    }

    /// SwiftUI no siempre dibuja un UIImage respaldado por CIImage, así que lo
    /// renderizamos a CGImage (reducido a `maxDimension` para que sea ligero).
    private static func makePreview(from image: CIImage, maxDimension: CGFloat = 2048) -> UIImage {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return UIImage() }
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else {
            return UIImage()
        }
        return UIImage(cgImage: cgImage)
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Recorta y corrige la perspectiva. Devuelve `nil` si falla (y fija `errorMessage`).
    func confirmAndCrop() async -> CIImage? {
        guard let polygon = detectedPolygon, polygon.isValid, !isProcessing else { return nil }
        isProcessing = true
        defer { isProcessing = false }

        do {
            return try await processingService.applyHomography(to: inputImage, polygon: polygon)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
