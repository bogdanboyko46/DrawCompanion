import SwiftUI

/// One small pill at the bottom that says what's happening and which gesture
/// does what next.
struct StatusPill: View {
    @Environment(AppModel.self) private var model
    @State private var started = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 6) {
                Text(text(at: context.date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                if model.phase == .making {
                    ProgressView(value: model.job?.progress ?? 0.02)
                        .tint(.white)
                        .frame(width: 180)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.black.opacity(0.35), in: Capsule())
            .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
            .animation(.easeInOut(duration: 0.25), value: text(at: context.date))
        }
        .onChange(of: model.phase) { _, phase in if phase == .making { started = Date() } }
    }

    private func text(at date: Date) -> String {
        if let error = model.errorMessage { return "⚠️ \(error)  ·  🫰 snap to try again" }
        let name = model.job?.character?.name
        switch model.phase {
        case .scanning:
            return "🫰 Snap to bring the drawing in the frame to life"
        case .capturing:
            return "📸 Capturing…"
        case .making:
            let stage = GenerationStage(rawValue: model.job?.stage ?? "")?.title ?? "Starting"
            let company = model.scene.actors.first { $0.root.isEnabled }.map { "  ·  🤫 talk to \($0.name) while you wait" } ?? ""
            return "\(name.map { "\($0): " } ?? "")\(stage)… \(remaining(at: date))\(company)"
        case .ready:
            return "👏 Clap to bring \(name ?? "them") out of the paper"
        case .alive:
            return "🤫 shhh to talk  ·  👉 point  ·  👍 cheer  ·  ✌️ photo  ·  🫰 new"
        }
    }

    /// A rough countdown: blend the typical total with what progress so far implies.
    private func remaining(at date: Date) -> String {
        let spent = date.timeIntervalSince(started)
        let p = max(0.02, model.job?.progress ?? 0)
        let typical = model.useServer ? 300.0 : 85.0
        let total = p < 0.3 ? typical : (typical + spent / p) / 2
        let left = max(5, total - spent)
        return left < 60 ? "almost there" : "about \(Int((left / 60).rounded(.up))) min"
    }
}

/// What you're saying while talking to a character, and that it's thinking.
struct TalkCaption: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let talk = model.talk
        Group {
            switch talk.state {
            case .listening:
                pill("🎙️ " + (talk.caption.isEmpty ? "Listening…" : talk.caption))
            case .thinking:
                pill("💭 " + (talk.caption.isEmpty ? "Thinking…" : talk.caption))
            case .idle:
                if !talk.caption.isEmpty { pill(talk.caption) }
            }
        }
        .animation(.spring(duration: 0.3), value: talk.state)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.black.opacity(0.45), in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
