import SwiftUI

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
