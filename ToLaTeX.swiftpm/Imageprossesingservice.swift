import CoreImage
import CoreImage.CIFilterBuiltins

enum ImageProcessingError: Error, LocalizedError {
    case invalidImage
    case invalidPolygon
    case transformFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: "La imagen no es válida."
        case .invalidPolygon: "El recuadro no es válido. Ajusta las esquinas."
        case .transformFailed: "No se pudo recortar la imagen. Intenta de nuevo."
        }
    }
}

/// Aplica el recorte y la corrección de perspectiva (homografía) en segundo plano.
actor ImageProcessingService {
    private lazy var context = CIContext()

    func applyHomography(to image: CIImage, polygon: PerspectivePolygon) async throws -> CIImage {
        guard polygon.isValid else { throw ImageProcessingError.invalidPolygon }

        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { throw ImageProcessingError.invalidImage }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = imagePoint(polygon.topLeft, in: extent)
        filter.topRight = imagePoint(polygon.topRight, in: extent)
        filter.bottomRight = imagePoint(polygon.bottomRight, in: extent)
        filter.bottomLeft = imagePoint(polygon.bottomLeft, in: extent)

        guard let output = filter.outputImage,
              !output.extent.isEmpty, !output.extent.isInfinite else {
            throw ImageProcessingError.transformFailed
        }

        // Renderizamos aquí (en el actor) para que el trabajo pesado no ocurra
        // luego en el hilo principal al mostrar o inferir.
        guard let cgImage = context.createCGImage(output, from: output.extent) else {
            throw ImageProcessingError.transformFailed
        }
        return CIImage(cgImage: cgImage)
    }

    /// Normalizado (origen arriba-izquierda) → píxeles de CIImage (origen abajo-izquierda).
    private func imagePoint(_ p: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + p.x * extent.width,
                y: extent.minY + (1 - p.y) * extent.height)
    }
}

