import SwiftUI

/// Hold to talk to the character in the room; what you say shows beside it.
struct TalkButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let talk = model.talk
        HStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 0)
            if !talk.caption.isEmpty || talk.state == .listening {
                caption(talk)
                    .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
            }
            mic(talk)
        }
        .animation(.spring(duration: 0.3), value: talk.caption.isEmpty)
        .animation(.spring(duration: 0.3), value: talk.state)
    }

    private func caption(_ talk: Conversation) -> some View {
        HStack(spacing: 8) {
            Text(talk.caption.isEmpty ? "Listening…" : talk.caption)
                .font(.callout.weight(.medium))
                .foregroundStyle(talk.caption.isEmpty ? .secondary : .primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            if talk.needsSettings {
                Button("Settings") { talk.openSettings() }
                    .font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 280, alignment: .trailing)
    }

    private func mic(_ talk: Conversation) -> some View {
        let listening = talk.state == .listening
        return ZStack {
            Circle()
                .fill(listening
                      ? AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.55, blue: 0.2), Color(red: 0.95, green: 0.3, blue: 0.55)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                      : AnyShapeStyle(.ultraThinMaterial))
            if talk.state == .thinking {
                ProgressView()
            } else {
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(listening ? .white : .primary)
                    .symbolEffect(.variableColor.iterative, isActive: listening)
            }
        }
        .frame(width: 60, height: 60)
        .scaleEffect(listening ? 1.15 : 1)
        .shadow(color: .black.opacity(listening ? 0.3 : 0.15), radius: listening ? 10 : 4)
        .contentShape(Circle())
        // Pressing starts listening and letting go sends; dragging far off cancels into a send too.
        .onLongPressGesture(minimumDuration: 60, maximumDistance: 120) {
            talk.release()
        } onPressingChanged: { pressing in
            if pressing { talk.press(in: model.scene) } else { talk.release() }
        }
        .accessibilityLabel("Talk to your character")
        .accessibilityHint("Hold while you speak, then let go.")
        .accessibilityAddTraits(.isButton)
    }
}
