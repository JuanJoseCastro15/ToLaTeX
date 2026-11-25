import CoreGraphics
import Foundation

protocol ROICropServiceProtocol: Sendable {
    func cropAndNormalizeRegions(image: CGImage, rois: [EquationROI]) async throws -> [CGImage]
    func stackedPreview(image: CGImage, rois: [EquationROI], gap: Int) async throws -> CGImage
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

    /// Tamaño de entrada del modelo en píxeles (ancho × alto): el mismo 384×1152
    /// que usaba el código de la cámara. Cámbialo aquí si tu modelo espera otro.
    static let defaultTargetSize = CGSize(width: 384, height: 1152)

    private let targetSize: CGSize

    init(targetSize: CGSize = ROICropService.defaultTargetSize) {
        self.targetSize = targetSize
    }

    /// Un recorte por ecuación, ajustado al tamaño de entrada del modelo.
    func cropAndNormalizeRegions(image: CGImage, rois: [EquationROI]) async throws -> [CGImage] {
        try cropRegions(image: image, rois: rois).map { try padToTargetSize($0) }
    }

    /// Vista previa: los recortes sin relleno, uno debajo de otro y separados por
    /// `gap` píxeles blancos (centrados en horizontal).
    func stackedPreview(image: CGImage, rois: [EquationROI], gap: Int) async throws -> CGImage {
        let crops = try cropRegions(image: image, rois: rois)
        let gap = max(gap, 0)

        let width = crops.map(\.width).max() ?? 1
        let height = crops.reduce(0) { $0 + $1.height } + gap * (crops.count - 1)

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
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high

        // CGContext tiene el origen abajo-izquierda; se dibuja de arriba hacia abajo.
        var top = 0
        for crop in crops {
            let rect = CGRect(x: (width - crop.width) / 2,
                              y: height - top - crop.height,
                              width: crop.width,
                              height: crop.height)
            context.draw(crop, in: rect)
            top += crop.height + gap
        }

        guard let output = context.makeImage() else { throw ROICropError.paddingFailed }
        return output
    }

    /// Recorta cada ROI de la imagen base, sin relleno.
    private func cropRegions(image: CGImage, rois: [EquationROI]) throws -> [CGImage] {
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
            results.append(cropped)
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
