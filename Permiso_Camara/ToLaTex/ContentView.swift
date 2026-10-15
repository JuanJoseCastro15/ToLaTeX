// Ticket: [TX14] - Acceder a la cámara (Integración con ContentView - Fix Swift 6 Concurrency)
// Proyecto: ToLaTeX | iOS 18.0+ | Swift 6

// MARK: - Imports & Config
import SwiftUI
import AVFoundation

// MARK: - Domain Models & Error Handling

/// Representa los estados posibles de la interfaz gráfica de la cámara.
enum CameraViewState: Sendable, Equatable {
    case idle
    case loadingPermission
    case denied
    case error(String)
    case ready
}

/// Mapeo del estado de autorización de AVFoundation.
enum CameraAuthorizationStatus: Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
}

/// Errores posibles durante la configuración de la cámara.
enum CameraError: LocalizedError, Sendable {
    case deviceUnavailable
    case cannotAddInput
    case timeout
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "No se pudo acceder al hardware de la cámara."
        case .cannotAddInput:
            return "No se pudo configurar la entrada de video."
        case .timeout:
            return "La solicitud ha tardado demasiado."
        case .unknown:
            return "Ocurrió un error desconocido."
        }
    }
}

// MARK: - Services & Actors Layer

/// Interfaz de Dominio para el servicio de cámara.
protocol CameraServiceProtocol: Sendable {
    func checkPermission() async -> CameraAuthorizationStatus
    func requestPermission() async -> Bool
    func configureSession() async throws
    func getCaptureSession() async -> AVCaptureSession
    func startSession() async
}

/// Servicio concreto de infraestructura que interactúa con AVFoundation.
actor AVCameraService: CameraServiceProtocol {
    private let captureSession = AVCaptureSession()
    private var isConfigured = false
    
    init() {}
    
    func checkPermission() -> CameraAuthorizationStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .notDetermined
        }
    }
    
    func requestPermission() async -> Bool {
        return await AVCaptureDevice.requestAccess(for: .video)
    }
    
    func configureSession() throws {
        guard !isConfigured else { return }
        
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // Configuración para dispositivo físico. En el simulador esto lanzará deviceUnavailable
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let deviceInput = try? AVCaptureDeviceInput(device: videoDevice) else {
            throw CameraError.deviceUnavailable
        }
        
        if captureSession.canAddInput(deviceInput) {
            captureSession.addInput(deviceInput)
        } else {
            throw CameraError.cannotAddInput
        }
        
        captureSession.sessionPreset = .photo
        isConfigured = true
    }
    
    func getCaptureSession() -> AVCaptureSession {
        return captureSession
    }
    
    func startSession() {
        guard !captureSession.isRunning else { return }
        captureSession.startRunning()
    }
}

// MARK: - Presentation Layer (ViewModel & SwiftUI Views)

/// Lógica de presentación y máquina de estados de la vista de cámara.
@MainActor
@Observable
final class CameraViewModel {
    var state: CameraViewState = .idle
    var captureSession: AVCaptureSession?
    
    private let cameraService: CameraServiceProtocol
    
    init(cameraService: CameraServiceProtocol = AVCameraService()) {
        self.cameraService = cameraService
    }
    
    /// Evalúa la autorización y configura la sesión si se tienen los permisos.
    func checkAndRequestPermission() async {
        state = .loadingPermission
        
        let status = await cameraService.checkPermission()
        
        switch status {
        case .notDetermined:
            let granted = await cameraService.requestPermission()
            if granted {
                await setupSession()
            } else {
                state = .denied
            }
            
        case .authorized:
            await setupSession()
            
        case .denied, .restricted:
            state = .denied
        }
    }
    
    /// Reintenta el proceso de permisos/configuración.
    func retryPermission() {
        Task {
            await checkAndRequestPermission()
        }
    }
    
