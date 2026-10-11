import SwiftUI

/// Hands-free control in AR. Every button still works; these do the same
/// things with a gesture:
///
///   snap your fingers   scan the drawing in the frame and bring it to life
///   say "shhh"           the character listens; talk, then pause and it answers
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
            case .clap: self?.cheer(flash: "👏")
            case .shush: self?.shushToTalk()
            }
        }
        hands.onBegan = { [weak self] pose in self?.handBegan(pose) }
        hands.onEnded = { [weak self] pose in self?.handEnded(pose) }
        hands.onPointing = { [weak self] tip in self?.pointed(at: tip) }
        sounds.start()
    }

    // MARK: Talking (shared by the mic button and the open palm)

    func startTalking() {
        guard talk.state == .idle else { return }
        sounds.pause() // speech recognition needs the mic
        talk.press(in: scene)
        if talk.state != .listening { sounds.resume() }
    }

    func stopTalking() {
        guard talk.state == .listening else { return }
        talk.release()
        sounds.resume()
    }

    // MARK: Gestures

    private func snapToScan() {
        guard countdown == nil, phase == .scanning || phase == .alive else { return }
        flash("🫰")
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
            cheer(flash: "👍")
        case .peace:
            guard hasCharacters else { return }
            flash("✌️")
            takeSnapshot()
        case .point:
            if hasCharacters { flash("👉") }
        }
    }

    private func handEnded(_ pose: HandGestures.Pose) {}

    /// "Shhh" → the character listens. You talk; a pause of about 1.5 s after
    /// your last word sends it (or 6 s of nothing cancels).
    private func shushToTalk() {
        guard phase == .alive, hasCharacters, talk.state == .idle else { return }
        flash("🤫")
        startTalking()
        guard talk.state == .listening else { return }
        Task {
            var lastText = "", lastChange = Date(), started = Date()
            while talk.state == .listening {
                try? await Task.sleep(for: .milliseconds(250))
                if talk.caption != lastText { lastText = talk.caption; lastChange = Date() }
                let quietFor = Date().timeIntervalSince(lastChange)
                if !lastText.isEmpty && quietFor > 1.5 { break }
                if lastText.isEmpty && Date().timeIntervalSince(started) > 6 { break }
            }
            stopTalking()
        }
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
