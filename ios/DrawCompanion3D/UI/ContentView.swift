import SwiftUI

/// Everything happens in AR: no buttons. The camera view carries only the scan
/// frame, speech bubbles, a gesture flash, and one status pill that says what
/// to do next (snap, clap, talk…).
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            ARViewContainer(scene: model.scene)
                .ignoresSafeArea()

            if model.phase == .scanning || model.phase == .alive {
                ReticleView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            SpeechLayer()
                .ignoresSafeArea()

            GestureFlash()

            VStack(spacing: 8) {
                Spacer()
                TalkCaption()
                StatusPill()
            }
            .padding(.bottom, 14)
            .padding(.horizontal, 24)
        }
        .allowsHitTesting(false)
        .animation(.spring(duration: 0.4), value: model.phase)
    }
}
