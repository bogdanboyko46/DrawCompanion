import Foundation

/// The Meshy API (api.meshy.ai), called from the phone: create a task, poll it,
/// download what it made. Same endpoints and fields as server/character/meshy.js.
struct MeshyClient {
    var apiKey: String
    private let base = URL(string: "https://api.meshy.ai")!

    enum Endpoint: String {
        case imageToImage = "/openapi/v1/image-to-image"
        case imageTo3d = "/openapi/v1/image-to-3d"
        case multiImageTo3d = "/openapi/v1/multi-image-to-3d"
    }

    struct MeshyError: LocalizedError {
        var message: String
        var retryable = false
        var errorDescription: String? { message }
    }

    struct Task: Decodable {
        var id: String?
        var status: String
        var progress: Double?
        var image_urls: [String]?
        var model_urls: [String: String]?
        var thumbnail_url: String?
        var task_error: TaskError?
        struct TaskError: Decodable { var message: String? }
    }

    func create(_ endpoint: Endpoint, body: [String: Any]) async throws -> String {
        let data = try await send("POST", endpoint.rawValue, body: body)
        struct Created: Decodable { var result: String?; var id: String? }
        let created = try JSONDecoder().decode(Created.self, from: data)
        guard let id = created.result ?? created.id else { throw MeshyError(message: "Meshy returned no task id.") }
        return id
    }

    func get(_ endpoint: Endpoint, _ id: String) async throws -> Task {
        try JSONDecoder().decode(Task.self, from: try await send("GET", "\(endpoint.rawValue)/\(id)"))
    }

    /// Polls until done. `progress` gets 0…1.
    func wait(_ endpoint: Endpoint, _ id: String, timeout: TimeInterval = 15 * 60,
              progress: @Sendable (Double) async -> Void) async throws -> Task {
        let deadline = Date().addingTimeInterval(timeout)
        var misses = 0
        while true {
            try _Concurrency.Task.checkCancellation()
            let task: Task
            do {
                task = try await get(endpoint, id)
                misses = 0
            } catch let error as MeshyError where error.retryable {
                misses += 1
                if misses > 5 { throw error }
                try await _Concurrency.Task.sleep(for: .seconds(3))
                continue
            }
            await progress(min(1, max(0, (task.progress ?? 0) / 100)))
            switch task.status {
            case "SUCCEEDED": return task
            case "FAILED", "CANCELED":
                throw MeshyError(message: "Meshy \(task.status.lowercased()): \(task.task_error?.message ?? "no details")")
            default:
                if Date() > deadline { throw MeshyError(message: "Meshy took too long.", retryable: true) }
                try await _Concurrency.Task.sleep(for: .seconds(3))
            }
        }
    }

    func download(_ url: String, to destination: URL) async throws {
        guard let remote = URL(string: url) else { throw MeshyError(message: "Bad download URL from Meshy.") }
        let (temp, response) = try await URLSession.shared.download(from: remote)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MeshyError(message: "Download failed for \(destination.lastPathComponent).", retryable: true)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temp, to: destination)
    }

    /// Cheap call to check the key works.
    func checkKey() async throws {
        _ = try await send("GET", "/openapi/v1/balance")
    }

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        for attempt in 0..<4 {
            if attempt > 0 { try await _Concurrency.Task.sleep(for: .seconds(Double(1 << attempt))) }
            let data: Data, response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                if attempt == 3 { throw MeshyError(message: "Couldn't reach Meshy: \(error.localizedDescription)", retryable: true) }
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            if (status == 429 || status >= 500), attempt < 3 { continue }
            struct Body: Decodable { var message: String? }
            let message = (try? JSONDecoder().decode(Body.self, from: data))?.message ?? String(data: data, encoding: .utf8) ?? ""
            if status == 401 { throw MeshyError(message: "The Meshy API key was rejected. Check it in Settings.") }
            if status == 402 { throw MeshyError(message: "Your Meshy account is out of credits.") }
            throw MeshyError(message: "Meshy error \(status): \(message.prefix(200))", retryable: status == 429 || status >= 500)
        }
        throw MeshyError(message: "Couldn't reach Meshy.", retryable: true)
    }
}
