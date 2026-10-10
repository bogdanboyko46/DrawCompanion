import ReplayKit
import SwiftUI

/// A glowing outline on the detected paper, so you know it's been found.
struct PageOutline: View {
    var points: [CGPoint]

    var body: some View {
        TimelineView(.animation) { timeline in
            canvas(pulse: 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 5.5))
        }
    }

    private func canvas(pulse: Double) -> some View {
        Canvas { context, _ in
            guard points.count == 4 else { return }
            var path = Path()
            path.addLines(points)
            path.closeSubpath()
            let color = Color(red: 1, green: 0.7, blue: 0.35)
            context.fill(path, with: .color(color.opacity(0.05 + 0.08 * pulse)))
            context.stroke(path, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: 10, lineJoin: .round))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            // Corner ticks.
            for p in points {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.white))
            }
        }
    }
}

/// Speech bubbles that follow each character's head.
struct SpeechLayer: View {
    // Reads the model itself so 30 Hz head updates only re-render this layer.
    @Environment(AppModel.self) private var model

    var body: some View {
        let lines = Array(model.speech.values)
        let heads = model.heads
        GeometryReader { _ in
            ForEach(lines) { line in
                if let p = heads[line.characterID] {
                    SpeechBubble(name: line.name, text: line.text)
                        .fixedSize()
                        .position(x: p.x, y: p.y - 34)
                        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.4), value: lines.map(\.id))
    }
}

struct SpeechBubble: View {
    var name: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.2))
            Text(text)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.black)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottom) {
            Triangle().fill(.white).frame(width: 14, height: 8).offset(y: 7)
        }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

struct SnapshotView: View {
    var item: SnapshotItem
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(uiImage: item.image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal)
                HStack(spacing: 12) {
                    ShareLink(item: Image(uiImage: item.image), preview: SharePreview("My character", image: Image(uiImage: item.image))) {
                        Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        UIImageWriteToSavedPhotosAlbum(item.image, nil, nil, nil)
                        saved = true
                    } label: {
                        Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark" : "arrow.down.to.line").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(saved)
                }
                .padding(.horizontal)
            }
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

/// Hosts ReplayKit's own editor/share screen for a recording.
struct RecordingPreview: UIViewControllerRepresentable {
    let controller: RPPreviewViewController
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    func makeUIViewController(context: Context) -> RPPreviewViewController {
        controller.previewControllerDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: RPPreviewViewController, context: Context) {}

    final class Coordinator: NSObject, RPPreviewViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
            DispatchQueue.main.async { self.dismiss() }
        }
    }
}
