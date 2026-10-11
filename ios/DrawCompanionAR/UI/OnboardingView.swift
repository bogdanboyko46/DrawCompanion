import SwiftUI

/// First launch: what the app does, access to camera/mic/speech, the Claude
/// API key, finding the paper, and what to say. Skippable; shown once (and
/// again from Settings › Show welcome).
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, access, key, paper, talk }

    @EnvironmentObject var model: AppModel
    @AppStorage(AppSettings.onboarded) private var onboarded = false
    @State private var step: Step = .welcome

    var body: some View {
        ZStack {
            // The paper step shows the live camera; the others dim it.
            Rectangle()
                .fill(.black.opacity(step == .paper ? 0 : 0.55))
                .background(step == .paper ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Material.ultraThinMaterial))
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: step)

            VStack(spacing: 0) {
                HStack {
                    Dots(count: Step.allCases.count, current: step.rawValue)
                    Spacer()
                    if step != .talk {
                        Button("Skip") { finish() }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)

                Group {
                    switch step {
                    case .welcome: WelcomeStep(next: next)
                    case .access: AccessStep(next: next)
                    case .key: KeyStep(next: next)
                    case .paper: PaperStep(next: next)
                    case .talk: TalkStep(done: finish)
                    }
                }
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
    }

    private func next() {
        withAnimation(.spring(duration: 0.45)) {
            step = Step(rawValue: step.rawValue + 1) ?? .talk
        }
        if step == .paper || step == .key, Permissions.camera == .granted { Launch.start(model) }
    }

    private func finish() {
        onboarded = true
    }
}

// MARK: steps

private struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        HStack(spacing: 40) {
            AppMark().frame(width: 150, height: 150)
            VStack(alignment: .leading, spacing: 14) {
                Text("DrawCompanion")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Draw on real paper. When you're stuck, just say so, and an outline appears right on your page for you to trace.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    Feature(icon: "waveform", text: "Always listening. Talk naturally; it ignores chatter.")
                    Feature(icon: "scribble.variable", text: "Outlines match your pencil and stay on the paper.")
                    Feature(icon: "hand.draw", text: "Trace it. It fades 3 s after you stop.")
                }
                PrimaryButton(title: "Get started", action: next)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(.horizontal, 32)
    }
}

private struct AccessStep: View {
    let next: () -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var refresh = 0
    @State private var asking = false

    var body: some View {
        let _ = refresh
        StepLayout(icon: "lock.shield", title: "Three permissions", subtitle: "Nothing is recorded or saved. Speech is turned into text on this iPhone when it can be.") {
            VStack(spacing: 10) {
                AccessRow(icon: "camera.fill", title: "Camera", reason: "To see your paper and draw outlines on it.", status: Permissions.camera)
                AccessRow(icon: "mic.fill", title: "Microphone", reason: "To hear you while the app is open.", status: Permissions.microphone)
                AccessRow(icon: "waveform", title: "Speech recognition", reason: "To turn what you say into requests.", status: Permissions.speech)
            }
            if Permissions.allGranted {
                PrimaryButton(title: "Continue", action: next)
            } else if [Permissions.camera, Permissions.microphone, Permissions.speech].contains(.notAsked) {
                PrimaryButton(title: asking ? "Asking…" : "Allow access") {
                    asking = true
                    Task {
                        await Permissions.requestAll()
                        asking = false
                        refresh += 1
                        if Permissions.camera == .granted { Launch.start(model) }
                        if Permissions.allGranted { next() }
                    }
                }
                .disabled(asking)
            } else {
                HStack(spacing: 12) {
                    PrimaryButton(title: "Open Settings") { Permissions.openSettings() }
                    SecondaryButton(title: "Continue anyway", action: next)
                }
            }
        }
        .onChange(of: phase) { _, _ in refresh += 1 }
    }
}

private struct KeyStep: View {
    let next: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var hasKey = Keychain.apiKey != nil

