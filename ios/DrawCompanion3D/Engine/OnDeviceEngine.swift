import Foundation
import UIKit

/// Where characters get made: on this phone (OnDeviceEngine) or by the
/// companion server on a Mac (CharacterAPI). Both report jobs the same way.
protocol CharacterBackend: Sendable {
    func create(jpeg: Data, hint: String) async throws -> CharacterJob
    func job(_ id: String) async throws -> CharacterJob
    func retry(_ id: String) async throws -> CharacterJob
    func list() async throws -> [CharacterJob]
    func resolve(_ path: String) -> URL
    func data(at path: String) async throws -> Data
    func download(_ path: String, to destination: URL) async throws
}

extension CharacterBackend {
    func image(at path: String) async throws -> UIImage {
        guard let image = UIImage(data: try await data(at: path)) else {
            throw CharacterAPI.ServerError(message: "Couldn't read an image.")
        }
        return image
    }
}

extension CharacterAPI: CharacterBackend {}

/// The whole drawing → 3D pipeline, running on the phone: Claude reads the
/// drawing, Meshy paints a concept (Claude checks it, one repaint if it drifted),
/// then Meshy sculpts a textured model and we download its USDZ. Characters are
/// static (no rig), which the app brings to life with procedural motion.
///
/// The app must stay open while a character is being made.
actor OnDeviceEngine: CharacterBackend {
    static let shared = OnDeviceEngine()

    // Settings, matching the server's defaults.
    private let imageModel = "nano-banana-pro"
    private let meshModel = "latest"
    private let polycount = 50_000

    private struct Work {
        var jpeg: Data
        var hint: String
        var sheet: ClaudeDirector.Sheet?
        var conceptTask: String?
        var conceptViews = 0
        var reviewed = false
        var sculptTask: String?
        var done: Set<GenerationStage> = []
    }

    private var jobs: [String: CharacterJob] = [:]
    private var work: [String: Work] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    private let library = LocalLibrary()

    private static let weights: [GenerationStage: Double] = [.read: 0.08, .concept: 0.17, .review: 0.05, .sculpt: 0.6, .package: 0.1]

    // MARK: CharacterBackend

    func create(jpeg: Data, hint: String) async throws -> CharacterJob {
        guard Keys.haveBoth else {
            throw CharacterAPI.ServerError(message: "Add your Anthropic and Meshy API keys in Settings first.")
        }
        let id = "d" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let folder = library.folder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let drawing = folder.appending(path: "drawing.jpg")
        try jpeg.write(to: drawing)
        let job = CharacterJob(
            id: id, status: .queued, stage: "queued", message: "Starting", progress: 0, stageProgress: 0,
            error: nil, createdAt: ISO8601DateFormatter().string(from: Date()),
            drawingUrl: drawing.absoluteString, conceptUrl: nil, thumbnailUrl: nil, character: nil, model: nil)
        jobs[id] = job
        work[id] = Work(jpeg: jpeg, hint: hint)
        start(id)
        return job
    }

    func job(_ id: String) async throws -> CharacterJob {
        if let job = jobs[id] { return job }
        if let saved = library.all().first(where: { $0.id == id }) { return saved }
        throw CharacterAPI.ServerError(message: "That character isn't on this phone.")
    }

    func retry(_ id: String) async throws -> CharacterJob {
        guard var job = jobs[id], work[id] != nil else {
            throw CharacterAPI.ServerError(message: "This character can't be retried. Scan the drawing again.")
        }
        job.status = .queued
        job.error = nil
        job.message = "Trying again"
        jobs[id] = job
        start(id)
        return job
    }

    func list() async throws -> [CharacterJob] { library.all() }

    nonisolated func resolve(_ path: String) -> URL {
        URL(string: path) ?? URL(fileURLWithPath: path)
    }

    nonisolated func data(at path: String) async throws -> Data {
        try Data(contentsOf: resolve(path))
    }

    nonisolated func download(_ path: String, to destination: URL) async throws {
        let source = resolve(path)
        guard source != destination else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }

    // MARK: Pipeline

    private func start(_ id: String) {
        running[id]?.cancel()
        running[id] = Task { await self.run(id) }
    }

    private func run(_ id: String) async {
        guard let anthropicKey = Keys.value(Keys.anthropic), let meshyKey = Keys.value(Keys.meshy) else {
            fail(id, "Add your Anthropic and Meshy API keys in Settings first.")
            return
        }
        let director = ClaudeDirector(apiKey: anthropicKey)
        let meshy = MeshyClient(apiKey: meshyKey)
        let folder = library.folder(id)
        do {
            guard var w = work[id] else { return }
            let drawingURI = "data:image/jpeg;base64," + w.jpeg.base64EncodedString()

            // 1. Claude reads the drawing.
            if !w.done.contains(.read) {
                enter(id, .read)
                let sheet = try await director.readDrawing(jpeg: w.jpeg, hint: w.hint)
                guard sheet.is_character else {
                    throw CharacterAPI.ServerError(message: sheet.reject_reason.isEmpty
                        ? "That doesn't look like a character yet. Try drawing a figure." : sheet.reject_reason)
                }
                w.sheet = sheet
                w.done.insert(.read)
                work[id] = w
                jobs[id]?.character = CharacterInfo(
                    name: sheet.name, summary: sheet.summary, greeting: sheet.greeting, bodyPlan: sheet.body_plan,
                    heightMeters: sheet.height_m, figureBox: sheet.figure_box, colors: sheet.colors,
                    personality: sheet.personality)
            }
            guard let sheet = w.sheet else { return }

            // 2. Paint a clean concept: front, side and back views of the same design.
            func paint(_ prompt: String) async throws {
                let task = try await meshy.create(.imageToImage, body: [
                    "ai_model": imageModel,
                    "prompt": prompt,
                    "reference_image_urls": [drawingURI],
                    "generate_multi_view": true,
                ])
                w.conceptTask = task
                work[id] = w
                let done = try await meshy.wait(.imageToImage, task) { p in await self.progress(id, p) }
                guard let first = done.image_urls?.first else { throw MeshyClient.MeshyError(message: "The concept came back empty.") }
                w.conceptViews = done.image_urls?.count ?? 1
                let file = folder.appending(path: "concept.png")
                try await meshy.download(first, to: file)
                jobs[id]?.conceptUrl = file.absoluteString
            }
            if !w.done.contains(.concept) {
                enter(id, .concept)
                try await paint(sheet.concept_prompt)
                w.done.insert(.concept)
                work[id] = w
            }

            // 3. Claude checks the concept against the drawing; one repaint if it drifted.
            if !w.done.contains(.review) {
                enter(id, .review)
                if !w.reviewed, let concept = try? Data(contentsOf: folder.appending(path: "concept.png")) {
                    w.reviewed = true
                    work[id] = w
                    if let review = try? await director.reviewConcept(
                        drawing: w.jpeg, concept: concept, conceptType: Self.imageType(concept), sheet: sheet),
                       !review.faithful, !review.revised_prompt.isEmpty {
                        progress(id, 0.3)
                        try await paint(String(review.revised_prompt.prefix(800)))
                    }
                }
                w.done.insert(.review)
                work[id] = w
            }

            // 4. Sculpt the textured 3D model from the concept views.
            enter(id, .sculpt)
            let endpoint: MeshyClient.Endpoint = w.conceptViews > 1 ? .multiImageTo3d : .imageTo3d
            if w.sculptTask == nil {
                var body: [String: Any] = [
                    "ai_model": meshModel,
                    "should_texture": true,
                    "enable_pbr": true,
                    "texture_prompt": sheet.texture_prompt,
                    "should_remesh": true,
                    "target_polycount": polycount,
                    "topology": "triangle",
                    "target_formats": ["usdz", "glb"],
                ]
                if let concept = w.conceptTask { body["input_task_id"] = concept } else { body["image_url"] = drawingURI }
                w.sculptTask = try await meshy.create(endpoint, body: body)
                work[id] = w
            }
            let sculpt = try await meshy.wait(endpoint, w.sculptTask!) { p in await self.progress(id, p) }
            w.done.insert(.sculpt)
            work[id] = w

            // 5. Bring the model onto the phone.
            enter(id, .package)
            guard let usdz = sculpt.model_urls?["usdz"] else {
                throw MeshyClient.MeshyError(message: "The 3D model came back without a USDZ file.")
            }
            try await meshy.download(usdz, to: library.modelURL(id))
            if let thumb = sculpt.thumbnail_url {
                try? await meshy.download(thumb, to: library.thumbnailURL(id))
            }
            guard var job = jobs[id] else { return }
            job.model = ModelInfo(url: library.modelURL(id).absoluteString, animated: false, clips: [])
            if FileManager.default.fileExists(atPath: library.thumbnailURL(id).path) {
                job.thumbnailUrl = library.thumbnailURL(id).absoluteString
            }
            job.status = .ready
            job.stage = "done"
            job.message = "\(sheet.name) is ready"
            job.progress = 1
            job.stageProgress = 1
            jobs[id] = job
            try? JSONEncoder().encode(job).write(to: folder.appending(path: "job.json"))
        } catch is CancellationError {
            return
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    private func enter(_ id: String, _ stage: GenerationStage) {
        guard var job = jobs[id] else { return }
        job.status = .running
        job.stage = stage.rawValue
        job.message = stage.title
        job.stageProgress = 0
        jobs[id] = job
        progress(id, 0)
    }

    private func progress(_ id: String, _ p: Double) {
        guard var job = jobs[id], let stage = GenerationStage(rawValue: job.stage) else { return }
        job.stageProgress = max(job.stageProgress ?? 0, min(1, p))
        let done = work[id]?.done ?? []
        var total = 0.0
        for (s, weight) in Self.weights {
            if done.contains(s) { total += weight } else if s == stage { total += weight * (job.stageProgress ?? 0) }
        }
        job.progress = min(0.99, total)
        jobs[id] = job
    }

    private func fail(_ id: String, _ message: String) {
        guard var job = jobs[id] else { return }
        job.status = .failed
        job.error = message
        jobs[id] = job
    }

    private static func imageType(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if bytes.count >= 12, String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return "image/webp" }
        return "image/png"
    }
}
