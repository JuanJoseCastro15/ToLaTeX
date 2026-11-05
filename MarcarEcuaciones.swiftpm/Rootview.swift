import SwiftUI
import PhotosUI
import CoreImage

/// Flujo completo: bienvenida → cámara → delimitar la hoja → marcar ecuaciones → recortes.
struct RootView: View {

    private enum Step {
        case welcome
        case camera
        case cropping(CIImage)
        case marking(CGImage)
        case result([UIImage])
    }

    @State private var step: Step = .welcome
    @State private var cameraViewModel = CameraViewModel()
    private let preprocessing = ImagePreprocessingService()
    @State private var pickerItem: PhotosPickerItem?
    @State private var loadError: String?

    var body: some View {
        switch step {
        case .welcome:
            welcomeView

        case .camera:
            cameraStep

        case .cropping(let image):
            CropView(
                image: image,
                onConfirmed: { cropped in
                    if let cgImage = CIContext().createCGImage(cropped, from: cropped.extent) {
                        step = .marking(cgImage)
                    } else {
                        loadError = "No se pudo generar la imagen recortada."
                        step = .camera
                    }
                },
                onRetake: { step = .camera }
            )

        case .marking(let cgImage):
            EquationSelectionView(image: cgImage) { crops in
                step = .result(crops.map { UIImage(cgImage: $0) })
            }

        case .result(let crops):
            resultView(crops)
        }
    }

    // MARK: - Pantallas

    private var welcomeView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "function")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Bienvenido a ToLaTeX")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Toma una foto de tu hoja y convierte tus ecuaciones a LaTeX.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                loadError = nil
                step = .camera
            } label: {
                Label("Tomar foto", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
    }

    private var cameraStep: some View {
        CameraView(viewModel: cameraViewModel) { photo in
            loadError = nil
            step = .cropping(CIImage(cgImage: photo))
        }
        .overlay(alignment: .topTrailing) { galleryButton }
        .overlay(alignment: .top) {
            if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.red.opacity(0.85), in: .rect(cornerRadius: 8))
                    .padding(.top, 8)
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(from: item) }
        }
    }

    /// Alternativa a la cámara (y la única opción en el simulador).
    private var galleryButton: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            Image(systemName: "photo.on.rectangle")
                .font(.title3)
                .foregroundStyle(.white)
                .padding(12)
                .background(.ultraThinMaterial, in: .circle)
        }
        .padding()
        .accessibilityLabel("Elegir foto de la galería")
    }

    private func resultView(_ crops: [UIImage]) -> some View {
        VStack(spacing: 16) {
            Text("Recortes listos para UniMERNet (\(crops.count))")
                .font(.headline)

            ScrollView {
                VStack(spacing: 16) {
                    ForEach(Array(crops.enumerated()), id: \.offset) { index, crop in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ecuación \(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(uiImage: crop)
                                .resizable()
                                .scaledToFit()
                                .border(.secondary.opacity(0.4))
                        }
                    }
                }
            }

            Button("Empezar de nuevo") { step = .welcome }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Utilidades

    private func loadPhoto(from item: PhotosPickerItem) async {
        defer { pickerItem = nil }
        do {
            // Se decodifica con ImageIO (aplica la orientación EXIF) igual que la foto
            // de la cámara. CIImage(image: UIImage) ignora la orientación del UIImage
            // y dejaba las fotos de la galería giradas.
            guard let data = try await item.loadTransferable(type: Data.self),
                  let cgImage = await preprocessing.makeWorkingImage(from: data) else {
                loadError = "La foto está corrupta o no se pudo leer. Elige otra."
                return
            }
            loadError = nil
            step = .cropping(CIImage(cgImage: cgImage))
        } catch {
            loadError = error.localizedDescription
        }
    }
}