    var body: some View {
        StepLayout(icon: "key.fill", title: "Your Claude API key", subtitle: "DrawCompanion asks Claude for each outline. Create a key at console.anthropic.com › API keys and paste it here. It stays in this iPhone's Keychain and is sent only to Anthropic.") {
            if hasKey {
                Label("Key saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                PrimaryButton(title: "Continue", action: next)
            } else {
                KeyEntry { model.refreshKey(); hasKey = true; next() }
                Button("Skip for now: try the sample AI (it draws a flower)", action: next)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

private struct PaperStep: View {
    let next: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var sweep = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(model.pageFound ? Color.green : Color.white.opacity(0.8),
                                  style: StrokeStyle(lineWidth: 2.5, dash: model.pageFound ? [] : [10, 8], dashPhase: sweep ? 36 : 0))
                    .frame(width: 210, height: 150)
                    .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: sweep)
                if model.pageFound {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.4), value: model.pageFound)
            VStack(spacing: 6) {
                Text(model.pageFound ? "Found your paper" : "Point the camera at your paper")
                    .font(.title3.weight(.semibold))
                Text(model.pageFound ? "Keep it in view while you draw. It can move; the outline moves with it."
                                     : "A plain sheet on a darker table works best. Get the whole page in view.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if model.pageFound {
                PrimaryButton(title: "Continue", action: next)
            } else {
                SecondaryButton(title: "Continue without paper", action: next)
            }
            Spacer()
        }
        .onAppear {
            Launch.start(model)
            sweep = true
        }
    }
}

private struct TalkStep: View {
    let done: () -> Void

    var body: some View {
        StepLayout(icon: "bubble.left.and.text.bubble.right.fill", title: "Now just say it", subtitle: "No buttons needed. Pause briefly when you're done; it never talks back, it just draws.") {
            VStack(alignment: .leading, spacing: 8) {
                Example(said: "“I'm stuck… maybe add a cat on the windowsill?”", does: "new outline")
                Example(said: "“Bigger, and facing left.”", does: "changes it")
                Example(said: "“Clear it.”", does: "removes it")
            }
            if AppModel.headsetAvailable {
            Text("Using a headset viewer? Tap **Headset view**, slide the phone in, and talk. Double-tap the screen (or the viewer's button twice) to come back.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            }
            PrimaryButton(title: "Start drawing", action: done)
        }
    }
}

// MARK: building blocks

/// Icon on the left, text and controls on the right: fits a landscape phone.
private struct StepLayout<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 36) {
            Image(systemName: icon)
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(Color.brand)
                .frame(width: 130)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    content
                }
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: 460)
        }
        .padding(.horizontal, 32)
    }
}

private struct Feature: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.85))
        } icon: {
            Image(systemName: icon).foregroundStyle(Color.brand).frame(width: 22)
        }
    }
}

private struct AccessRow: View {
    let icon: String
    let title: String
    let reason: String
    let status: Permissions.Status

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(reason).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            switch status {
            case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied: Text("Off").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            case .notAsked: EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct Example: View {
    let said: String
    let does: String

    var body: some View {
        HStack {
            Text(said).font(.subheadline)
            Spacer(minLength: 12)
            Text(does).font(.caption).foregroundStyle(Color.brand)
        }
    }
}

private struct Dots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.brand : Color.white.opacity(0.3))
                    .frame(width: i == current ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(duration: 0.4), value: current)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 26)
                .frame(height: 46)
                .background(Color.brand, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 46)
                .background(.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The app's mark, drawn in SwiftUI so it needs no image: a sheet of paper
/// with a glowing dashed outline and a pencil line tracing part of it.
struct AppMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.08, style: .continuous)
                    .fill(Color(white: 0.96))
                    .frame(width: s * 0.72, height: s * 0.86)
                    .rotationEffect(.degrees(-6))
                    .shadow(color: .black.opacity(0.4), radius: s * 0.06, y: s * 0.03)
                Star()
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: s * 0.03, lineCap: .round, dash: [s * 0.05, s * 0.045]))
                    .frame(width: s * 0.5, height: s * 0.5)
                    .shadow(color: Color.brand.opacity(0.8), radius: s * 0.03)
                    .rotationEffect(.degrees(-6))
                Star()
                    .trim(from: 0, to: 0.42)
                    .stroke(Color(white: 0.18), style: StrokeStyle(lineWidth: s * 0.022, lineCap: .round, lineJoin: .round))
                    .frame(width: s * 0.5, height: s * 0.5)
                    .rotationEffect(.degrees(-6))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }
}

/// A soft five-pointed star (the outline in the app mark).
struct Star: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.48
        var points: [CGPoint] = []
        for i in 0..<10 {
            let r: CGFloat = i.isMultiple(of: 2) ? outer : inner
            let a = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 5
            points.append(CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
        }
        var p = Path()
        p.addLines(points)
        p.closeSubpath()
        return p
    }
}
