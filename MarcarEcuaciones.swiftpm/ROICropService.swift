import CoreGraphics
import Foundation

protocol ROICropServiceProtocol: Sendable {
    func cropAndNormalizeRegions(image: CGImage, rois: [EquationROI]) async throws -> [CGImage]
}

enum ROICropError: Error, LocalizedError {
    case noRegions
    case cropFailed
    case paddingFailed

    var errorDescription: String? {
        switch self {
        case .noRegions: "Marca al menos una ecuación antes de confirmar."
        case .cropFailed: "No se pudo recortar una de las ecuaciones. Ajusta su rectángulo e inténtalo de nuevo."
        case .paddingFailed: "No se pudo preparar la imagen de una ecuación."
        }
    }
}

/// Recorta cada ROI de la imagen base y la ajusta (sin deformar, con fondo blanco)
/// al tamaño de entrada del modelo.
actor ROICropService: ROICropServiceProtocol {

    /// Tamaño de entrada del modelo en píxeles. VERIFÍCALO contra la configuración
    /// de tu versión de UniMERNet / tu conversión a Core ML.
    static let defaultTargetSize = CGSize(width: 1152, height: 384)

    private let targetSize: CGSize

    init(targetSize: CGSize = ROICropService.defaultTargetSize) {
        self.targetSize = targetSize
    }

    func cropAndNormalizeRegions(image: CGImage, rois: [EquationROI]) async throws -> [CGImage] {
        guard !rois.isEmpty else { throw ROICropError.noRegions }

        let imageSize = CGSize(width: image.width, height: image.height)
        var results: [CGImage] = []
        results.reserveCapacity(rois.count)

        for roi in rois {
            try Task.checkCancellation()
            let pixelRect = roi.toPixelCoordinates(imageSize: imageSize)
            guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1,
                  let cropped = image.cropping(to: pixelRect) else {
                throw ROICropError.cropFailed
            }
            results.append(try padToTargetSize(cropped))
        }
        return results
    }

    /// Escala conservando la proporción y centra sobre un lienzo blanco.
    private func padToTargetSize(_ image: CGImage) throws -> CGImage {
        let width = Int(targetSize.width), height = Int(targetSize.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ROICropError.paddingFailed }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: targetSize))

        let scale = min(targetSize.width / CGFloat(image.width),
                        targetSize.height / CGFloat(image.height))
        let drawSize = CGSize(width: CGFloat(image.width) * scale,
                              height: CGFloat(image.height) * scale)
        let drawRect = CGRect(x: (targetSize.width - drawSize.width) / 2,
                              y: (targetSize.height - drawSize.height) / 2,
                              width: drawSize.width,
                              height: drawSize.height)

        context.interpolationQuality = .high
        context.draw(image, in: drawRect)

        guard let output = context.makeImage() else { throw ROICropError.paddingFailed }
        return output
    }
}
