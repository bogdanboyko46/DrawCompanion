import AVFoundation
import Speech
import UIKit

/// Always-on listening. Uses Apple's speech recognition (on-device when the
/// phone supports it, so audio stays on the phone). A phrase is finished
/// after a short pause (`PhraseEndpointer` decides how short); each finished
/// phrase is handed to `onPhrase`.
///
/// Keeps itself running: recognition tasks are replaced before Apple's ~1
/// minute limit, errors are retried with a growing delay, and listening pauses
/// for calls, Siri and the app going to the background, then resumes on its
/// own. Only `stop()` turns it off for good.
@MainActor
final class SpeechListener: NSObject, SFSpeechRecognizerDelegate {
    enum State: Equatable { case off, listening, paused, denied, unavailable }

    var onPhrase: ((String) -> Void)?
    var onState: ((State) -> Void)?
    private(set) var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            print("[DC] speech: \(state)")
            LiveSpeech.shared.state = state
            onState?(state)
        }
    }

    /// UserDefaults key for the base pause that ends a phrase (seconds).
    nonisolated static let pauseKey = "dc.speech.pause"
    nonisolated static let defaultPause: TimeInterval = 1.0

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine = AVAudioEngine()
    private let feed = AudioFeed()
    private var task: SFSpeechRecognitionTask?
    private var endpointer = PhraseEndpointer()
    private var taskStartedAt: TimeInterval = 0
    private var generation = 0 // ignores callbacks from recognition tasks we've moved on from
    private var wanted = false // the user wants the mic on (survives pauses)
    private var engineRunning = false
    private var engineStartedAt: TimeInterval = 0
    private var failures = 0 // consecutive recognition errors without a result
    private var retry: DispatchWorkItem?
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        recognizer?.delegate = self
        observe()
    }

    // MARK: on / off

    func start() async {
        wanted = true
        guard state != .listening else { return }
        let speechOK = await Self.speechPermission()
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard wanted else { return } // stopped while the permission prompts were up
        guard speechOK, micOK else { state = .denied; return }
        resume()
    }

    func stop() {
        wanted = false
        retry?.cancel()
        suspend()
        state = .off
    }

    static func speechPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status != .notDetermined { return status == .authorized }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// Starts (or restarts) the microphone and recognition if wanted.
    private func resume() {
        retry?.cancel()
        guard wanted, UIApplication.shared.applicationState != .background else { return }
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable
            scheduleRetry(after: 3)
            return
        }
        if !engineRunning {
            do {
                try startEngine()
            } catch {
                print("[DC] speech: audio didn't start: \(error.localizedDescription)")
                suspend()
                state = .unavailable
                scheduleRetry(after: retryDelay())
                return
            }
        }
        state = .listening
        LiveSpeech.shared.note = nil
        if task == nil { beginPhrase() }
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func startEngine() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audio.setActive(true, options: .notifyOthersOnDeactivation)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No usable input (another app or a call holds the mic): installing a
        // tap with this format would crash.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "DrawCompanion", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone input"])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(into: feed))
        engine.prepare()
        try engine.start()
        engineRunning = true
        engineStartedAt = CACurrentMediaTime()
    }

    /// Stops audio and recognition but remembers whether the mic was wanted.
    private func suspend() {
        generation += 1
        ticker?.invalidate()
        ticker = nil
        task?.cancel()
        feed.request?.endAudio()
        feed.request = nil
        task = nil
        endpointer = PhraseEndpointer(options: options)
        LiveSpeech.shared.partial = ""
        if engineRunning || engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            engineRunning = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func pause(_ note: String) {
        guard wanted, state == .listening || state == .unavailable else { return }
        suspend()
        state = .paused
        LiveSpeech.shared.note = note
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.resume() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func retryDelay() -> TimeInterval {
        failures += 1
        return min(10, 0.5 * pow(2, Double(min(failures, 5))))
    }

    // MARK: phrases

    private var options: PhraseEndpointer.Options {
        let stored = UserDefaults.standard.double(forKey: Self.pauseKey)
        let pause = stored > 0 ? stored : Self.defaultPause
        return PhraseEndpointer.Options(pause: pause, trailingPause: pause + 1.0)
    }

    /// One recognition task per phrase: tasks are limited to about a minute,
    /// and a fresh task gives a clean transcript for the next phrase. The new
    /// request takes over the audio feed before the old one is closed, so no
    /// words are lost in between.
    private func beginPhrase() {
        guard state == .listening, let recognizer else { return }
        generation += 1
        let mine = generation
        endpointer = PhraseEndpointer(options: options)
        taskStartedAt = CACurrentMediaTime()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let old = (task, feed.request)
        feed.request = request
        old.0?.cancel()
        old.1?.endAudio()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler { [weak self] text, final, error in
            guard let self, mine == self.generation else { return }
            self.received(text: text, final: final, error: error)
        })
    }

    private func received(text: String?, final: Bool, error: NSError?) {
        if let text {
            failures = 0
            endpointer.update(text, at: CACurrentMediaTime())
            LiveSpeech.shared.partial = endpointer.text
            if final { finishPhrase(reason: "final") }
            return
        }
        guard let error else { return }
        if !endpointer.text.isEmpty {
            finishPhrase(reason: "error \(error.code)")
            return
        }
        // 1110 "no speech detected" and 301/216 "cancelled" are routine; the
        // rest count toward backing off.
        // A task that fails right away isn't routine, whatever the code: back
        // off so it doesn't spin.
        let routine = [1110, 301, 216, 203].contains(error.code) && CACurrentMediaTime() - taskStartedAt > 1
        print("[DC] speech: recognition error \(error.domain) \(error.code)\(routine ? "" : ": \(error.localizedDescription)")")
        task = nil
        if routine {
            beginPhrase()
        } else {
            generation += 1
            let delay = retryDelay()
            if failures >= 4 { LiveSpeech.shared.note = "Speech recognition is having trouble; retrying…" }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.state == .listening, self.task == nil else { return }
                    self.beginPhrase()
                }
            }
        }
    }

    /// Ten times a second: ends phrases after the pause and replaces idle
    /// tasks before the recognizer's time limit.
    private func tick() {
        guard state == .listening, task != nil else { return }
        let now = CACurrentMediaTime()
        if endpointer.isFinished(at: now) {
            finishPhrase(reason: now - (endpointer.startedAt ?? now) >= endpointer.options.maxPhrase ? "max length" : "pause")
        } else if endpointer.text.isEmpty, now - taskStartedAt > 50 {
            beginPhrase()
        }
    }

    private func finishPhrase(reason: String) {
        let gap = endpointer.longestGap
        let length = (endpointer.lastChangeAt ?? 0) - (endpointer.startedAt ?? 0)
        let phrase = endpointer.finish()
        LiveSpeech.shared.partial = ""
        beginPhrase()
        guard let phrase else { return }
        print(String(format: "[DC] phrase (%@, %.1fs, longest gap %.2fs): %@", reason, length, gap, phrase))
        LiveSpeech.shared.record(gap: gap)
        LiveSpeech.shared.lastPhrase = phrase
        onPhrase?(phrase)
    }

    // MARK: interruptions, route changes, background

    private func observe() {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ object: Any? = nil, _ act: @escaping @MainActor (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { note in
                MainActor.assumeIsolated { act(note) }
            })
        }
        let session = AVAudioSession.sharedInstance()
        on(AVAudioSession.interruptionNotification, session) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self.engineRunning = false // the system already stopped it
                self.pause("Listening paused (call or Siri)")
            } else if self.state == .paused {
                self.scheduleRetry(after: 0.5)
            }
        }
        on(AVAudioSession.routeChangeNotification, session) { [weak self] note in
            guard let self, self.state == .listening,
                  let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  [.newDeviceAvailable, .oldDeviceUnavailable].contains(reason) else { return }
            // A different microphone (headphones in or out): restart with its format.
            print("[DC] speech: audio route changed, restarting")
            self.suspend()
            self.scheduleRetry(after: 0.3)
        }
        on(AVAudioSession.mediaServicesWereResetNotification, session) { [weak self] _ in
            guard let self else { return }
            print("[DC] speech: media services reset")
            self.suspend()
            self.engine = AVAudioEngine()
            if self.wanted { self.scheduleRetry(after: 1) }
        }
        on(.AVAudioEngineConfigurationChange) { [weak self] note in
            // Starting the engine can itself post one of these; restarting
            // for that would loop.
            guard let self, note.object as AnyObject? === self.engine, self.wanted, self.state == .listening,
                  CACurrentMediaTime() - self.engineStartedAt > 1 else { return }
            print("[DC] speech: audio configuration changed, restarting")
            self.suspend()
            self.scheduleRetry(after: 0.3)
        }
        on(UIApplication.didEnterBackgroundNotification) { [weak self] _ in
            self?.pause("Listening paused")
        }
        on(UIApplication.didBecomeActiveNotification) { [weak self] _ in
            guard let self, self.wanted, self.state != .listening, self.state != .denied else { return }
            Task { await self.start() } // permissions may have changed in Settings
        }
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            print("[DC] speech: recognizer available = \(available)")
            if available, self.wanted, self.state == .unavailable { self.resume() }
            if !available, self.state == .listening {
                self.suspend()
                self.state = .unavailable
                self.scheduleRetry(after: 3)
            }
        }
    }

    // MARK: off the main thread

    /// Hands microphone audio to whichever request is current. Runs on the
    /// audio thread, hence the lock.
    final class AudioFeed: @unchecked Sendable {
        private let lock = NSLock()
        private var _request: SFSpeechAudioBufferRecognitionRequest?
        var request: SFSpeechAudioBufferRecognitionRequest? {
            get { lock.lock(); defer { lock.unlock() }; return _request }
            set { lock.lock(); _request = newValue; lock.unlock() }
        }
    }

    nonisolated private static func tap(into feed: AudioFeed) -> AVAudioNodeTapBlock {
        { buffer, _ in feed.request?.append(buffer) }
    }

    nonisolated private static func handler(_ deliver: @escaping @MainActor (String?, Bool, NSError?) -> Void)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let nsError = error.map { $0 as NSError }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(text, final, nsError) }
            }
        }
    }
}

/// What the listener is hearing right now, for the phone view and Settings.
@MainActor
final class LiveSpeech: ObservableObject {
    static let shared = LiveSpeech()

    /// Words of the phrase being spoken (empty between phrases).
    @Published var partial = ""
    @Published var lastPhrase = ""
    @Published var state: SpeechListener.State = .off
    /// Why listening is paused or struggling, if it is.
    @Published var note: String?
    /// Longest mid-phrase silences of recent phrases (seconds), to tune the pause.
    @Published private(set) var recentGaps: [TimeInterval] = []

    func record(gap: TimeInterval) {
        guard gap > 0 else { return }
        recentGaps = Array((recentGaps + [gap]).suffix(20))
    }
}
