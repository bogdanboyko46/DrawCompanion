import Foundation

/// Checks a Claude API key before it's saved: a quick look at its shape, then
/// one free request (listing models costs nothing) to confirm the API
/// accepts it.
enum APIKeyCheck {
    enum Result: Equatable {
        case valid
        case rejected // the API says the key is wrong or revoked
        case offline // couldn't reach the API: try again later
        case problem(String) // anything else (rate limit, outage)

        var message: String {
            switch self {
            case .valid: return "Key works."
            case .rejected: return "That key was rejected. Copy it again from console.anthropic.com › API keys."
            case .offline: return "Couldn't reach Claude. Check your internet connection, then try again."
            case let .problem(text): return text
            }
        }
    }

    /// Strips whitespace, quotes and line breaks a paste can bring along.
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’`")))
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    /// Why this can't be a key, without asking the API (nil if it looks fine).
    static func formatProblem(_ key: String) -> String? {
        if key.isEmpty { return "Paste your key first." }
        if !key.hasPrefix("sk-ant-") { return "Claude API keys start with “sk-ant-”. This doesn't look like one." }
        if key.count < 40 { return "This key looks cut off. Copy the whole key and paste it again." }
        return nil
    }

    static func request(key: String, baseURL: URL = URL(string: "https://api.anthropic.com")!) -> URLRequest {
        var url = URLComponents(url: baseURL.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "limit", value: "1")]
        var req = URLRequest(url: url.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return req
    }

    static func interpret(status: Int) -> Result {
        switch status {
        case 200..<300: return .valid
        case 401, 403: return .rejected
        case 429: return .problem("The key works, but the API is busy right now. It's saved.")
        case 500...: return .problem("Claude's API is having trouble (\(status)). The key is saved; try again later.")
        default: return .problem("Unexpected answer from the API (\(status)).")
        }
    }

    static func interpret(error: Error) -> Result {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return .offline
            default: break
            }
        }
        return .problem(error.localizedDescription)
    }

    static func check(_ key: String, session: URLSession = .shared) async -> Result {
        if formatProblem(key) != nil { return .rejected }
        do {
            let (_, response) = try await session.data(for: request(key: key))
            guard let http = response as? HTTPURLResponse else { return .problem("No answer from the API.") }
            return interpret(status: http.statusCode)
        } catch {
            return interpret(error: error)
        }
    }
}
