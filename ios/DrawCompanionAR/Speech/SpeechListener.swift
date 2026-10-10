import AVFoundation
import Speech

/// Always-on listening. Uses Apple's speech recognition (on-device when the
/// phone supports it, so audio stays on the phone). A phrase is finished
/// after a short pause; each finished phrase is handed to `onPhrase`.
final class SpeechListener {
    enum State: Equatable { case off, listening, denied, unavailable }

    var onPhrase: ((String) -> Void)?
    var onState: ((State) -> Void)?
    private(set) var state: State = .off { didSet { if state != oldValue { onState?(state) } } }

    /// Silence that ends a phrase.
    var pause: TimeInterval = 1.2

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heard = ""
    private var pauseTimer: Timer?
    private var generation = 0 // ignores callbacks from recognition tasks we've moved on from

    @MainActor
    func start() async {
        guard state != .listening else { return }
        let speechOK = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard speechOK, micOK else { state = .denied; return }
        guard let recognizer, recognizer.isAvailable else { state = .unavailable; return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            state = .unavailable
            return
        }
        state = .listening
        beginPhrase()
    }

    @MainActor
    func stop() {
        generation += 1
        pauseTimer?.invalidate()
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        heard = ""
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if state == .listening { state = .off }
    }

    /// One recognition task per phrase: tasks are limited to about a minute,
    /// and a fresh task gives a clean transcript for the next phrase.
    private func beginPhrase() {
        guard state == .listening, let recognizer else { return }
        generation += 1
        let mine = generation
        heard = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, mine == self.generation else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.heard {
                        self.heard = text
                        self.restartPauseTimer()
                    }
                    if result.isFinal { self.finishPhrase() }
                } else if error != nil {
                    self.finishPhrase()
                }
            }
        }
    }

    private func restartPauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: pause, repeats: false) { [weak self] _ in
            self?.finishPhrase()
        }
    }

    private func finishPhrase() {
        pauseTimer?.invalidate()
        let phrase = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        if !phrase.isEmpty { onPhrase?(phrase) }
        // Short delay so a task that ends on an error doesn't spin.
        DispatchQueue.main.asyncAfter(deadline: .now() + (phrase.isEmpty ? 0.5 : 0.05)) { [weak self] in
            self?.beginPhrase()
        }
    }
}
