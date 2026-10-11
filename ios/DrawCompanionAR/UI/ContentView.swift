import Network
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AppSettings.onboarded) private var onboarded = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            CameraView().ignoresSafeArea()
            if !onboarded {
                OnboardingView()
                    .transition(.opacity)
            } else if model.headset {
                HeadsetOverlay()
            } else {
                PhoneOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: onboarded)
        .statusBarHidden(true)
        .persistentSystemOverlays(model.headset ? .hidden : .automatic)
        .onAppear {
            if onboarded || Permissions.camera == .granted { Launch.start(model) }
            if onboarded { Launch.listenIfAllowed(model) }
        }
        .onChange(of: onboarded) { _, done in
            guard done else { return }
            Launch.start(model)
            Launch.listenIfAllowed(model)
        }
        .onChange(of: phase) { _, phase in
            // Back from Settings with access newly allowed: start listening.
            if phase == .active, onboarded { Launch.listenIfAllowed(model) }
        }
    }
}

/// Phone view: for setup and trying things out. Talk or type, then switch to
/// the headset view. The AI never replies in words; this only shows status.
struct PhoneOverlay: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var live = LiveSpeech.shared
    @ObservedObject private var network = Connectivity.shared
    @State private var typed = ""
    @State private var showSettings = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                StatusPill(status: status)
                if model.usingMock {
                    Button { showSettings = true } label: {
                        Label("Sample AI", systemImage: "wand.and.stars")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(ChipStyle())
                    .accessibilityHint("Add your Claude API key in Settings for real outlines")
                }
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(RoundIconStyle())
                .accessibilityLabel("Settings")
            }
            if let issue {
                IssueBanner(issue: issue) { fix(issue) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            Transcript(partial: live.partial, last: model.lastHeard)
            controls
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .animation(.easeOut(duration: 0.25), value: issue)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { model.toggleListening() } label: {
                Image(systemName: model.listening ? "mic.fill" : "mic.slash.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(RoundIconStyle(tint: model.listening ? .green : nil))
            .accessibilityLabel(model.listening ? "Stop listening" : "Start listening")

            HStack {
                TextField("Or type what you'd say…", text: $typed)
                    .submitLabel(.send)
                    .focused($typing)
                    .onSubmit(send)
                if !typed.isEmpty {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                        .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(.ultraThinMaterial, in: Capsule())

            if model.hasOutline {
                Button { model.clearOutline() } label: {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(RoundIconStyle())
                .accessibilityLabel("Hide outline")
                .transition(.scale.combined(with: .opacity))
            }

            Button { typing = false; model.enterHeadset() } label: {
                Label("Headset view", systemImage: "eyeglasses")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(Color.brand, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.hasOutline)
    }

    private func send() {
        model.heard(typed)
        typed = ""
    }

    // MARK: status

    private var status: StatusPill.Status {
        if live.state == .paused { return .init(text: "Paused", color: .gray) }
        if !model.pageFound { return .init(text: "Looking for paper", color: .orange) }
        if model.working { return .init(text: "Working on it", color: .brand, pulsing: true) }
        if model.listening { return .init(text: "Listening", color: .green) }
        return .init(text: "Mic off · tap the mic or type", color: .gray)
    }

    private var issue: Issue? {
        if live.state == .denied || (model.listening == false && Permissions.microphone == .denied) {
            return Issue(icon: "mic.slash", text: "Microphone or speech recognition is off for DrawCompanion.", fix: "Open Settings", action: .systemSettings)
        }
        if model.pageFound == false && Permissions.camera == .denied {
            return Issue(icon: "camera", text: "Camera access is off, so DrawCompanion can't see your paper.", fix: "Open Settings", action: .systemSettings)
        }
        if !network.online {
            return Issue(icon: "wifi.slash", text: model.usingMock ? "You're offline. The sample AI still works." : "You're offline. Outlines need an internet connection.", fix: nil, action: nil)
        }
        if let problem = model.problem {
            if problem.localizedCaseInsensitiveContains("key was rejected") {
                return Issue(icon: "key", text: "Your Claude API key was rejected.", fix: "Fix key", action: .appSettings)
            }
            if problem.localizedCaseInsensitiveContains("speech recognition") {
                return Issue(icon: "waveform.slash", text: "Speech recognition isn't available right now. Typing still works.", fix: "Retry", action: .retryMic)
            }
            if problem.localizedCaseInsensitiveContains("offline") || problem.localizedCaseInsensitiveContains("internet")
                || problem.localizedCaseInsensitiveContains("timed out") || problem.localizedCaseInsensitiveContains("network") {
                return Issue(icon: "wifi.exclamationmark", text: "Couldn't reach Claude. Check your connection and say it again.", fix: nil, action: nil)
            }
            if problem.localizedCaseInsensitiveContains("busy") {
                return Issue(icon: "hourglass", text: "Claude is busy. Say it again in a moment.", fix: nil, action: nil)
            }
            return Issue(icon: "exclamationmark.triangle", text: problem, fix: nil, action: nil)
        }
        if let note = live.note {
            return Issue(icon: "pause.circle", text: note, fix: nil, action: nil)
        }
        return nil
    }

    private func fix(_ issue: Issue) {
        switch issue.action {
        case .systemSettings: Permissions.openSettings()
        case .appSettings: showSettings = true
        case .retryMic: model.startListening()
        case nil: break
        }
    }
}

// MARK: pieces

struct Issue: Equatable {
    enum Action { case systemSettings, appSettings, retryMic }
    var icon: String
    var text: String
    var fix: String?
    var action: Action?
}

struct IssueBanner: View {
    let issue: Issue
    let onFix: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: issue.icon).foregroundStyle(.orange)
            Text(issue.text).font(.footnote).foregroundStyle(.white).lineLimit(2)
            if let fix = issue.fix {
                Button(fix, action: onFix)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 560)
    }
}

struct StatusPill: View {
    struct Status: Equatable {
        var text: String
        var color: Color
        var pulsing = false
    }

    let status: Status
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
                .opacity(status.pulsing && pulse ? 0.25 : 1)
                .animation(status.pulsing ? .easeInOut(duration: 0.5).repeatForever() : .default, value: pulse)
            Text(status.text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.easeInOut(duration: 0.2), value: status)
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
    }
}

/// What's being heard right now, in small light type; the finished phrase
/// lingers briefly, then fades.
struct Transcript: View {
    let partial: String
    let last: String
    @State private var showLast = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if !partial.isEmpty {
                Text(partial).foregroundStyle(.white.opacity(0.85))
            } else if showLast, !last.isEmpty {
                Text("“\(last)”").foregroundStyle(.white.opacity(0.55))
            }
        }
        .font(.callout)
        .lineLimit(2)
        .truncationMode(.head)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.black.opacity(partial.isEmpty && !showLast ? 0 : 0.35), in: Capsule())
        .frame(maxWidth: 620)
        .animation(.easeOut(duration: 0.2), value: partial)
        .animation(.easeOut(duration: 0.6), value: showLast)
        .onChange(of: last) { _, _ in
            showLast = true
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled { showLast = false }
            }
        }
    }
}

struct RoundIconStyle: ButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint == nil ? Color.white : Color.black)
            .frame(width: 44, height: 44)
            .background {
                if let tint { Circle().fill(tint) } else { Circle().fill(.ultraThinMaterial) }
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.brand)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.ultraThinMaterial, in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Whether the phone is online (so "no network" can be shown before a request fails).
@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    @Published private(set) var online = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Connectivity.shared.online = online }
            }
        }
        monitor.start(queue: DispatchQueue(label: "drawcompanion.network"))
    }
}
