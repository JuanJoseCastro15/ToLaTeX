import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class EquationSelectionViewModel {
    private(set) var equationROIs: [EquationROI] = []
    private(set) var activeROI: EquationROI?
    let baseFilteredImage: CGImage

    private(set) var isProcessing = false
    private(set) var errorMessage: String?

    private let cropService: any ROICropServiceProtocol
    private let onCropsReady: ([CGImage]) -> Void

    /// ROI existente que se está moviendo o redimensionando (nil si se dibuja una nueva).
    private var editingOriginal: EquationROI?

    private static let minSide: CGFloat = 0.02

    var canConfirm: Bool { !isProcessing && !equationROIs.isEmpty }

    /// - Parameter onCropsReady: punto de salida hacia el coordinador de navegación.
    init(
        baseFilteredImage: CGImage,
        cropService: any ROICropServiceProtocol = ROICropService(),
        onCropsReady: @escaping ([CGImage]) -> Void
    ) {
        self.baseFilteredImage = baseFilteredImage
        self.cropService = cropService
        self.onCropsReady = onCropsReady
    }

    /// Empieza a mover o redimensionar una ROI ya agregada.
    func beginEditingROI(id: UUID) {
        guard let roi = equationROIs.first(where: { $0.id == id }) else { return }
        editingOriginal = roi
        activeROI = roi
    }

    /// Actualiza en vivo la ROI que se está trazando o editando.
    func updateActiveROI(normalizedRect: CGRect) {
        let bounds = Self.clampedToUnit(normalizedRect)

        if let original = editingOriginal {
            let updated = EquationROI(id: original.id, normalizedBounds: bounds)
            activeROI = updated
            if let index = equationROIs.firstIndex(where: { $0.id == original.id }) {
                equationROIs[index] = updated
            }
        } else {
            activeROI = EquationROI(id: activeROI?.id ?? UUID(), normalizedBounds: bounds)
        }
    }

    /// Cierra el gesto: agrega la ROI nueva a la pila, o confirma la edición de una existente.
    func addROI(normalizedRect: CGRect) {
        let bounds = Self.clampedToUnit(normalizedRect)
        let isBigEnough = bounds.width >= Self.minSide && bounds.height >= Self.minSide
        defer {
            activeROI = nil
            editingOriginal = nil
        }

        if let original = editingOriginal {
            // Si quedó demasiado pequeña, se restaura la ROI original.
            let final = isBigEnough ? EquationROI(id: original.id, normalizedBounds: bounds) : original
            if let index = equationROIs.firstIndex(where: { $0.id == original.id }) {
                equationROIs[index] = final
            }
        } else if isBigEnough {
            equationROIs.append(EquationROI(id: activeROI?.id ?? UUID(), normalizedBounds: bounds))
        }
    }

    func undoLastROI() {
        activeROI = nil
        editingOriginal = nil
        guard !equationROIs.isEmpty else { return }
        equationROIs.removeLast()
    }

    func confirmSelection() async {
        guard canConfirm else { return }
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        do {
            let crops = try await cropService.cropAndNormalizeRegions(
                image: baseFilteredImage,
                rois: equationROIs
            )
            onCropsReady(crops)
        } catch is CancellationError {
            // La vista desapareció; no hay nada que mostrar.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private static func clampedToUnit(_ rect: CGRect) -> CGRect {
        let clipped = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull ? .zero : clipped
    }
}
