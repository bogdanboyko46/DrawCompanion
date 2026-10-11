import Foundation

/// One line of a conversation between the user and a character.
struct ChatTurn: Equatable, Sendable {
    var fromUser: Bool
    var text: String
}

/// Claude as the character's voice: short, in-character spoken replies.
extension ClaudeDirector {
    private struct Reply: Decodable { var reply: String }

    /// `history` is the recent conversation, oldest first, not including `utterance`.
    func reply(to utterance: String, as character: CharacterInfo, history: [ChatTurn]) async throws -> String {
        let name = character.name
        let past = history.map { "\($0.fromUser ? "User" : name): \($0.text)" }.joined(separator: "\n")
        let text = """
        \(past.isEmpty ? "This is the start of the conversation." : "Conversation so far:\n\(past)")

        The user just said (speech recognition, may have small errors): "\(utterance)"
        """
        let answer: Reply = try await call(
            system: Self.chatSystem(for: character),
            content: [["type": "text", "text": text]],
            schema: Self.replySchema, effort: "low")
        return Self.trimmed(answer.reply)
    }

    private static func chatSystem(for c: CharacterInfo) -> String {
        let p = c.personality
        let traits = p.traits.isEmpty ? "friendly" : p.traits.joined(separator: ", ")
        return """
        You are \(c.name), a character someone drew on paper that came to life as a small 3D figure standing on their desk in augmented reality. You can see the room a little, walk around the desk, and wave. The person is talking to you through their phone.

        About you: \(c.summary)
        Body: \(c.bodyPlan.replacingOccurrences(of: "_", with: " ")). Personality: \(traits). Energy \(String(format: "%.1f", p.energy)) of 1, friendliness \(String(format: "%.1f", p.friendliness)) of 1. The first thing you said was: "\(c.greeting)"

        Reply in character, as speech: one or two short sentences, at most 120 characters. Your words are read aloud by a speech synthesizer, so no emoji, no stage directions, no asterisks, no lists. Be playful and warm, kid-friendly, and match your personality (a shy character is brief and hesitant; an energetic one is excited). If the words look garbled, guess what they meant or ask them to say it again, in character. If someone sincerely asks whether you're real or an AI, say kindly that you're their drawing brought to life by an AI.
        """
    }

    private static let replySchema: [String: Any] = [
        "type": "object",
        "properties": ["reply": ["type": "string", "description": "What the character says out loud, max 120 characters."]],
        "required": ["reply"],
        "additionalProperties": false,
    ]

    /// Keeps a runaway reply short enough for a bubble, ending on a word.
    private static func trimmed(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 140 else { return clean }
        let cut = clean.prefix(140)
        if let end = cut.lastIndex(where: { ".!?".contains($0) }), cut.distance(from: cut.startIndex, to: end) > 40 {
            return String(cut[...end])
        }
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + "…"
    }
}
