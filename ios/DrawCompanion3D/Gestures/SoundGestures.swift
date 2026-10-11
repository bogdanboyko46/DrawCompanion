import AVFoundation
import SoundAnalysis

/// Listens for a finger snap or a clap (Apple's built-in sound classifier) and
/// a "shhh" (a steady hiss, detected directly: the classifier has no shush),
/// so the app can be driven hands-free in AR.
///
/// Runs its own audio engine on the mic. It pauses while you're talking to a
/// character (speech recognition needs the mic then) and resumes afterwards.
@MainActor
final class SoundGestures {
    enum Sound { case snap, clap, shush }

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
            let hiss = HissDetector()
            hiss.onShush = { [weak self] in Task { @MainActor in self?.heard(.shush, 1) } }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
                queue.async {
                    analyzer.analyze(buffer, atAudioFramePosition: when.sampleTime)
                    hiss.feed(buffer)
                }
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
            } else if let hiss = ["snake_hiss", "whispering"].compactMap({ result.classification(forIdentifier: $0) })
                        .max(by: { $0.confidence < $1.confidence }), hiss.confidence > 0.75 {
                onHeard?(.shush, hiss.confidence)
            }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            print("[sound] analysis failed: \(error.localizedDescription)")
        }
    }
}

/// Spots a "shhh": a steady hiss for about half a second. A hiss has a very
/// high zero-crossing rate (vowels and most noise don't) and keeps going
/// (snaps and claps are over in a blink). Runs on the analysis queue.
final class HissDetector: @unchecked Sendable {
    var onShush: (() -> Void)?
    private var run = 0
    private var noiseFloor: Float = 0.002
    private var cooldown = 0
    private var logCount = 0

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 1 else { return }
        var energy: Float = 0, crossings = 0
        for i in 0..<n {
            energy += data[i] * data[i]
            if i > 0, (data[i] >= 0) != (data[i - 1] >= 0) { crossings += 1 }
        }
        let rms = (energy / Float(n)).squareRoot()
        let zcr = Float(crossings) / Float(n)
        // Track the room's background level so "loud enough" adapts.
        if rms < noiseFloor * 2 { noiseFloor = noiseFloor * 0.95 + rms * 0.05 }
        if cooldown > 0 { cooldown -= 1; return }
        // A real "shhh" centers around 2–4 kHz: a zero-crossing rate of ~0.1–0.2
        // at 48 kHz. Vowels sit far lower (~0.01–0.05).
        let loud = rms > max(0.004, noiseFloor * 3)
        let hissy = zcr > 0.09 && loud
        if loud, logCount % 6 == 0 { print(String(format: "[hiss] zcr %.3f rms %.4f floor %.4f", zcr, rms, noiseFloor)) }
        if loud { logCount += 1 }
        run = hissy ? run + 1 : 0
        // ~0.45 s of hiss at 4096-frame buffers (48 kHz → 85 ms each).
        let needed = max(4, Int(0.45 * buffer.format.sampleRate / Double(n)))
        if run >= needed {
            run = 0
            cooldown = needed * 3
            onShush?()
        }
    }
}
