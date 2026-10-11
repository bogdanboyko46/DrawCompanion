import SwiftUI

/// Hands-free control in AR. Every button still works; these do the same
/// things with a gesture:
///
///   snap your fingers   scan the drawing in the frame and bring it to life
///   just talk           the character answers (it's always listening)
///   say "shhh"           the character stops talking
///   open palm           the characters wave hello
///   point at the table  the character walks there
///   thumbs up / clap    the characters cheer
///   peace sign          take a photo
extension AppModel {
    func setUpGestures() {
        scene.onFrame = { [weak self] frame in
            guard let self else { return }
            self.hands.process(frame, toView: self.scene.viewMapper(for: frame))
        }
        sounds.onSound = { [weak self] sound in
            switch sound {
            case .snap: self?.snapToScan()
            case .clap:
                if self?.phase == .ready { self?.flash("👏"); self?.summon() } else { self?.cheer(flash: "👏") }
            case .shush: self?.shush()
            }
        }
        hands.onBegan = { [weak self] pose in self?.handBegan(pose) }
        hands.onEnded = { [weak self] pose in self?.handEnded(pose) }
        hands.onPointing = { [weak self] tip in self?.pointed(at: tip) }
        sounds.start()
        // Anyone out in the room can be talked to, including a companion while a new one is made.
        talk.start(in: scene, hearing: sounds.speech) { [weak self] in
            guard let self else { return false }
            return self.phase != .capturing && self.sounds.running
        }
    }

    // MARK: Gestures

    private func snapToScan() {
        guard countdown == nil, phase == .scanning || phase == .alive else { return }
        flash("🫰")
        // After a failure, a snap retries that character instead of scanning again.
        if failedJobID != nil {
            retryFailed()
            return
        }
        // A beat to get your hand out of the shot.
        countdown = 1
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            countdown = nil
            bringToLife()
        }
    }

    private func handBegan(_ pose: HandGestures.Pose) {
        switch pose {
        case .palm:
            guard hasCharacters else { return }
            flash("👋")
            for character in scene.actors { character.express("greet") }
        case .thumbsUp:
            if phase == .ready { flash("👍"); summon() } else { cheer(flash: "👍") }
        case .peace:
            guard hasCharacters else { return }
            flash("✌️")
            takeSnapshot()
        case .point:
            if hasCharacters { flash("👉") }
        }
    }

    private func handEnded(_ pose: HandGestures.Pose) {}

    /// "Shhh" → whoever's talking stops.
    private func shush() {
        guard hasCharacters else { return }
        flash("🤫")
        talk.interrupt()
    }

    private func pointed(at tip: CGPoint) {
        // Re-aim twice a second while you keep pointing.
        guard Date().timeIntervalSince(lastPointWalk) > 0.5,
              let character = scene.actors.last,
              let spot = scene.surfacePoint(at: tip) else { return }
        lastPointWalk = Date()
        character.walk(toWorld: spot)
    }

    private func cheer(flash emoji: String) {
        guard hasCharacters else { return }
        flash(emoji)
        for character in scene.actors { character.express("happy") }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func flash(_ emoji: String) {
        withAnimation(.spring(duration: 0.25)) { gestureFlash = emoji }
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation(.easeOut(duration: 0.3)) { if gestureFlash == emoji { gestureFlash = nil } }
        }
    }
}
