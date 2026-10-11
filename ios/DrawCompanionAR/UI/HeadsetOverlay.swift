import SwiftUI

/// Headset view: nothing but your page, the outline, and a small status dot
/// low in each eye. Green = listening, pulsing blue = working on what you
/// said, orange = can't see the page, grey = microphone off. Text appears
/// only for setup problems. Double-tap (the viewer's button twice) to exit.
struct HeadsetOverlay: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.displayScale) private var displayScale
    /// Bumped when settings change, so the dot follows the lens layout.
    @State private var settingsVersion = 0

    var body: some View {
        GeometryReader { geo in
            let optics = HeadsetOptics(defaults: .standard)
            let layout = optics.layout(screenWidth: geo.size.width * displayScale, screenHeight: geo.size.height * displayScale)
            ZStack {
                ForEach(0..<layout.eyes.count, id: \.self) { i in
                    eye(at: { x, y in
                        let p = optics.screenPoint(eye: layout.eyes[i], layout: layout, eyeTanX: x, eyeTanY: y)
                        return CGPoint(x: p.x / displayScale, y: p.y / displayScale)
                    }, textWidth: optics.fieldTan * layout.pixelsPerTan / displayScale)
                }
            }
            .id(settingsVersion)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.exitHeadset() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            settingsVersion += 1
        }
    }

    /// The dot and any problem text, placed low in what this eye sees through
    /// its lens (`point` maps a direction seen by the eye, in tan units, to
    /// screen points), so they're inside the field, not lost past its edge.
    @ViewBuilder
    private func eye(at point: (Double, Double) -> CGPoint, textWidth: Double) -> some View {
        if let problem = model.problem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .frame(width: max(80, textWidth))
                .position(point(0, 0.42))
        }
        StatusDot()
            .position(point(0, 0.6))
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
