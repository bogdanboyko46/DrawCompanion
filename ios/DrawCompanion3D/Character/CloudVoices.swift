import Foundation

/// Human-sounding character voices from ElevenLabs, used when an ElevenLabs
/// key is set (otherwise characters use iOS's own voices).
///
/// Each character gets one of the account's voices, picked to fit it (a
/// young voice for little cute ones, a deeper one for gruff ones) and the
/// same one every time.
@MainActor
final class CloudVoices {
    static let shared = CloudVoices()

    struct Voice: Decodable {
        let voice_id: String
        let name: String
        let labels: [String: String]?
    }

    private var voices: Task<[Voice], Error>?
    /// Recent lines (a greeting comes back often): voice + text → mp3.
    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        return URLSession(configuration: config)
    }()

    var key: String? { Keys.value(Keys.elevenLabs) }

    /// Fetches the voice list early, so the first line isn't slower.
    func warmUp() {
        guard key != nil else { return }
        Task { _ = try? await allVoices() }
    }

    func voice(for profile: VoiceProfile, seed: String) async throws -> Voice {
        var pool = try await allVoices()
        guard !pool.isEmpty else { throw CloudVoiceError.noVoices }
        func label(_ v: Voice, _ k: String) -> String { v.labels?[k]?.lowercased() ?? "" }
        func narrow(_ keep: (Voice) -> Bool) {
            let kept = pool.filter(keep)
            if !kept.isEmpty { pool = kept }
        }
        // English voices that sound like a person talking, not a narrator.
        narrow { label($0, "language").isEmpty || label($0, "language").hasPrefix("en") }
        narrow { !label($0, "use_case").contains("news") && !label($0, "use_case").contains("narrat") }
        narrow { label($0, "gender") == (profile.gruff ? "male" : "female") }
        if profile.cute { narrow { label($0, "age") == "young" } }
        if profile.gruff { narrow { label($0, "age") != "young" } }
        pool.sort { $0.voice_id < $1.voice_id }
        let hash = seed.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
        return pool[Int(hash % UInt32(pool.count))]
    }

    /// The line spoken in `voice`, as mp3.
    func audio(_ text: String, voice: Voice, speed: Double) async throws -> Data {
        let cacheKey = voice.voice_id + "|" + text
        if let hit = cache[cacheKey] { return hit }
        guard let key else { throw CloudVoiceError.noKey }
        var request = URLRequest(url: URL(string:
            "https://api.elevenlabs.io/v1/text-to-speech/\(voice.voice_id)?output_format=mp3_44100_128")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "text": text,
            // Flash: the fastest model, so answers start talking right away.
            "model_id": "eleven_flash_v2_5",
            "voice_settings": ["stability": 0.4, "similarity_boost": 0.8, "speed": min(1.15, max(0.85, speed))],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = Date()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw CloudVoiceError.http(status, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        print("[voice] \(voice.name): \(data.count / 1024) KB in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        cache[cacheKey] = data
        cacheOrder.append(cacheKey)
        if cacheOrder.count > 30 { cache[cacheOrder.removeFirst()] = nil }
        return data
    }

    private func allVoices() async throws -> [Voice] {
        if let voices { return try await voices.value }
        let task = Task { [session, key] () throws -> [Voice] in
            guard let key else { throw CloudVoiceError.noKey }
            var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw CloudVoiceError.http(status, String(data: data.prefix(200), encoding: .utf8) ?? "")
            }
            struct List: Decodable { let voices: [Voice] }
            let list = try JSONDecoder().decode(List.self, from: data).voices
            print("[voice] ElevenLabs: \(list.count) voices")
            return list
        }
        voices = task
        do {
            return try await task.value
        } catch {
            voices = nil // try again next time
            throw error
        }
    }
}

enum CloudVoiceError: LocalizedError {
    case noKey, noVoices
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noKey: "No ElevenLabs key"
        case .noVoices: "No ElevenLabs voices on this account"
        case .http(let status, let body): "ElevenLabs HTTP \(status): \(body)"
        }
    }
}
