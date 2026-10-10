import Foundation
import UIKit

/// Talks to the companion server (`npm start` / `npm run mock` in the repo root).
/// API keys live on the server; the phone only sends the page photo.
struct CharacterAPI: Sendable {
    var baseURL: URL

    struct ServerError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    func create(jpeg: Data, hint: String) async throws -> CharacterJob {
        let body: [String: String] = [
            "image": "data:image/jpeg;base64," + jpeg.base64EncodedString(),
            "hint": hint,
        ]
        var request = URLRequest(url: baseURL.appending(path: "api/characters"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        return try await send(request)
    }

    func job(_ id: String) async throws -> CharacterJob {
        try await send(URLRequest(url: baseURL.appending(path: "api/characters/\(id)")))
    }

    func retry(_ id: String) async throws -> CharacterJob {
        var request = URLRequest(url: baseURL.appending(path: "api/characters/\(id)/retry"))
        request.httpMethod = "POST"
        return try await send(request)
    }

    func list() async throws -> [CharacterJob] {
        struct Page: Decodable { var characters: [CharacterJob] }
        let page: Page = try await send(URLRequest(url: baseURL.appending(path: "api/characters")))
        return page.characters
    }

    /// Server paths come back relative ("/api/characters/…"); resolve them here.
    func resolve(_ path: String) -> URL {
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    func data(at path: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: resolve(path))
        try check(response, data)
        return data
    }

    func image(at path: String) async throws -> UIImage {
        guard let image = UIImage(data: try await data(at: path)) else {
            throw ServerError(message: "The server sent an unreadable image.")
        }
        return image
    }

    func download(_ path: String, to destination: URL) async throws {
        let (temp, response) = try await URLSession.shared.download(from: resolve(path))
        try check(response, nil)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temp, to: destination)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func check(_ response: URLResponse, _ data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            struct Body: Decodable { var error: String }
            let message = data.flatMap { try? JSONDecoder().decode(Body.self, from: $0).error }
            throw ServerError(message: message ?? "Server error \(http.statusCode)")
        }
    }
}

/// Characters you've made, kept on the device so they can be placed again
/// offline: Application Support/Characters/<id>/{job.json, character.usdz, thumb.png}.
struct LocalLibrary {
    let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Characters", directoryHint: .isDirectory)
    }()

    func folder(_ id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }
    func modelURL(_ id: String) -> URL { folder(id).appending(path: "character.usdz") }
    func thumbnailURL(_ id: String) -> URL { folder(id).appending(path: "thumb.png") }

    func hasModel(_ id: String) -> Bool { FileManager.default.fileExists(atPath: modelURL(id).path) }

    func all() -> [CharacterJob] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return ids.compactMap { id in
            guard let data = try? Data(contentsOf: folder(id).appending(path: "job.json")) else { return nil }
            return try? JSONDecoder().decode(CharacterJob.self, from: data)
        }
        .filter { $0.status == .ready && hasModel($0.id) }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Downloads the model (and thumbnail) for a finished job and records it.
    @discardableResult
    func save(_ job: CharacterJob, using api: any CharacterBackend) async throws -> URL {
        guard let model = job.model else { throw CharacterAPI.ServerError(message: "The character has no model yet.") }
        try FileManager.default.createDirectory(at: folder(job.id), withIntermediateDirectories: true)
        if !hasModel(job.id) {
            try await api.download(model.url, to: modelURL(job.id))
        }
        if let thumb = job.thumbnailUrl, !FileManager.default.fileExists(atPath: thumbnailURL(job.id).path) {
            try? await api.download(thumb, to: thumbnailURL(job.id))
        }
        try JSONEncoder().encode(job).write(to: folder(job.id).appending(path: "job.json"))
        return modelURL(job.id)
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
    }
}
