import CoreGraphics
import Foundation

/// Región de interés (una ecuación) dentro de la imagen rectificada.
/// `normalizedBounds` usa coordenadas normalizadas (0...1) con origen arriba-izquierda.
struct EquationROI: Identifiable, Equatable, Sendable {
    let id: UUID
    let normalizedBounds: CGRect

    init(id: UUID = UUID(), normalizedBounds: CGRect) {
        self.id = id
        self.normalizedBounds = normalizedBounds
    }

    /// Convierte a píxeles absolutos de la CGImage (origen arriba-izquierda),
    /// redondeando hacia afuera y sin salirse de la imagen.
    func toPixelCoordinates(imageSize: CGSize) -> CGRect {
        let rect = CGRect(
            x: normalizedBounds.minX * imageSize.width,
            y: normalizedBounds.minY * imageSize.height,
            width: normalizedBounds.width * imageSize.width,
            height: normalizedBounds.height * imageSize.height
        )
        return rect.integral.intersection(CGRect(origin: .zero, size: imageSize))
    }
}
