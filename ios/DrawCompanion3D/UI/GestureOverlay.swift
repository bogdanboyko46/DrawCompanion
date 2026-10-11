import SwiftUI

/// The gesture cheat sheet, and a big flash when a gesture is recognized.
struct GestureOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let emoji = model.gestureFlash {
                Text(emoji)
                    .font(.system(size: 96))
                    .shadow(color: .black.opacity(0.3), radius: 12)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            VStack {
                Spacer().frame(height: 64)
                hints
                Spacer()
            }
        }
        .allowsHitTesting(false)
    }

    private var hints: some View {
        HStack(spacing: 10) {
            hint("🫰", model.hasCharacters ? "new" : "scan")
            if model.hasCharacters {
                hint("✋", "talk")
                hint("👉", "move")
                hint("👍", "cheer")
                hint("✌️", "photo")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func hint(_ emoji: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(emoji).font(.callout)
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}
