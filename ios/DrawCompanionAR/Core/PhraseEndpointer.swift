import Foundation

/// Decides when a spoken phrase is finished, from the recognizer's live
/// transcript. A phrase ends after a pause; how long a pause depends on how
/// the words so far end:
///
///   "add a cat on the windowsill."  → complete thought: the base pause
///   "maybe a cat on the"            → trailing word: wait longer
///   "um"                            → filler only: wait longer, and if it
///                                     still ends there, it's dropped
///
/// Pure logic (no audio), so it's unit-tested; `SpeechListener` feeds it.
struct PhraseEndpointer {
    struct Options: Equatable {
        /// Silence after a complete-sounding phrase. On-device recognition
        /// reports words ~0.3 s after they're said, so the real gap the user
        /// leaves is roughly this plus that.
        var pause: TimeInterval = 1.0
        /// Silence after a phrase that ends mid-thought ("a cat on the").
        var trailingPause: TimeInterval = 2.0
        /// A phrase this long is sent even mid-speech, well before the
        /// recognizer's ~1 minute limit cuts it off.
        var maxPhrase: TimeInterval = 40
    }

    var options = Options()
    private(set) var text = ""
    private(set) var startedAt: TimeInterval?
    private(set) var lastChangeAt: TimeInterval?
    /// Longest silence between words in the current phrase (wall clock
    /// between transcript changes); logged to tune `pause`.
    private(set) var longestGap: TimeInterval = 0

    init(options: Options = Options()) { self.options = options }

    /// The recognizer's latest transcript for the current phrase.
    mutating func update(_ transcript: String, at now: TimeInterval) {
        guard transcript != text else { return }
        if let last = lastChangeAt { longestGap = max(longestGap, now - last) }
        if startedAt == nil { startedAt = now }
        text = transcript
        lastChangeAt = now
    }

    /// When the phrase should end if nothing more is heard (nil: nothing yet).
    var deadline: TimeInterval? {
        guard let lastChangeAt, let startedAt else { return nil }
        let silence = Self.soundsUnfinished(text) ? options.trailingPause : options.pause
        return min(lastChangeAt + silence, startedAt + options.maxPhrase)
    }

    func isFinished(at now: TimeInterval) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }

    /// Ends the phrase: returns what to send (nil for nothing worth sending)
    /// and resets for the next one.
    mutating func finish() -> String? {
        let phrase = Self.cleaned(text)
        self = PhraseEndpointer(options: options)
        return phrase
    }

    // MARK: rules

    static let trailingWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "of", "to", "on", "in", "at", "with", "by", "for", "from",
        "into", "onto", "near", "next", "behind", "under", "over", "above", "below", "like", "maybe", "some",
        "um", "uh", "er", "erm", "hmm", "mm", "let's", "add", "draw", "make", "put", "is", "it's", "its",
        "my", "your", "this", "that", "then", "because", "if", "can", "could", "would", "should", "you",
    ]

    static let fillers: Set<String> = ["um", "uh", "er", "erm", "hmm", "mm", "mhm", "ah", "oh", "uhh", "umm", "hm"]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }
    }

    /// Ends in a way that suggests more is coming.
    static func soundsUnfinished(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, ".?!".contains(last) {
            // The recognizer's punctuation is a guess; a lone filler or a
            // dangling article with a period added is still unfinished.
            guard let word = words(trimmed).last else { return false }
            return fillers.contains(word) || ["a", "an", "the"].contains(word)
        }
        if trimmed.hasSuffix(",") || trimmed.hasSuffix("…") { return true }
        guard let word = words(trimmed).last else { return false }
        return trailingWords.contains(word)
    }

    /// The text to send, or nil if it's empty or only filler.
    static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ws = words(trimmed)
        guard !ws.isEmpty, !ws.allSatisfy(fillers.contains) else { return nil }
        return trimmed
    }
}
