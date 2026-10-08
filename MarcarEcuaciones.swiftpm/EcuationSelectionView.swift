import SwiftUI

struct EquationSelectionView: View {
    private static let canvasSpace = "equationCanvas"

    @State private var viewModel: EquationSelectionViewModel
    /// Rectángulo de la ROI al inicio de un gesto de mover/redimensionar.
    @State private var editStartRect: CGRect?

    init(image: CGImage, onCropsReady: @escaping ([CGImage]) -> Void) {
        _viewModel = State(initialValue: EquationSelectionViewModel(
            baseFilteredImage: image,
            onCropsReady: onCropsReady
        ))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Dibuja un rectángulo sobre cada ecuación. Arrástralo para moverlo y usa las esquinas para cambiar su tamaño.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            imageCanvas
            controls
        }
        .padding()
        .overlay { if viewModel.isProcessing { loadingOverlay } }
        .alert("No se pudo continuar", isPresented: errorBinding) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Lienzo

    private var imageCanvas: some View {
        GeometryReader { geo in
            let image = viewModel.baseFilteredImage
            let size = fittedSize(for: CGSize(width: image.width, height: image.height), in: geo.size)

            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: size.width, height: size.height)

                renderCanvasOverlay(in: size)
                renderInteractiveBoundingBoxes(in: size)
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: Self.canvasSpace)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    /// Capa transparente que captura el arrastre para trazar un rectángulo nuevo.
    private func renderCanvasOverlay(in size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.canvasSpace))
                    .onChanged { value in
                        viewModel.updateActiveROI(normalizedRect: drawnRect(from: value, in: size))
                    }
                    .onEnded { value in
                        viewModel.addROI(normalizedRect: drawnRect(from: value, in: size))
                    }
            )
    }

    @ViewBuilder
    private func renderInteractiveBoundingBoxes(in size: CGSize) -> some View {
        // ROI nueva en trazo (todavía no está en la lista).
        if let active = viewModel.activeROI,
           !viewModel.equationROIs.contains(where: { $0.id == active.id }) {
            let rect = pixelRect(active.normalizedBounds, in: size)
            Rectangle()
                .fill(Color.orange.opacity(0.15))
                .overlay(Rectangle().strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }

        ForEach(Array(viewModel.equationROIs.enumerated()), id: \.element.id) { index, roi in
            let rect = pixelRect(roi.normalizedBounds, in: size)
            let color: Color = viewModel.activeROI?.id == roi.id ? .orange : .blue

            ZStack {
                // Cuerpo: arrastrar para mover.
                Rectangle()
                    .fill(color.opacity(0.15))
                    .overlay(Rectangle().strokeBorder(color, lineWidth: 2))
                    .overlay(alignment: .topLeading) {
                        Text("\(index + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(color, in: .rect(cornerRadius: 4))
                            .padding(3)
                    }
                    .contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(moveGesture(for: roi, in: size))
                    .accessibilityLabel("Ecuación \(index + 1)")

                // Esquinas: arrastrar para cambiar el tamaño.
                ForEach(0..<4, id: \.self) { cornerIndex in
                    let point = corner(cornerIndex, of: rect)
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(color, lineWidth: 3))
                        .frame(width: 16, height: 16)
                        .frame(width: 44, height: 44) // zona táctil más grande
                        .contentShape(Rectangle())
                        .position(point)
                        .gesture(resizeGesture(for: roi, cornerIndex: cornerIndex, in: size))
                }
            }
        }
    }

    // MARK: - Gestos de edición

    private func moveGesture(for roi: EquationROI, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                if editStartRect == nil {
                    editStartRect = roi.normalizedBounds
                    viewModel.beginEditingROI(id: roi.id)
                }
                guard let start = editStartRect else { return }

                var moved = start.offsetBy(dx: value.translation.width / size.width,
                                           dy: value.translation.height / size.height)
                moved.origin.x = min(max(moved.origin.x, 0), 1 - moved.width)
                moved.origin.y = min(max(moved.origin.y, 0), 1 - moved.height)
                viewModel.updateActiveROI(normalizedRect: moved)
            }
            .onEnded { _ in finishEditing() }
    }

    private func resizeGesture(for roi: EquationROI, cornerIndex: Int, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                if editStartRect == nil {
                    editStartRect = roi.normalizedBounds
                    viewModel.beginEditingROI(id: roi.id)
                }
                guard let start = editStartRect else { return }

                // La esquina opuesta queda fija; la arrastrada sigue al dedo.
                let fixed = corner((cornerIndex + 2) % 4, of: start)
                let moving = normalize(value.location, in: size)
                viewModel.updateActiveROI(normalizedRect: rect(from: fixed, to: moving))
            }
            .onEnded { _ in finishEditing() }
    }

    private func finishEditing() {
        if let active = viewModel.activeROI {
            viewModel.addROI(normalizedRect: active.normalizedBounds)
        }
        editStartRect = nil
    }

    // MARK: - Controles

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                Task { await viewModel.confirmSelection() }
            } label: {
                Text(viewModel.equationROIs.isEmpty
                     ? "Confirmar selección"
                     : "Confirmar selección (\(viewModel.equationROIs.count))")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canConfirm)

            Button {
                viewModel.undoLastROI()
            } label: {
                Label("Deshacer", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.equationROIs.isEmpty)
        }
        .disabled(viewModel.isProcessing)
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            ProgressView("Procesando…")
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
    }

    // MARK: - Utilidades geométricas

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.dismissError() } }
        )
    }

    private func fittedSize(for imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func normalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: point.x / size.width, y: point.y / size.height)
    }

    private func pixelRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width,
               y: normalized.minY * size.height,
               width: normalized.width * size.width,
               height: normalized.height * size.height)
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func drawnRect(from value: DragGesture.Value, in size: CGSize) -> CGRect {
        rect(from: normalize(value.startLocation, in: size),
             to: normalize(value.location, in: size))
    }

    /// 0 = arriba-izq, 1 = arriba-der, 2 = abajo-der, 3 = abajo-izq.
    private func corner(_ index: Int, of rect: CGRect) -> CGPoint {
        switch index {
        case 0: CGPoint(x: rect.minX, y: rect.minY)
        case 1: CGPoint(x: rect.maxX, y: rect.minY)
        case 2: CGPoint(x: rect.maxX, y: rect.maxY)
        default: CGPoint(x: rect.minX, y: rect.maxY)
        }
    }
}
