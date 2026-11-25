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

    /// Modal de confirmación para borrar todos los rectángulos (TX21).
    private(set) var showClearConfirmation = false
    /// Banner rojo "Sin recortes" (TX21).
    private(set) var showEmptyStateBanner = false

    /// ROI resaltada en morado, la que muestra el botón "Eliminar recorte" (TX24).
    private(set) var selectedROIID: UUID?
    /// ROI que se va a eliminar mientras se espera la confirmación (TX24).
    private(set) var roiPendingDeletion: EquationROI?
    private(set) var showDeleteConfirmation = false

    var selectedROI: EquationROI? {
        guard let selectedROIID else { return nil }
        return equationROIs.first { $0.id == selectedROIID }
    }

    private let cropService: any ROICropServiceProtocol
    private let onCropsReady: ([CGImage], CGImage) -> Void

    /// ROI existente que se está moviendo o redimensionando (nil si se dibuja una nueva).
    private var editingOriginal: EquationROI?

    /// Acciones que "Deshacer" puede revertir, de la más antigua a la más reciente.
    private enum UndoAction {
        case added(id: UUID)
        case deleted(roi: EquationROI, index: Int)
        case clearedAll(rois: [EquationROI])
    }
    private var undoHistory: [UndoAction] = []

    private static let minSide: CGFloat = 0.02
    /// Separación en píxeles entre ecuaciones en la vista previa final.
    private static let previewGap = 20

    /// Hay algo que deshacer (agregar un recorte, eliminar uno o eliminar todos).
    var canUndo: Bool { !undoHistory.isEmpty }

    /// - Parameter onCropsReady: punto de salida hacia el coordinador de navegación.
    ///   Recibe los recortes listos para el modelo y la vista previa con los recortes
    ///   apilados (separados por `previewGap` píxeles).
    init(
        baseFilteredImage: CGImage,
        cropService: any ROICropServiceProtocol = ROICropService(),
        onCropsReady: @escaping ([CGImage], CGImage) -> Void
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
            // El usuario retomó el trazado: se oculta el aviso de "sin recortes".
            dismissEmptyStateBanner()
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
            let roi = EquationROI(id: activeROI?.id ?? UUID(), normalizedBounds: bounds)
            equationROIs.append(roi)
            undoHistory.append(.added(id: roi.id))
        }
    }

    func undoLastROI() {
        activeROI = nil
        editingOriginal = nil
        // Revierte la acción más reciente: quita el recorte agregado o devuelve el
        // eliminado a su misma posición y con su último tamaño.
        while let action = undoHistory.popLast() {
            switch action {
            case .added(let id):
                guard let index = equationROIs.firstIndex(where: { $0.id == id }) else { continue }
                equationROIs.remove(at: index)
                if selectedROIID == id { selectedROIID = nil }
                return
            case .deleted(let roi, let index):
                equationROIs.insert(roi, at: min(index, equationROIs.count))
                dismissEmptyStateBanner()
                return
            case .clearedAll(let rois):
                equationROIs = rois
                dismissEmptyStateBanner()
                return
            }
        }
    }

    // MARK: - Eliminar todos los recortes (TX21)

    /// Botón "Eliminar todos los rectángulos". Sin recortes avisa con el banner;
    /// con recortes pide confirmación y no borra nada hasta que el usuario acepte.
    func requestClearAll() {
        guard !isProcessing else { return }
        if equationROIs.isEmpty {
            showEmptyStateBanner = true
        } else {
            showClearConfirmation = true
        }
    }

    func confirmClearAll() {
        activeROI = nil
        editingOriginal = nil
        // Se guarda la lista completa para que "Deshacer" pueda devolverla.
        if !equationROIs.isEmpty {
            undoHistory.append(.clearedAll(rois: equationROIs))
        }
        equationROIs.removeAll()
        selectedROIID = nil
        showClearConfirmation = false
        showEmptyStateBanner = true
    }

    func cancelClearAll() {
        showClearConfirmation = false
    }

    func dismissEmptyStateBanner() {
        guard showEmptyStateBanner else { return }
        showEmptyStateBanner = false
    }

    // MARK: - Eliminar recorte particular (TX24)

    /// Tocar un recorte lo resalta; tocarlo de nuevo quita el resaltado;
    /// tocar otro mueve el resaltado a ese.
    func toggleSelection(id: UUID) {
        guard equationROIs.contains(where: { $0.id == id }) else { return }
        selectedROIID = (selectedROIID == id) ? nil : id
    }

    /// Botón "Eliminar recorte": guarda la ROI y pide confirmación; no borra nada todavía.
    func requestDeleteROI(id: UUID) {
        guard !isProcessing, let roi = equationROIs.first(where: { $0.id == id }) else { return }
        roiPendingDeletion = roi
        showDeleteConfirmation = true
    }

    func confirmDeleteROI() {
        if let pending = roiPendingDeletion,
           let index = equationROIs.firstIndex(where: { $0.id == pending.id }) {
            // Se guarda con su posición para poder devolverla con "Deshacer".
            undoHistory.append(.deleted(roi: equationROIs[index], index: index))
            equationROIs.remove(at: index)
            if selectedROIID == pending.id { selectedROIID = nil }
        }
        roiPendingDeletion = nil
        showDeleteConfirmation = false
    }

    func cancelDeleteROI() {
        roiPendingDeletion = nil
        showDeleteConfirmation = false
    }

    // MARK: - Confirmar selección

    func confirmSelection() async {
        guard !isProcessing else { return }
        // Sin recortes no se avanza: se muestra el banner rojo.
        guard !equationROIs.isEmpty else {
            showEmptyStateBanner = true
            return
        }

        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        do {
            let crops = try await cropService.cropAndNormalizeRegions(
                image: baseFilteredImage,
                rois: equationROIs
            )
            let preview = try await cropService.stackedPreview(
                image: baseFilteredImage,
                rois: equationROIs,
                gap: Self.previewGap
            )
            onCropsReady(crops, preview)
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
