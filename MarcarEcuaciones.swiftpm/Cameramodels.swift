import CoreGraphics
import Foundation
import ImageIO

// MARK: - Estado

nonisolated enum CameraSessionState: Equatable {
    case idle
    case configuring
    case running
    case capturing
    case reviewing
    case preparing
    case processing   // la foto ya salió de la cámara hacia el recorte
    case failed(String)
}

nonisolated enum CameraError: LocalizedError {
    case accessDenied
    case noCamera
    case cannotConfigure
    case captureInProgress
    case invalidPhoto

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Sin permiso para usar la cámara."
        case .noCamera: return "No se encontró una cámara disponible."
        case .cannotConfigure: return "No se pudo configurar la sesión de cámara."
        case .captureInProgress: return "Ya hay una captura en curso."
        case .invalidPhoto: return "No se pudo leer la foto capturada."
        }
    }
}

// MARK: - Utilidad compartida

// Decodifica los datos de la foto aplicando su orientación EXIF
nonisolated func decodeImage(from data: Data, maxPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}
