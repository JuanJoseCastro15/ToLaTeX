import CoreGraphics
import Foundation

/// Decodifica las fotos fuera del hilo principal.
///
/// Ya no ajusta la foto a 384×1152: ese relleno se aplica a cada ecuación
/// después del recorte (ROICropService), no a la hoja completa.
actor ImagePreprocessingService {
    /// Resolución con la que la foto entra al flujo de recorte.
    static let workingMaxPixelSize = 4096

    // Vista previa reducida para la pantalla de revisión
    func makePreview(from data: Data, maxPixelSize: Int) -> sending CGImage? {
        decodeImage(from: data, maxPixelSize: maxPixelSize)
    }

    // Foto a resolución de trabajo, con la orientación EXIF ya aplicada
    func makeWorkingImage(from data: Data) -> sending CGImage? {
        decodeImage(from: data, maxPixelSize: Self.workingMaxPixelSize)
    }
}
