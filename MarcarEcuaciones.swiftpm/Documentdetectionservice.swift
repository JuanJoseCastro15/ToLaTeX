import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

enum DocumentDetectionError: Error, LocalizedError {
    case invalidImage
    case detectionFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "La foto está corrupta o no se pudo leer. Vuelve a tomar otra foto."
        case .detectionFailed:
            "No se encontró la hoja en la foto; puede estar mal tomada o poco clara. Vuelve a tomar otra foto o marca el recuadro manualmente."
        }
    }
}

/// Localiza la hoja en la foto: filtro + umbral (CoreImage) y búsqueda del
/// cuadrilátero (Vision). Corre en su propio actor, fuera del hilo principal.
actor DocumentDetectionService {

    func detectDocument(in image: CIImage) async throws -> PerspectivePolygon {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width > 1, extent.height > 1 else {
            throw DocumentDetectionError.invalidImage
        }

        // Trabajamos con origen en (0,0).
        let base = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                           y: -extent.origin.y))

        // 1.º intento: imagen binarizada (la hoja destaca del fondo).
        // 2.º intento: imagen original, por si la hoja y el fondo son muy parecidos.
        let candidates = [applyThresholdAndFilter(to: base), base]
        for candidate in candidates {
            try Task.checkCancellation()
            if let polygon = try? extractCorners(from: candidate) {
                return polygon
            }
        }
        throw DocumentDetectionError.detectionFailed
    }

    // MARK: - Privado

    /// Escala de grises + contraste + desenfoque (borra el texto de las ecuaciones
    /// para que solo quede la silueta de la hoja) + umbral de Otsu.
    private func applyThresholdAndFilter(to image: CIImage) -> CIImage {
        let extent = image.extent

        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.saturation = 0
        controls.contrast = 1.3
        let gray = controls.outputImage ?? image

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = gray.clampedToExtent()
        blur.radius = Float(max(extent.width, extent.height) * 0.004)
        let smooth = (blur.outputImage ?? gray).cropped(to: extent)

        let otsu = CIFilter.colorThresholdOtsu()
        otsu.inputImage = smooth
        return otsu.outputImage ?? smooth
    }

    /// Busca rectángulos y se queda con el de mayor área; los objetos pequeños
    /// fuera de la hoja (ruido) quedan descartados.
    private func extractCorners(from image: CIImage) throws -> PerspectivePolygon {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.25
        request.minimumConfidence = 0.5
        request.quadratureTolerance = 30
        request.maximumObservations = 5

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])

        guard let best = request.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else {
            throw DocumentDetectionError.detectionFailed
        }

        // Vision usa origen abajo-izquierda; el modelo usa arriba-izquierda.
        func convert(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, 0), 1), y: min(max(1 - p.y, 0), 1))
        }
        let polygon = PerspectivePolygon(
            topLeft: convert(best.topLeft),
            topRight: convert(best.topRight),
            bottomRight: convert(best.bottomRight),
            bottomLeft: convert(best.bottomLeft)
        )
        guard polygon.isValid else { throw DocumentDetectionError.detectionFailed }
        return polygon
    }
}
