import AVFoundation
import Observation
import Speech
import UIKit

/// Always listening: whenever a character is out in the room you just talk,
/// and after a short pause it answers in its own voice (Claude writes the
/// line). The mic is ignored while a character speaks so it doesn't hear
/// itself; "shhh" cuts it off.
@MainActor
@Observable
final class Conversation {
    enum State: Equatable { case idle, listening, thinking }

    private(set) var state: State = .idle
    /// Your words as they're recognized, or a short note (permissions, nothing heard).
    private(set) var caption = ""
    /// The caption is about a permission that only the Settings app can fix.
    private(set) var needsSettings = false

    @ObservationIgnored private var histories: [String: [ChatTurn]] = [:]
    @ObservationIgnored private let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private var sink: SpeechSink?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var heard = ""
    @ObservationIgnored private var heardAt = Date()
    @ObservationIgnored private var heardFinal = false
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var listener: CharacterActor?
    @ObservationIgnored private var captionClear: Task<Void, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private weak var scene: SceneController?
    /// Bumped by "shhh": a reply still on its way is dropped.
    @ObservationIgnored private var turn = 0
    @ObservationIgnored private var askedPermission = false

    /// Turns kept per character and sent with each question.
    private let historyLength = 6
    /// Quiet after your last word that ends what you're saying.
    private let endOfSentence: TimeInterval = 1.3

    // MARK: Always on

