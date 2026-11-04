import SwiftUI
@preconcurrency import AVFoundation

// MARK: - Vista previa de cámara

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

// MARK: - CameraView

struct CameraView: View {
    /// El view model lo crea y conserva RootView.
    let viewModel: CameraViewModel
    /// Recibe la foto confirmada (siguiente etapa: delimitar la hoja en CropView).
    let onPhotoConfirmed: (CGImage) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: viewModel.cameraService.sessionBox.session)
                .ignoresSafeArea()

            if let preview = viewModel.capturedPhotoPreview {
                Color.black.ignoresSafeArea()
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .scaledToFit()
            }

            if viewModel.sessionState == .configuring || viewModel.sessionState == .preparing {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            VStack {
                Spacer()
                controls
                    .padding(.bottom, 32)
            }
        }
        .task { await viewModel.startCameraSession() }
        .onDisappear { viewModel.stopCameraSession() }
    }

    @ViewBuilder
    private var controls: some View {
        switch viewModel.sessionState {
        case .running, .capturing:
            Button {
                Task { await viewModel.takePhoto() }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(.white).frame(width: 62, height: 62)
                }
            }
            .disabled(viewModel.sessionState == .capturing)

        case .reviewing, .preparing:
            HStack(spacing: 24) {
                Button("Repetir") { viewModel.retakePhoto() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button("Confirmar Foto") {
                    Task {
                        if let photo = await viewModel.confirmPhoto() {
                            onPhotoConfirmed(photo)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(viewModel.sessionState == .preparing)

        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button("Reintentar") {
                    Task { await viewModel.startCameraSession() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

        default:
            EmptyView()
        }
    }
}

#Preview {
    CameraView(viewModel: CameraViewModel(), onPhotoConfirmed: { _ in })
}
