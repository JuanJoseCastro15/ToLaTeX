// Ticket: [TX-13] - Pantalla Inicial y Gestión de Permisos de Cámara
// Proyecto: ToLaTeX | iOS 18.0+ | Swift 6

// MARK: - Imports & Config

import SwiftUI
import AVFoundation
import CoreImage
import Accelerate
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Domain Models & Error Handling

/// Representa las rutas de navegación disponibles en la jerarquía global de ToLaTeX.
public enum AppRoute: Hashable, Sendable {
    case camera
    case laTeXResult(rawLaTeX: String)
}

/// Estado de los permisos del hardware de la cámara.
public enum CameraPermissionStatus: Sendable {
    case granted
    case denied
    case notDetermined
    case restricted
}

/// Estado global de carga del sistema y verificación de componentes.
public enum AppLoadState: Sendable, Equatable {
    case loading
    case loaded
    case failed(reason: String)
}

/// Errores localizados para la gestión de permisos y estados de ejecución.
public enum CameraPermissionError: LocalizedError, Sendable {
    case permissionDenied
    case permissionRestricted
    case appInitializationFailed

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "El acceso a la cámara fue denegado. Por favor, habilítalo en la Configuración de tu dispositivo para escanear ecuaciones."
        case .permissionRestricted:
            return "El acceso a la cámara está restringido en este dispositivo por políticas del sistema."
        case .appInitializationFailed:
            return "Ocurrió un error al inicializar los recursos de ToLaTeX. Presiona el botón para intentar nuevamente."
        }
    }
}

// MARK: - Services & Actors Layer

/// Contrato del servicio de infraestructura para la gestión de permisos del hardware de video.
public protocol CameraPermissionsServiceProtocol: Sendable {
    func checkPermission() async -> CameraPermissionStatus
    func requestAccess() async -> Bool
}

/// Servicio encargado exclusivamente de gestionar la autorización del hardware de video con AVFoundation.
public actor CameraPermissionsService: CameraPermissionsServiceProtocol {
    
    public init() {}
    
    /// Consulta el estado actual del permiso de video en AVFoundation sin bloquear el hilo principal.
    public func checkPermission() async -> CameraPermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }
    
    /// Dispara la solicitud nativa de permisos suspendiendo la ejecución asíncronamente con async/await.
    public func requestAccess() async -> Bool {
        return await AVCaptureDevice.requestAccess(for: .video)
    }
}

// MARK: - Presentation Layer (ViewModel & SwiftUI Views)

/// Director de tráfico de la aplicación que administra la pila de navegación global.
@Observable
@MainActor
public final class AppCoordinator {
    public var path: NavigationPath
    
    public init(path: NavigationPath = NavigationPath()) {
        self.path = path
    }
    
    /// Muta la propiedad `path` apilando el destino correspondiente al flujo de la cámara.
    public func navigateToCamera() {
        path.append(AppRoute.camera)
    }
    
    /// Regresa la pila de navegación a la vista raíz del menú principal.
    public func popToRoot() {
        path.removeLast(path.count)
    }
}

/// Mantiene el estado reactivo de la vista de menú inicial y coordina la lógica de negocio previa a la captura.
@Observable
@MainActor
public final class MainMenuViewModel {
    
    // MARK: - Properties
    public var isCameraAuthorized: Bool = false
    public var appLoadState: AppLoadState = .loaded
    public var errorMessage: String? = nil
    public var showErrorAlert: Bool = false
    
    private let cameraPermissionsService: any CameraPermissionsServiceProtocol
    private let coordinator: AppCoordinator
    
    // MARK: - Initialization
    public init(
        cameraPermissionsService: any CameraPermissionsServiceProtocol,
        coordinator: AppCoordinator
    ) {
        self.cameraPermissionsService = cameraPermissionsService
        self.coordinator = coordinator
    }
    
    // MARK: - Public Actions
    
    /// Método orquestador. Determina si se deben solicitar permisos o si se ordena al coordinador la transición a la cámara.
    public func handleCameraButtonTap() {
        Task {
            let status = await cameraPermissionsService.checkPermission()
            
            switch status {
            case .granted:
                self.isCameraAuthorized = true
                self.coordinator.navigateToCamera()
                
            case .notDetermined:
                let granted = await cameraPermissionsService.requestAccess()
                self.isCameraAuthorized = granted
                if granted {
                    self.coordinator.navigateToCamera()
                } else {
                    self.presentError(CameraPermissionError.permissionDenied)
                }
                
            case .denied:
                self.isCameraAuthorized = false
                self.presentError(CameraPermissionError.permissionDenied)
                
            case .restricted:
                self.isCameraAuthorized = false
                self.presentError(CameraPermissionError.permissionRestricted)
            }
        }
    }
    
