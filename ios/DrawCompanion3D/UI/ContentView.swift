import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            ARViewContainer(scene: model.scene)
                .ignoresSafeArea()

            if showOutline {
                ReticleView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            SpeechLayer()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if !model.isRecording && model.phase != .making {
                GestureOverlay()
            }

            if model.isRecording {
                RecordingBar()
            } else {
                chrome
            }
        }
        .animation(.spring(duration: 0.4), value: model.phase)
        .sheet(isPresented: $model.showLibrary) { LibraryView() }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .sheet(item: $model.snapshot) { SnapshotView(item: $0) }
        .sheet(item: $model.recording) { RecordingPreview(controller: $0.controller).ignoresSafeArea() }
    }

    private var showOutline: Bool {
        (model.phase == .scanning || model.phase == .alive) && !model.isRecording
    }

    private var chrome: some View {
        VStack(spacing: 12) {
            TopBar()
            Spacer()
            if model.phase == .alive {
                TalkButton()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let error = model.errorMessage {
                ErrorBanner(message: error)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            switch model.phase {
            case .scanning, .alive:
                CapturePanel()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .capturing:
                Label("Capturing your page…", systemImage: "camera.aperture")
                    .font(.headline)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: Capsule())
            case .making:
                GenerationCard()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

private struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Label("DrawCompanion", systemImage: "pencil.and.scribble")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            if model.phase == .alive {
                CircleButton(symbol: "camera") { model.takeSnapshot() }
                CircleButton(symbol: "record.circle") { model.toggleRecording() }
            }
            CircleButton(symbol: "square.grid.2x2") {
                model.refreshLibrary()
                model.showLibrary = true
            }
            CircleButton(symbol: "gearshape") { model.showSettings = true }
        }
    }
}

struct CircleButton: View {
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct CapturePanel: View {
    @Environment(AppModel.self) private var model
    @FocusState private var typing: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 10) {
            Text(prompt)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("Tell it who it is (optional)", text: $model.hint)
                .focused($typing)
                .submitLabel(.done)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            Button {
                typing = false
                model.bringToLife()
            } label: {
                Label(model.hasCharacters ? "Bring another to life" : "Bring it to life", systemImage: "sparkles")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        LinearGradient(colors: [Color(red: 1, green: 0.55, blue: 0.2), Color(red: 0.95, green: 0.3, blue: 0.55)],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var prompt: String {
        if model.hasCharacters { return "Tap the table to call it over. Tap it to say hi. Pinch to resize." }
        return "Center a drawing in the frame, then tap below."
    }
}

private struct ErrorBanner: View {
    @Environment(AppModel.self) private var model
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if model.failedJobID != nil {
                Button("Retry") { model.retryFailed() }.font(.callout.weight(.semibold))
            }
            Button {
                model.dismissError()
            } label: {
                Image(systemName: "xmark").font(.callout.weight(.semibold))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct RecordingBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            Spacer()
            Button {
                model.toggleRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.headline)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 24)
        }
    }
}
