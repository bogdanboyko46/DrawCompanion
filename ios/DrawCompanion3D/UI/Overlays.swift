import ReplayKit
import SwiftUI

/// The capture frame: corner brackets in the middle of the screen, with the
/// rest of the view dimmed so it's clear only what's inside gets scanned.
struct ReticleView: View {
    var body: some View {
        GeometryReader { geo in
            let r = Reticle.rect(in: geo.size)
            ZStack {
                // Dim everything outside the frame.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRoundedRect(in: r, cornerSize: CGSize(width: 18, height: 18))
                }
                .fill(Color.black.opacity(0.28), style: FillStyle(eoFill: true))

                Brackets()
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .shadow(color: .black.opacity(0.35), radius: 3)

                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
                    .position(x: r.midX, y: r.midY)


            }
        }
    }
}

private struct Brackets: Shape {
    func path(in r: CGRect) -> Path {
        let len = min(r.width, r.height) * 0.16
        var p = Path()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0), (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x + dx * len, y: corner.y))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * len))
        }
        return p
    }
}

/// Where a speech bubble attaches: a point beside the character's face, and
/// which side of the character it's on.
struct BubbleSpot: Equatable {
    var point: CGPoint
    var onRight: Bool
}

/// Speech bubbles that follow each character, beside its face (never over it).
struct SpeechLayer: View {
    // Reads the model itself so 30 Hz head updates only re-render this layer.
    @Environment(AppModel.self) private var model

    var body: some View {
        let lines = Array(model.speech.values)
        let heads = model.heads
        GeometryReader { _ in
            ForEach(lines) { line in
                if let spot = heads[line.characterID] {
                    SpeechBubble(name: line.name, text: line.text, pointsLeft: spot.onRight)
                        .fixedSize()
                        // A zero-size frame pins the bubble's near edge to the spot.
                        .frame(width: 0, height: 0, alignment: spot.onRight ? .leading : .trailing)
                        .position(spot.point)
                        .transition(.scale(scale: 0.6, anchor: spot.onRight ? .leading : .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.4), value: lines.map(\.id))
    }
}

struct SpeechBubble: View {
    var name: String
    var text: String
    /// The pointer faces the character: left when the bubble is on its right.
    var pointsLeft = true

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
        .frame(maxWidth: 220, alignment: .leading)
        .overlay(alignment: pointsLeft ? .leading : .trailing) {
            Triangle().fill(.white).frame(width: 14, height: 8)
                .rotationEffect(.degrees(pointsLeft ? 90 : -90))
                .offset(x: pointsLeft ? -10 : 10)
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