    private func setupSession() async {
        do {
            try await cameraService.configureSession()
            
            // Iniciar la sesión de captura en un hilo secundario para no bloquear el Main Thread.
            // Se captura cameraService fuertemente ya que Task.detached terminará de inmediato.
            await Task.detached(priority: .userInitiated) {
                await self.cameraService.startSession()
            }.value
            
            self.captureSession = await cameraService.getCaptureSession()
            self.state = .ready
        } catch {
            self.state = .error(error.localizedDescription)
        }
    }
}

/// Capa de Presentación principal que renderiza la vista de cámara o los estados de error/carga.
@MainActor
struct CameraView: View {
    // Al usar @State directamente con el inicializador por defecto,
    // Swift 6 respeta el aislamiento del @MainActor.
    @State private var viewModel = CameraViewModel()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            switch viewModel.state {
            case .idle:
                Color.clear
                    .task {
                        await viewModel.checkAndRequestPermission()
                    }
                
            case .loadingPermission:
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    Text("Configurando cámara...")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                
            case .ready:
                if let session = viewModel.captureSession {
                    CameraPreviewRepresentable(session: session)
                        .ignoresSafeArea()
                        .transition(.opacity)
                    
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                dismiss()
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white)
                                    .padding()
                            }
                        }
                        Spacer()
                    }
                }
                
            case .denied:
                VStack(spacing: 20) {
                    Image(systemName: "camera.slash.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.gray)
                    
                    Text("Acceso a la cámara denegado")
                        .font(.title2)
                        .bold()
                        .foregroundColor(.white)
                    
                    Text("ToLaTeX requiere acceso a la cámara para poder capturar las ecuaciones matemáticas y procesarlas. Por favor, habilita el permiso en la configuración del dispositivo.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 32)
                    
                    Button {
                        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(settingsUrl)
                        }
                    } label: {
                        Text("Ir a Configuración")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .cornerRadius(12)
                            .padding(.horizontal, 32)
                    }
                    
                    Button("Volver al inicio") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                    .padding(.top, 10)
                }
                
            case .error(let errorMessage):
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.yellow)
                    
                    Text("Ocurrió un problema")
                        .font(.title2)
                        .bold()
                        .foregroundColor(.white)
                    
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 32)
                    
                    Button {
                        viewModel.retryPermission()
                    } label: {
                        Text("Volver a cargar")
                            .font(.headline)
                            .foregroundColor(.black)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.white)
                            .cornerRadius(12)
                            .padding(.horizontal, 32)
                    }
                    
                    Button("Volver al inicio") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                    .padding(.top, 10)
                }
            }
        }
        .animation(.easeInOut, value: viewModel.state)
        .navigationBarHidden(true)
    }
}

/// Vista auxiliar de UIKit envuelta en SwiftUI para mostrar la capa de captura de AVFoundation.
@MainActor
struct CameraPreviewRepresentable: UIViewRepresentable {
    let session: AVCaptureSession
    
    class VideoPreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }
        
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
    }
    
    func makeUIView(context: Context) -> VideoPreviewView {
        let view = VideoPreviewView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }
    
    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

// MARK: - Punto de Entrada de la Aplicación (Menú Inicial)

/// Menú inicial con el botón "Tomar foto".
@MainActor
struct ContentView: View {
    @State private var isPresentingCamera = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()
                
                Image(systemName: "function")
                    .font(.system(size: 100))
                    .foregroundColor(.blue)
                
                Text("ToLaTeX")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                
                Text("Convierte imágenes de ecuaciones\nmatemáticas a código LaTeX.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                Spacer()
                
                Button(action: {
                    isPresentingCamera = true
                }) {
                    HStack {
                        Image(systemName: "camera.fill")
                        Text("Tomar foto")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(16)
                    .padding(.horizontal, 40)
                }
                .padding(.bottom, 50)
            }
            .navigationDestination(isPresented: $isPresentingCamera) {
                CameraView()
            }
        }
    }
}

#Preview {
    ContentView()
}
