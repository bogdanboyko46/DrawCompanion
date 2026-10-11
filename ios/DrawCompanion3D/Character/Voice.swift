import AVFoundation

/// Gives every character a voice of its own, spoken aloud next to its bubble.
///
/// One shared synthesizer, so characters take turns instead of talking over
/// each other; a character's new line cuts off its own previous one.
@MainActor
final class CharacterVoice: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = CharacterVoice()

    private let synthesizer = AVSpeechSynthesizer()
    private var speakers: [ObjectIdentifier: String] = [:] // utterance → character id
    private var current: ObjectIdentifier?
    private var profiles: [String: VoiceProfile] = [:]

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, by character: CharacterActor) {
        let id = character.job.id
        // Reactions like "♪" have nothing to say out loud.
        guard text.contains(where: \.isLetter) else { return }
        if let current, speakers[current] == id {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let profile = profiles[id] ?? VoiceProfile(for: character.job)
        profiles[id] = profile

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = profile.voice
        utterance.pitchMultiplier = profile.pitch
        utterance.rate = profile.rate
        utterance.postUtteranceDelay = 0.15
        speakers[ObjectIdentifier(utterance)] = id
        AudioRoute.prepareToSpeak()
        synthesizer.speak(utterance)
    }

    /// Hush, e.g. when the user starts talking (and so the mic doesn't hear it).
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakers.removeAll()
        current = nil
    }

    private func finished(_ id: ObjectIdentifier) {
        speakers[id] = nil
        if current == id { current = nil }
        if speakers.isEmpty { AudioRoute.rest() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.current = id }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }
}

/// How a character sounds, from what Claude wrote about it: small and cute
/// is high, big monsters are low and slow, energetic ones talk fast.
struct VoiceProfile {
    var voice: AVSpeechSynthesisVoice?
    var pitch: Float
    var rate: Float

    init(for job: CharacterJob) {
        let info = job.character
        let personality = info?.personality ?? .neutral
        let traits = (personality.traits + [info?.summary ?? ""]).joined(separator: " ").lowercased()
        let has = { (words: [String]) in words.contains { traits.contains($0) } }

        // Size sets the base pitch: a 1.4 m figure speaks at 1.0, halving the size raises it.
        let height = Float(info?.heightMeters ?? 0.6)
        var pitch = 1.05 - 0.3 * log2(max(0.2, height) / 1.4)
        switch info?.bodyPlan {
        case "blob", "object": pitch += 0.08
        case "winged": pitch += 0.05
        default: break
        }
        if has(["cute", "tiny", "little", "bubbly", "squeak", "sweet", "baby", "giggl"]) { pitch += 0.12 }
        if has(["grump", "fierce", "scary", "monster", "menac", "gruff", "spook", "brave", "tough", "dragon"]) { pitch -= 0.15 }
        self.pitch = min(1.75, max(0.55, pitch))

        let energy = Float(personality.energy)
        var rate = AVSpeechUtteranceDefaultSpeechRate * (0.86 + 0.3 * energy)
        if height > 2 { rate *= 0.9 }
        if has(["sleepy", "lazy", "calm", "wise", "old"]) { rate *= 0.92 }
        self.rate = min(AVSpeechUtteranceMaximumSpeechRate * 0.75, max(AVSpeechUtteranceMinimumSpeechRate + 0.2, rate))

        voice = Self.pickVoice(deep: self.pitch < 0.85, high: self.pitch > 1.25, seed: job.id)
    }

    /// The best installed English voice of a fitting register, the same one
    /// for a character every time.
    private static func pickVoice(deep: Bool, high: Bool, seed: String) -> AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier == "en"
            ? AVSpeechSynthesisVoice.currentLanguageCode() : "en-US"
        var voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let local = voices.filter { $0.language == language }
        if !local.isEmpty { voices = local }
        // Pitching a low voice up sounds more natural for little ones, and vice versa.
        let gender: AVSpeechSynthesisVoiceGender? = deep ? .male : (high ? .female : nil)
        if let gender, voices.contains(where: { $0.gender == gender }) {
            voices = voices.filter { $0.gender == gender }
        }
        if let best = voices.map(\.quality.rawValue).max() {
            voices = voices.filter { $0.quality.rawValue == best }
        }
        voices.sort { $0.identifier < $1.identifier }
        guard !voices.isEmpty else { return AVSpeechSynthesisVoice(language: language) }
        // String.hashValue changes every launch; this doesn't.
        let hash = seed.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
        return voices[Int(hash % UInt32(voices.count))]
    }
}

/// The app's audio session. ARKit doesn't set one up, and the default
/// category goes silent with the ring switch, so speech would be lost.
@MainActor
enum AudioRoute {
    private(set) static var listening = false
    /// The mic stays open in the background for snap/clap gestures.
    private(set) static var ambient = false

    /// Speaker output that plays even in silent mode, ducking music meanwhile.
    static func prepareToSpeak() {
        guard !listening, !ambient else { return } // .playAndRecord already speaks through the speaker
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
    }

    /// Mic on, while still speaking through the loudspeaker (not the earpiece).
    static func startListening() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
        try session.setActive(true)
        listening = true
    }

    static func stopListening() {
        listening = false
        prepareToSpeak()
    }

    /// Mic on for gesture sounds, playing out loud at the same time and leaving
    /// other audio alone.
    static func startAmbientListening() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        try session.setActive(true)
        ambient = true
    }

    static func stopAmbientListening() {
        ambient = false
    }

    /// Lets other audio come back up once nobody's talking.
    static func rest() {
        guard !listening, !ambient else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
