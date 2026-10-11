import AVFoundation
import SoundAnalysis

/// Listens for a finger snap or a clap with Apple's built-in sound classifier,
/// so the app can be driven hands-free in AR.
///
/// Runs its own audio engine on the mic. It pauses while you're talking to a
/// character (speech recognition needs the mic then) and resumes afterwards.
@MainActor
final class SoundGestures {
    enum Sound { case snap, clap }

    var onSound: ((Sound) -> Void)?
    private(set) var running = false

    private let engine = AVAudioEngine()
    private var analyzer: SNAudioStreamAnalyzer?
    private let observer = Observer()
    private let queue = DispatchQueue(label: "sound-gestures")
    private var paused = false
    private var lastFired: [Sound: Date] = [:]
    private var configObserver: NSObjectProtocol?

    init() {
        observer.onHeard = { [weak self] sound, confidence in
            Task { @MainActor in self?.heard(sound, confidence) }
        }
    }

    /// Asks for the mic once, then starts listening.
    func start() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else { print("[sound] mic permission denied: snapping won't work"); return }
                self.paused = false
                self.begin()
            }
        }
    }

    /// While the mic is needed for something else (talking to a character).
    func pause() {
        paused = true
        end()
    }

    func resume() {
        paused = false
        begin()
    }

    private func begin() {
        guard !running, !paused else { return }
        do {
            try AudioRoute.startAmbientListening()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { return }
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.overlapFactor = 0.8 // a snap is short: check often
            try analyzer.add(request, withObserver: observer)
            self.analyzer = analyzer
            let queue = self.queue
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
                queue.async { analyzer.analyze(buffer, atAudioFramePosition: when.sampleTime) }
            }
            engine.prepare()
            try engine.start()
            running = true
            // A route or category change stops the engine: start it again.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.end()
                    if !self.paused { self.begin() }
                }
            }
            print("[sound] listening for snaps and claps")
        } catch {
            print("[sound] couldn't start: \(error.localizedDescription)")
            end()
        }
    }

    private func end() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        analyzer?.removeAllRequests()
        analyzer = nil
        running = false
        AudioRoute.stopAmbientListening()
    }

    private func heard(_ sound: Sound, _ confidence: Double) {
        guard running else { return }
        let now = Date()
        // One snap shouldn't fire twice; the window slides over it several times.
        if let last = lastFired[sound], now.timeIntervalSince(last) < 2 { return }
        lastFired[sound] = now
        print("[sound] \(sound) \(String(format: "%.2f", confidence))")
        onSound?(sound)
    }

    private final class Observer: NSObject, SNResultsObserving {
        var onHeard: ((Sound, Double) -> Void)?

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            if let snap = result.classification(forIdentifier: "finger_snapping"), snap.confidence > 0.6 {
                onHeard?(.snap, snap.confidence)
            } else if let clap = result.classification(forIdentifier: "clapping"), clap.confidence > 0.7 {
                onHeard?(.clap, clap.confidence)
            }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            print("[sound] analysis failed: \(error.localizedDescription)")
        }
    }
}
