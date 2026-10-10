import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            CameraView().ignoresSafeArea()
            if model.headset {
                HeadsetOverlay()
            } else {
                PhoneOverlay()
            }
        }
        .statusBarHidden(model.headset)
        .persistentSystemOverlays(model.headset ? .hidden : .automatic)
    }
}

/// Headset view: nothing but your page, the outline, and a small status dot
/// low in each eye. Green = listening, pulsing blue = working on what you
/// said, orange = can't see the page, grey = microphone off. Text appears
/// only for setup problems. Double-tap (the viewer's button twice) to exit.
struct HeadsetOverlay: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            eye
            eye
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.exitHeadset() }
    }

    private var eye: some View {
        VStack(spacing: 8) {
            Spacer()
            if let problem = model.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.horizontal, 24)
            }
            StatusDot()
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusDot: View {
    @EnvironmentObject var model: AppModel
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(model.working ? (pulse ? 0.3 : 1) : 0.9)
            .animation(model.working ? .easeInOut(duration: 0.4).repeatForever() : .default, value: pulse)
            .onAppear { pulse = true }
    }

    private var color: Color {
        if !model.pageFound { return .orange }
        if model.working { return .cyan }
        return model.listening ? .green : .gray
    }
}

/// Phone view: for setup and trying things out. Talk or type, then switch to
/// the headset view.
struct PhoneOverlay: View {
    @EnvironmentObject var model: AppModel
    @State private var typed = ""
    @State private var showSettings = false

    var body: some View {
        VStack {
            HStack {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.title3)
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            if !model.lastHeard.isEmpty {
                Text("Heard: “\(model.lastHeard)”")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            HStack(spacing: 10) {
                Button { model.toggleListening() } label: {
                    Image(systemName: model.listening ? "mic.fill" : "mic.slash")
                }
                .buttonStyle(.bordered)
                .tint(model.listening ? .green : .gray)

                TextField("Or type what you'd say", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit {
                        model.heard(typed)
                        typed = ""
                    }

                Button("Hide outline") { model.clearOutline() }
                    .buttonStyle(.bordered)
                    .disabled(!model.hasOutline)

                Button("Headset view") { model.enterHeadset() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var status: String {
        if let problem = model.problem { return problem }
        if !model.pageFound { return "Point the camera at your paper" }
        if model.working { return "Working on it…" }
        if model.usingMock { return "Page found · mock AI (add your key in Settings)" }
        return model.listening ? "Page found · listening" : "Page found · tap the mic or type"
    }
}