    /// Listens for the rest of the app's life, whenever `canTalk` says someone's there.
    func start(in scene: SceneController, hearing sink: SpeechSink, canTalk: @escaping @MainActor () -> Bool) {
        self.sink = sink
        self.scene = scene
        loop?.cancel()
        loop = Task { [weak self, weak scene] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, let scene else { return }
                self.tick(scene, canTalk: canTalk())
            }
        }
    }

    /// "Shhh": the character stops talking (and forgets what it was about to say).
    func interrupt() {
        turn += 1
        CharacterVoice.shared.stop()
        if state == .thinking { state = .idle }
        // The hiss itself was probably half-heard as words.
        stopRecognizing()
        caption = ""
    }

    private func tick(_ scene: SceneController, canTalk: Bool) {
        guard state != .thinking else { return }
        let someone = canTalk && scene.actors.contains { $0.root.isEnabled }
        guard someone, !CharacterVoice.shared.isBusy, permitted() else {
            if state == .listening { stopRecognizing(); caption = "" }
            return
        }
        guard state == .listening, request != nil else { return beginRecognizing() }

        let said = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if said.contains(where: \.isLetter) {
            if heardFinal || Date().timeIntervalSince(heardAt) > endOfSentence {
                stopRecognizing()
                Task { await answer(said, in: scene) }
            }
        } else if heardFinal || Date().timeIntervalSince(startedAt) > 50 {
            // Recognition gives up after a stretch of silence (and can't run
            // past a minute): start a fresh one.
            stopRecognizing()
        }
    }

    // MARK: Listening

    private func beginRecognizing() {
        guard let recognizer, recognizer.isAvailable, let sink else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // On-device keeps your voice on the phone, and it's faster.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        heard = ""
        heardFinal = false
        startedAt = Date()
        heardAt = Date()
        recognition = Self.recognize(request, with: recognizer) { [weak self] text, final in
            guard let self, self.request === request, self.state == .listening else { return }
            if let text, text != self.heard {
                if self.heard.isEmpty, !text.isEmpty { self.attend() }
                self.heard = text
                self.heardAt = Date()
                self.caption = text
            }
            if final { self.heardFinal = true }
        }
        sink.attach(request)
        state = .listening
    }

    private func stopRecognizing() {
        sink?.attach(nil)
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        if state == .listening { state = .idle }
    }

    /// Someone started talking: the character you're facing turns to listen.
    private func attend() {
        guard let scene, let character = Self.facing(in: scene) else { return }
        listener = character
        character.listen()
    }

    private nonisolated static func recognize(
        _ request: SFSpeechAudioBufferRecognitionRequest, with recognizer: SFSpeechRecognizer,
        update: @escaping @MainActor (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in update(text, final) }
        }
    }

    // MARK: Answering

    private func answer(_ said: String, in scene: SceneController) async {
        guard let character = Self.facing(in: scene) else { return clearCaption(after: 1) }
        print("[talk] heard: \(said)")
        listener = character
        caption = said
        state = .thinking
        let myTurn = turn
        character.listen()
        character.ponder()

        let id = character.job.id
        let info = character.job.character ?? CharacterInfo(
            name: character.name, summary: "A friendly little character.", greeting: "Hi!", bodyPlan: "other",
            heightMeters: 0.5, figureBox: Box(x: 0, y: 0, w: 1, h: 1), colors: [], personality: character.personality)
        let history = histories[id] ?? []

        guard let key = Keys.value(Keys.anthropic) else {
            state = .idle
            character.answer(character.personality.friendliness < 0.4 ? "…hm?" : "Hmm? I can't talk yet!")
            return note("Add your Anthropic API key so characters can talk back.")
        }
        do {
            let reply = try await ClaudeDirector(apiKey: key).reply(to: said, as: info, history: history)
            guard turn == myTurn else { return } // shushed meanwhile
            histories[id] = Array((history + [ChatTurn(fromUser: true, text: said), ChatTurn(fromUser: false, text: reply)])
                .suffix(historyLength))
            state = .idle
            guard character.anchor.parent != nil else { return clearCaption(after: 0.5) }
            character.answer(reply)
            clearCaption(after: 1.5)
        } catch {
            print("[talk] reply failed: \(error.localizedDescription)")
            guard turn == myTurn else { return }
            state = .idle
            character.answer("Hmm? Say that again?")
            note("Couldn't reach Claude: \(error.localizedDescription)")
        }
    }

    // MARK: Whom you're talking to

    /// The character nearest the middle of the screen, or the newest one.
    private static func facing(in scene: SceneController) -> CharacterActor? {
        let view = scene.arView
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        // Only characters actually out in the room (one may be loaded, still hidden in the paper).
        let present = scene.actors.filter { $0.root.isEnabled }
        let onScreen = present.compactMap { actor -> (CharacterActor, CGFloat)? in
            guard let p = view.project(actor.headWorldPosition), view.bounds.contains(p) else { return nil }
            return (actor, hypot(p.x - center.x, p.y - center.y))
        }
        return onScreen.min { $0.1 < $1.1 }?.0 ?? present.last
    }

    // MARK: Permissions

    /// True if both are granted. Otherwise asks once (first use) or explains once.
    private func permitted() -> Bool {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVAudioApplication.shared.recordPermission
        if speech == .authorized && mic == .granted { return true }
        guard !askedPermission else { return false }
        askedPermission = true

        if speech == .denied || speech == .restricted || mic == .denied {
            needsSettings = speech != .restricted
            note(speech == .restricted
                 ? "Speech recognition is turned off on this device."
                 : "To talk with your character, allow the microphone and speech recognition in Settings.",
                 for: 6)
            return false
        }
        Task {
            let micOK = mic == .granted ? true : await AVAudioApplication.requestRecordPermission()
            let speechOK = speech == .authorized ? true : await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
            if !(micOK && speechOK) {
                needsSettings = true
                note("No problem. To talk later, allow the microphone and speech recognition in Settings.", for: 6)
            }
        }
        return false
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    // MARK: Caption

    private func note(_ text: String, for seconds: Double = 3.5) {
        captionClear?.cancel()
        caption = text
        clearCaption(after: seconds)
    }

    private func clearCaption(after seconds: Double) {
        captionClear?.cancel()
        captionClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.state == .idle else { return }
            self.caption = ""
            self.needsSettings = false
        }
    }
}
