import SwiftUI
import PhotosUI
import CoreImage

/// Vista raíz: elegir foto → delimitar la hoja → marcar ecuaciones → ver recortes.
struct RootView: View {

    private enum Step {
        case selecting
        case cropping(CIImage)
        case marking(CGImage)
        case result([UIImage])
    }

    @State private var step: Step = .selecting
    @State private var pickerItem: PhotosPickerItem?
    @State private var loadError: String?

    var body: some View {
        switch step {
        case .selecting:
            selectionView

        case .cropping(let image):
            CropView(
                image: image,
                onConfirmed: { cropped in
                    if let cgImage = CIContext().createCGImage(cropped, from: cropped.extent) {
                        step = .marking(cgImage)
                    } else {
                        loadError = "No se pudo generar la imagen recortada."
                        step = .selecting
                    }
                },
                onRetake: { step = .selecting }
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

    private var selectionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "function")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("ToLaTeX")
                .font(.largeTitle.bold())

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Elegir foto de la hoja", systemImage: "photo")
                    .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(from: item) }
        }
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

            Button("Empezar de nuevo") { step = .selecting }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Utilidades

    private func loadPhoto(from item: PhotosPickerItem) async {
        defer { pickerItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data),
                  let ciImage = CIImage(image: uiImage,
                                        options: [.applyOrientationProperty: true]) else {
                loadError = "La foto está corrupta o no se pudo leer. Elige otra."
                return
            }
            loadError = nil
            step = .cropping(ciImage)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
