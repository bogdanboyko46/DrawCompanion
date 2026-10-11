import SwiftUI

/// A big emoji flash when a gesture is recognized.
struct GestureFlash: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let emoji = model.gestureFlash {
                Text(emoji)
                    .font(.system(size: 96))
                    .shadow(color: .black.opacity(0.3), radius: 12)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
    }
}
