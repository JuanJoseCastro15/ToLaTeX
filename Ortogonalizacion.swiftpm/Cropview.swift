import SwiftUI
import CoreImage

struct CropView: View {
    private static let canvasSpace = "cropCanvas"
    private static let cornerNames = ["superior izquierda", "superior derecha",
                                      "inferior derecha", "inferior izquierda"]

    @State private var viewModel: CropViewModel
    private let onConfirmed: (CIImage) -> Void
    private let onRetake: () -> Void

    /// - Parameters:
    ///   - onConfirmed: recibe la imagen ya recortada y rectificada (siguiente etapa: UniMERNet).
    ///   - onRetake: el usuario quiere volver a tomar la foto.
    init(image: CIImage,
         onConfirmed: @escaping (CIImage) -> Void,
         onRetake: @escaping () -> Void) {
        _viewModel = State(initialValue: CropViewModel(inputImage: image))
        self.onConfirmed = onConfirmed
        self.onRetake = onRetake
    }

    var body: some View {
        VStack(spacing: 16) {
            hint
            imageCanvas
            controls
        }
        .padding()
        .overlay { if viewModel.isProcessing { loadingOverlay } }
        .task { await viewModel.detectDocumentBounds() }
        .alert("No se pudo continuar", isPresented: errorBinding) {
            Button("Volver a tomar foto", action: onRetake)
            Button("Marcar manualmente") { viewModel.startManualSelection() }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Subvistas

    private var hint: some View {
        let isInvalid = viewModel.detectedPolygon?.isValid == false
        return Text(isInvalid
                    ? "El recuadro no es válido: debe ser convexo y sin cruces."
                    : "Ajusta las esquinas si el recuadro no cubre bien la hoja.")
            .font(.footnote)
            .foregroundStyle(isInvalid ? .red : .secondary)
    }

    private var imageCanvas: some View {
        GeometryReader { geo in
            let size = fittedSize(for: viewModel.inputImage.extent.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: viewModel.previewImage)
                    .resizable()
                    .frame(width: size.width, height: size.height)

                if let polygon = viewModel.detectedPolygon {
                    renderPolygonOverlay(polygon, in: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: Self.canvasSpace)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    @ViewBuilder
    private func renderPolygonOverlay(_ polygon: PerspectivePolygon, in size: CGSize) -> some View {
        let color: Color = polygon.isValid ? .green : .red
        let points = polygon.corners.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        let outline = Path { path in
            path.move(to: points[0])
            points.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()
        }

        ZStack(alignment: .topLeading) {
            outline.fill(color.opacity(0.15))
            outline.stroke(color, lineWidth: 2)

            ForEach(points.indices, id: \.self) { index in
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(color, lineWidth: 3))
                    .frame(width: 24, height: 24)
                    .frame(width: 44, height: 44) // zona táctil más grande
                    .contentShape(Rectangle())
                    .position(points[index])
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.canvasSpace))
                            .onChanged { value in
                                viewModel.updateCorner(
                                    index: index,
                                    newLocation: CGPoint(x: value.location.x / size.width,
                                                         y: value.location.y / size.height)
                                )
                            }
                    )
                    .accessibilityLabel("Esquina \(Self.cornerNames[index])")
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    if let cropped = await viewModel.confirmAndCrop() {
                        onConfirmed(cropped)
                    }
                }
            } label: {
                Text("Confirmar").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canConfirm)

            HStack(spacing: 12) {
                Button("Retomar foto", action: onRetake)
                Button("Marcar manualmente") { viewModel.startManualSelection() }
            }
            .buttonStyle(.bordered)
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

    // MARK: - Utilidades

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
}
