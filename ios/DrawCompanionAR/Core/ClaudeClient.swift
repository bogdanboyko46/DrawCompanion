import Foundation

/// Talks to the Claude API over HTTPS (there is no official Swift SDK).
///   1. classify: Claude Haiku, text only — new | revise | hide | ignore.
///      Fast and nearly free; most of what an always-on mic hears stops here.
///   2. draw: Claude Sonnet with the page photo, streamed, so each stroke is
///      handed over the moment it's complete.
final class ClaudeClient {
    struct Config {
        var apiKey: String
        var filterModel = "claude-haiku-5-5"
        var drawModel = "claude-sonnet-5-5"
        var drawEffort = "low" // latency matters more than depth: the user is waiting
        var baseURL = URL(string: "https://api.anthropic.com")!
        /// Extra attempts after a transient failure (429, 5xx, overloaded, a
        /// dropped connection) or an empty drawing. Short waits: the user is waiting.
        var retries = 2
        var backoff: [Double] = [0.4, 1.2] // seconds before retry 1, 2, …
    }

    enum Failure: LocalizedError, Equatable {
        case http(Int, String)
        case malformed(String)
        /// The drawing model finished without a usable stroke (e.g. only "M 0 0").
        case empty
        /// The drawing model declined the request.
        case declined

        var errorDescription: String? {
            switch self {
            case .http(401, _): return "The API key was rejected. Check it in Settings."
            case .http(403, _): return "This API key isn't allowed to use Claude. Check it in Settings."
            case .http(402, _): return "The Claude account is out of credit."
            case .http(429, _): return "Too many requests right now. Try again in a moment."
            case .http(529, _), .http(500..<600, _): return "Claude is overloaded right now. Try again in a moment."
            case let .http(code, message): return "AI error \(code): \(message)"
            case let .malformed(what): return "Unexpected AI response: \(what)"
            case .empty: return "Claude didn't draw anything for that. Try saying it differently."
            case .declined: return "Claude declined to draw that."
            }
        }

        /// Worth trying again after a short wait.
        var isTransient: Bool {
            switch self {
            case let .http(code, _): return [408, 409, 429, 500, 502, 503, 504, 529].contains(code)
            case .empty: return true
            default: return false
            }
        }
    }

