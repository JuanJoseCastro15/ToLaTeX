import CoreGraphics

/// Cuadrilátero que delimita la hoja con las ecuaciones.
///
/// Las coordenadas son NORMALIZADAS (0...1) con origen en la esquina superior
/// izquierda de la imagen, el mismo sistema que usa SwiftUI. Así el polígono no
/// depende de la resolución de la foto ni del tamaño en pantalla.
struct PerspectivePolygon: Equatable, Sendable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    private static let minVertexDistance: CGFloat = 0.02
    private static let minArea: CGFloat = 0.01
    private static let crossEpsilon: CGFloat = 1e-6

    /// Rectángulo inicial para el ajuste manual.
    static let defaultInset = PerspectivePolygon(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomRight: CGPoint(x: 0.9, y: 0.9),
        bottomLeft: CGPoint(x: 0.1, y: 0.9)
    )

    /// Vértices en sentido horario: 0 = TL, 1 = TR, 2 = BR, 3 = BL.
    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// `true` si es convexo, sin aristas cruzadas, sin vértices superpuestos,
    /// con las esquinas en su orden correcto y dentro de la imagen.
    var isValid: Bool {
        let pts = corners
        let bounds: ClosedRange<CGFloat> = 0...1

        guard pts.allSatisfy({ bounds.contains($0.x) && bounds.contains($0.y) }) else { return false }

        // Vértices superpuestos
        for i in 0..<4 {
            for j in (i + 1)..<4
            where hypot(pts[i].x - pts[j].x, pts[i].y - pts[j].y) < Self.minVertexDistance {
                return false
            }
        }

        // Convexidad: con y hacia abajo, un cuadrilátero horario TL→TR→BR→BL
        // tiene todos los productos cruzados positivos. Un "moño" (aristas
        // cruzadas) o esquinas intercambiadas producen signos distintos o negativos.
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4], c = pts[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if cross <= Self.crossEpsilon { return false }
        }

        return area >= Self.minArea
    }

    /// Rectángulo delimitador (bounding box) en coordenadas normalizadas.
    func toNormalizedRect() -> CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Devuelve una copia con el vértice `index` movido a `point`.
    func replacingCorner(at index: Int, with point: CGPoint) -> PerspectivePolygon {
        switch index {
        case 0: PerspectivePolygon(topLeft: point, topRight: topRight, bottomRight: bottomRight, bottomLeft: bottomLeft)
        case 1: PerspectivePolygon(topLeft: topLeft, topRight: point, bottomRight: bottomRight, bottomLeft: bottomLeft)
        case 2: PerspectivePolygon(topLeft: topLeft, topRight: topRight, bottomRight: point, bottomLeft: bottomLeft)
        case 3: PerspectivePolygon(topLeft: topLeft, topRight: topRight, bottomRight: bottomRight, bottomLeft: point)
        default: self
        }
    }

    /// Área normalizada (fórmula del polígono de Gauss).
    private var area: CGFloat {
        let p = corners
        var sum: CGFloat = 0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}
