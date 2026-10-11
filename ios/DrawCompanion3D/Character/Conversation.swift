import AVFoundation
import Observation
import Speech
import UIKit

/// Hold-to-talk with a character: on-device speech recognition while the
/// button is held, then Claude answers in the character's voice.
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
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var heardFinal = false
    @ObservationIgnored private var listener: CharacterActor?
    @ObservationIgnored private var captionClear: Task<Void, Never>?

    /// Turns kept per character and sent with each question.
    private let historyLength = 6

    // MARK: Button

    func press(in scene: SceneController) {
        guard state == .idle else { return }
        guard permitted() else { return }
        guard let character = Self.facing(in: scene) else { return }
        guard let recognizer, recognizer.isAvailable else {
            return note("Speech recognition isn't available right now. Try again in a moment.")
        }

        CharacterVoice.shared.stop()
        listener = character
        character.listen()
        do {
            try startRecognizing(with: recognizer)
        } catch {
            print("[talk] couldn't start listening: \(error.localizedDescription)")
            stopAudio()
            return note("The microphone couldn't start. Try again in a moment.")
        }
        captionClear?.cancel()
        needsSettings = false
        caption = ""
        state = .listening
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func release() {
        guard state == .listening else { return }
        state = .thinking
        request?.endAudio()
        stopAudio()
        Task { await finish() }
    }

    // MARK: Listening

    private func startRecognizing(with recognizer: SFSpeechRecognizer) throws {
        try AudioRoute.startListening()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // On-device keeps your voice on the phone, and it's faster.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        heardFinal = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Conversation", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
        }
        Self.tap(input, format: format, into: request)
        engine.prepare()
        try engine.start()

        recognition = Self.recognize(request, with: recognizer) { [weak self] text, final in
            guard let self, self.request === request else { return }
            if let text { self.caption = text }
            if final { self.heardFinal = true }
        }
    }

    // The audio tap and recognizer call back on their own queues; building the
    // closures outside the main actor keeps them free of main-actor checks.
    private nonisolated static func tap(_ input: AVAudioInputNode, format: AVAudioFormat, into request: SFSpeechAudioBufferRecognitionRequest) {
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
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

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        AudioRoute.stopListening()
    }

    // MARK: Answering

    private func finish() async {
        // The last words are often still being recognized when you let go.
        for _ in 0..<10 where !heardFinal {
            try? await Task.sleep(for: .milliseconds(80))
        }
        recognition?.cancel()
        recognition = nil
        request = nil

        let said = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let character = listener, character.anchor.parent != nil else {
            state = .idle
            return clearCaption(after: 1)
        }
        guard !said.isEmpty else {
            state = .idle
            return note("I didn't catch that. Hold the button while you talk.")
        }
        character.ponder()

        let id = character.job.id
        let info = character.job.character ?? CharacterInfo(
            name: character.name, summary: "A friendly little character.", greeting: "Hi!", bodyPlan: "other",
            heightMeters: 0.5, figureBox: Box(x: 0, y: 0, w: 1, h: 1), colors: [], personality: character.personality)
        let history = histories[id] ?? []

        guard let key = Keys.value(Keys.anthropic) else {
            state = .idle
            character.answer(character.personality.friendliness < 0.4 ? "…hm?" : "Hmm? I can't talk yet!")
            return note("Add your Anthropic API key in Settings so characters can talk back.")
        }
        do {
            let reply = try await ClaudeDirector(apiKey: key).reply(to: said, as: info, history: history)
            histories[id] = Array((history + [ChatTurn(fromUser: true, text: said), ChatTurn(fromUser: false, text: reply)])
                .suffix(historyLength))
            state = .idle
            guard character.anchor.parent != nil else { return clearCaption(after: 0.5) }
            character.answer(reply)
            clearCaption(after: 1.5)
        } catch {
            print("[talk] reply failed: \(error.localizedDescription)")
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
        let onScreen = scene.actors.compactMap { actor -> (CharacterActor, CGFloat)? in
            guard let p = view.project(actor.headWorldPosition), view.bounds.contains(p) else { return nil }
            return (actor, hypot(p.x - center.x, p.y - center.y))
        }
        return onScreen.min { $0.1 < $1.1 }?.0 ?? scene.actors.last
    }

    // MARK: Permissions

    /// True if both are granted. Otherwise asks (first use) or explains, and
    /// returns false: the alert breaks the hold, so the next press talks.
    private func permitted() -> Bool {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVAudioApplication.shared.recordPermission
        if speech == .authorized && mic == .granted { return true }

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
            if micOK && speechOK {
                note("All set! Hold the button and talk.")
            } else {
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
