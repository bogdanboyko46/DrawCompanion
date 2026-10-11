import SwiftUI

/// The character is done and waiting in the paper: clap to bring it out.
struct ReadyPrompt: View {
    @Environment(AppModel.self) private var model
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 12) {
            Text("👏").font(.system(size: 44)).scaleEffect(pulse ? 1.15 : 0.95)
            Text("\(model.job?.displayName ?? "Your character") is ready!")
                .font(.title3.weight(.bold))
            Text("Clap to bring them out of the paper")
                .font(.callout).foregroundStyle(.secondary)
            Button {
                model.summon()
            } label: {
                Text("Bring them out").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.95, green: 0.45, blue: 0.25))
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { pulse = true } }
    }
}
