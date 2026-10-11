import AVFoundation
import Speech
import SwiftUI

@main
struct DrawCompanionApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(.brand)
        }
    }
}

/// Starting the camera and the always-on microphone. On first launch this
/// waits for the welcome screens, so the permission prompts come with an
/// explanation instead of all at once.
@MainActor
enum Launch {
    private static var started = false

    /// Camera, page tracking and the turn loop. Safe to call more than once.
    static func start(_ model: AppModel) {
        guard !started else { return }
        started = true
        model.start()
    }

    /// Turns the microphone on if the user has already allowed it (never
    /// prompts: the welcome screens ask first).
    static func listenIfAllowed(_ model: AppModel) {
        guard Permissions.microphone == .granted, Permissions.speech == .granted, !model.listening else { return }
        model.startListening()
    }
}

/// Camera, microphone and speech recognition access.
@MainActor
enum Permissions {
    enum Status { case notAsked, granted, denied }

    static var camera: Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    static var microphone: Status {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .undetermined: return .notAsked
        default: return .denied
        }
    }

    static var speech: Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    static var allGranted: Bool { camera == .granted && microphone == .granted && speech == .granted }

    /// Asks for whatever hasn't been asked yet, one prompt at a time.
    static func requestAll() async {
        if camera == .notAsked { _ = await AVCaptureDevice.requestAccess(for: .video) }
        if microphone == .notAsked { _ = await AVAudioApplication.requestRecordPermission() }
        if speech == .notAsked { _ = await SpeechListener.speechPermission() }
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

extension Color {
    /// The app's accent: the cyan of the "working" dot, close to how an outline glows.
    static let brand = Color(red: 0.30, green: 0.82, blue: 0.93)
}