    /// Permite reintentar la carga del estado inicial si ocurre una falla al iniciar la app.
    public func retryLoadingApp() {
        self.appLoadState = .loading
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            self.appLoadState = .loaded
        }
    }
    
    // MARK: - Private Helpers
    private func presentError(_ error: CameraPermissionError) {
        self.errorMessage = error.localizedDescription
        self.showErrorAlert = true
    }
}

/// Renderiza la interfaz de entrada de la aplicación en SwiftUI dentro del @MainActor.
public struct MainMenuView: View {
    @State private var viewModel: MainMenuViewModel
    
    public init(viewModel: MainMenuViewModel) {
        self._viewModel = State(initialValue: viewModel)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            switch viewModel.appLoadState {
            case .loading:
                loadingView
            case .failed(let reason):
                failureView(reason: reason)
            case .loaded:
                mainMenuView
            }
        }
        .animation(.default, value: viewModel.appLoadState)
        .alert("Aviso de Cámara", isPresented: $viewModel.showErrorAlert) {
            Button("Aceptar", role: .cancel) { }
            #if os(iOS)
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link("Configuración", destination: settingsURL)
            }
            #endif
        } message: {
            Text(viewModel.errorMessage ?? "Ocurrió un inconveniente con los permisos de la cámara.")
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var mainMenuView: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Sección Ilustrativa y Branding
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 120, height: 120)
                    
                    Image(systemName: "function")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                
                Text("ToLaTeX")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                
                Text("Convierte ecuaciones matemáticas manuscritas o impresas a código LaTeX con Inteligencia Artificial.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }
            
            Spacer()
            
            // Botón Principal "Tomar foto"
            Button {
                onTapCameraButton()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.title2)
                    Text("Tomar foto")
                        .font(.title3)
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.accentColor.opacity(0.35), radius: 10, x: 0, y: 5)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 36)
        }
        .padding()
    }
    
    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Cargando menú inicial...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func failureView(reason: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            
            VStack(spacing: 8) {
                Text("Error de Carga")
                    .font(.title2)
                    .bold()
                
                Text(reason)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            }
            
            Button {
                viewModel.retryLoadingApp()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Volver a cargar")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Color.accentColor)
                .clipShape(Capsule())
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Action Handlers
    
    /// Método de acción que captura el gesto de toque (tap) sobre el botón de la cámara y notifica inmediatamente al MainMenuViewModel.
    public func onTapCameraButton() {
        viewModel.handleCameraButtonTap()
    }
}

// MARK: - Target Views & Application Container

/// Vista de destino del flujo de captura utilizada en el mapeo de NavigationStack.
public struct CameraCaptureDestinationView: View {
    @Environment(AppCoordinator.self) private var coordinator
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "viewfinder")
                .font(.system(size: 72))
                .foregroundStyle(Color.accentColor)
            
            Text("Módulo de Captura de Cámara")
                .font(.title2)
                .bold()
            
            Text("Matriz de entrada optimizada para ANE (384x1152 px)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            
            Button("Regresar al Menú Principal") {
                coordinator.popToRoot()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 16)
        }
        .padding()
        .navigationTitle("Capturar Ecuación")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Contenedor de la aplicación que integra NavigationStack y el flujo del AppCoordinator.
public struct ToLaTeXRootView: View {
    @State private var coordinator = AppCoordinator()
    @State private var permissionsService = CameraPermissionsService()
    
    public init() {}
    
    public var body: some View {
        NavigationStack(path: $coordinator.path) {
            MainMenuView(
                viewModel: MainMenuViewModel(
                    cameraPermissionsService: permissionsService,
                    coordinator: coordinator
                )
            )
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .camera:
                    CameraCaptureDestinationView()
                        .environment(coordinator)
                case .laTeXResult(let rawLaTeX):
                    VStack {
                        Text("Ecuación Procesada:")
                        Text(rawLaTeX)
                            .font(.monospaced(.body)())
                    }
                }
            }
        }
        .environment(coordinator)
    }
}