    /// Network errors that usually go away on their own.
    static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? Failure { return failure.isTransient }
        if let url = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                    .secureConnectionFailed].contains(url.code)
        }
        return false
    }

    let config: Config
    private let session: URLSession

    init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: stage 1

    func classify(utterances: [String], current: Outline?) async throws -> (action: TurnAction, note: String) {
        let body: [String: Any] = [
            "model": config.filterModel,
            "max_tokens": 2000, // leaves room for thinking before the short answer
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": Prompts.filterSchema]],
            "system": Prompts.filterSystem,
            "messages": [["role": "user", "content": Prompts.filterText(utterances: utterances, current: current)]],
        ]
        let data = try await withRetries("filter") {
            let (data, response) = try await self.session.data(for: self.request(body, beta: nil, timeout: 20))
            try self.check(response, data)
            return data
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed("not JSON")
        }
        // Haiku has no server-side fallback; a declined phrase is simply not acted on.
        if json["stop_reason"] as? String == "refusal" { return (.ignore, "filter: refusal") }
        print("[DC] filter raw: \(String(data: data.prefix(800), encoding: .utf8) ?? "?")")
        guard let text = Self.firstText(json),
              let decision = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let action = (decision["action"] as? String).flatMap(TurnAction.init)
        else { return (.ignore, "filter: unreadable answer") }
        let note = decision["note"] as? String ?? ""
        switch (action, current) {
        case (.revise, nil): return (.new, note)
        case (.hide, nil): return (.ignore, note)
        default: return (action, note)
        }
    }

    // MARK: stage 2

    /// Streams the drawing; calls onStroke for each stroke as it completes.
    /// Returns how many strokes were delivered.
    func draw(page: PagePhotos, paper: PaperSize, utterances: [String], current: Outline?, action: TurnAction,
              onStroke: (Stroke) async -> Void) async throws -> Int {
        let body: [String: Any] = [
            "model": config.drawModel,
            "max_tokens": 16000,
            "stream": true,
            "fallbacks": "default",
            "output_config": ["effort": config.drawEffort, "format": ["type": "json_schema", "schema": Prompts.drawSchema]],
            "system": Prompts.drawSystem,
            "messages": [[
                "role": "user",
                "content": Self.images(page) + [
                    ["type": "text", "text": Prompts.drawText(paper: paper, utterances: utterances, current: current, action: action, region: page.region)],
                ],
            ]],
        ]
        // Retried only while nothing has been drawn yet: once strokes are on
        // the paper, starting over would draw a second, different outline.
        var delivered = 0
        return try await withRetries("draw", canRetry: { delivered == 0 }) {
            try await self.drawOnce(body, paper: paper) { stroke in
                delivered += 1
                await onStroke(stroke)
            }
        }
    }

    private func drawOnce(_ body: [String: Any], paper: PaperSize, onStroke: (Stroke) async -> Void) async throws -> Int {
        let (bytes, response) = try await session.bytes(for: request(body, beta: "server-side-fallback-2026-07-01", timeout: 60))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            try check(response, data)
        }

        var scanner = StrokeScanner()
        var delivered = 0
        var raw = ""
        var stopReason: String?
        for try await line in bytes.lines {
            guard let event = SSE.event(fromLine: line) else { continue }
            switch event["type"] as? String {
            case "content_block_start":
                if (event["content_block"] as? [String: Any])?["type"] as? String == "text" {
                    scanner = StrokeScanner() // a fallback model starts its answer over
                }
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { continue }
                raw += text
                for json in scanner.push(text) {
                    for stroke in PathFlattener.strokes(fromJSON: json, paper: paper) where Self.isVisible(stroke) {
                        await onStroke(stroke)
                        delivered += 1
                    }
                }
            case "message_delta":
                stopReason = (event["delta"] as? [String: Any])?["stop_reason"] as? String ?? stopReason
            case "error":
                let error = event["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "stream error"
                throw Failure.http(error?["type"] as? String == "overloaded_error" ? 529 : 500, message)
            default:
                break
            }
        }
        print("[DC] draw stop=\(stopReason ?? "nil") delivered=\(delivered) raw: \(raw.prefix(600))")
        if delivered == 0 {
            // Never a silent "nothing happened": the caller retries or shows why.
            throw stopReason == "refusal" ? Failure.declined : Failure.empty
        }
        return delivered
    }

    /// Runs `attempt`, trying again after transient failures with a short wait.
    /// A cancelled turn (the user kept talking) stops at once.
    private func withRetries<T>(_ label: String, canRetry: () -> Bool = { true },
                                _ attempt: () async throws -> T) async throws -> T {
        var tries = 0
        while true {
            do {
                return try await attempt()
            } catch {
                guard tries < config.retries, Self.isTransient(error), canRetry(), !Task.isCancelled else { throw error }
                let wait = config.backoff.isEmpty ? 0.5 : config.backoff[min(tries, config.backoff.count - 1)]
                tries += 1
                print("[DC] \(label) retry \(tries) in \(wait)s after: \(error)")
                try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            }
        }
    }

    /// Drops strokes that would draw nothing visible (a dot like "M 0 0 L 0 0").
    static func isVisible(_ stroke: Stroke) -> Bool {
        let xs = stroke.points.map(\.x), ys = stroke.points.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return false }
        return max(x1 - x0, y1 - y0) >= 2
    }

    // MARK: helpers

    private static func images(_ page: PagePhotos) -> [[String: Any]] {
        [page.full, page.closeUp].compactMap { $0 }.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
        }
    }

    private func request(_ body: [String: Any], beta: String?, timeout: TimeInterval) throws -> URLRequest {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout // longest silence allowed between bytes
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let beta { req.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed("no HTTP response") }
        guard http.statusCode == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
                ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw Failure.http(http.statusCode, message)
        }
    }

    static func firstText(_ message: [String: Any]) -> String? {
        (message["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
    }
}

/// Server-sent events: the API streams lines like `data: {...}`.
enum SSE {
    static func event(fromLine line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
