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

    // Measured on a real drawing: meshy-6-lite from the three concept views
    // builds the model in ~55 s (vs ~6 min for "latest" with remesh and PBR)
    // with the same look on a phone, so a character takes under 2 minutes.
    private let imageModel = "nano-banana-2" // 16 s for 3 views vs 35 s for -pro, and more faithful
    private let meshModel = "meshy-6-lite"

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

    private static let weights: [GenerationStage: Double] = [.read: 0.05, .concept: 0.3, .sculpt: 0.55, .package: 0.1]

    /// The concept prompt. It doesn't wait for Claude: the image model sees the
    /// drawing itself, and this tells it how to render that faithfully.
    static func conceptPrompt(hint: String) -> String {
        var p = """
        Turn this drawing into a polished, stylized 3D toy character render of exactly this character: \
        keep its silhouette, proportions (a big head stays big), face, number and shape of limbs, \
        accessories and colors; don't redesign or realistify it. An uncolored pencil drawing becomes a \
        clean white or cream figure with its lines as dark details. Full body in frame, facing the viewer, \
        natural standing pose with limbs apart, plain white background, soft studio light, no text.
        """
        if !hint.isEmpty { p += " The artist says: \(hint.prefix(200))" }
        return String(p.prefix(800))
    }

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

            // The critical path is Meshy only: paint the concept, then build the 3D
            // model from it. Everything Claude does runs alongside and never holds
            // it up: reading the drawing gives the name, greeting and personality;
            // checking the concept picks which view to show as the front.
            enter(id, .read)
            let jpeg = w.jpeg, hint = w.hint
            let reading: Task<ClaudeDirector.Sheet, Error>? = w.sheet == nil
                ? Task { try await director.readDrawing(jpeg: jpeg, hint: hint) } : nil

            // 1. Paint a clean concept: front, side and back views of the same design.
            enter(id, .concept)
            if w.conceptTask == nil || !w.done.contains(.concept) {
                let task = try await meshy.create(.imageToImage, body: [
                    "ai_model": imageModel,
                    "prompt": Self.conceptPrompt(hint: hint),
                    "reference_image_urls": [drawingURI],
                    "generate_multi_view": true,
                ])
                w.conceptTask = task
                work[id] = w
            }
            let concept = try await meshy.wait(.imageToImage, w.conceptTask!) { p in await self.progress(id, p) }
            let urls = concept.image_urls ?? []
            guard !urls.isEmpty else { throw MeshyClient.MeshyError(message: "The concept came back empty.") }
            w.conceptViews = urls.count
            w.done.insert(.concept)
            work[id] = w

            // 2. Start the 3D build right away; it only needs the concept's id.
            enter(id, .sculpt)
            let endpoint: MeshyClient.Endpoint = urls.count > 1 ? .multiImageTo3d : .imageTo3d
            if w.sculptTask == nil {
                var body: [String: Any] = [
                    "ai_model": meshModel,
                    "should_texture": true,
                    "enable_pbr": false,
                    "should_remesh": false,
                    "target_formats": ["usdz"],
                    "input_task_id": w.conceptTask!,
                ]
                if let texture = w.sheet?.texture_prompt, !texture.isEmpty { body["texture_prompt"] = texture }
                w.sculptTask = try await meshy.create(endpoint, body: body)
                work[id] = w
            }
            let sculptTask = w.sculptTask!

            // 3. While it builds: fetch the views for the reveal, and finish reading.
            let files = await withTaskGroup(of: (Int, String?).self) { group in
                for (i, url) in urls.enumerated() {
                    group.addTask {
                        let file = folder.appending(path: "view-\(i).png")
                        return (i, (try? await meshy.download(url, to: file)) != nil ? file.absoluteString : nil)
                    }
                }
                var out = [String?](repeating: nil, count: urls.count)
                for await (i, f) in group { out[i] = f }
                return out.compactMap { $0 }
            }
            jobs[id]?.conceptViews = files
            showView(id, urls.count > 2 ? 1 : 0) // a guess until the check picks the front

            if let reading {
                do {
                    let sheet = try await reading.value
                    guard sheet.is_character else {
                        throw CharacterAPI.ServerError(message: sheet.reject_reason.isEmpty
                            ? "That doesn't look like a character yet. Try drawing a figure." : sheet.reject_reason)
                    }
                    w.sheet = sheet
                } catch let error as CharacterAPI.ServerError {
                    throw error
                } catch {
                    // Claude unreachable: the model is still coming, so carry on with defaults.
                    print("[engine] \(id) reading failed, using defaults: \(error.localizedDescription)")
                }
                work[id] = w
            }
            w.done.insert(.read)
            work[id] = w
            if let sheet = w.sheet {
                jobs[id]?.character = CharacterInfo(
                    name: sheet.name, summary: sheet.summary, greeting: sheet.greeting, bodyPlan: sheet.body_plan,
                    heightMeters: sheet.height_m, figureBox: sheet.figure_box, colors: sheet.colors,
                    personality: sheet.personality)
            }

            if !w.reviewed, let sheet = w.sheet, files.count > 1 {
                w.reviewed = true
                work[id] = w
                let views = (0..<urls.count).compactMap { i -> (data: Data, type: String)? in
                    guard let d = try? Data(contentsOf: folder.appending(path: "view-\(i).png")) else { return nil }
                    return (d, Self.imageType(d))
                }
                Task {
                    if let review = try? await director.reviewConcept(drawing: jpeg, views: views, sheet: sheet) {
                        self.showView(id, review.front_index)
                    }
                }
            }

            let sculpt = try await meshy.wait(endpoint, sculptTask) { p in await self.progress(id, p) }
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
            job.message = "\(w.sheet?.name ?? "Your character") is ready"
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

    /// Shows one of the concept's views (as concept.png) on the paper.
    private func showView(_ id: String, _ index: Int) {
        let folder = library.folder(id)
        let source = folder.appending(path: "view-\(index).png")
        let file = folder.appending(path: "concept.png")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.copyItem(at: source, to: file)
        // A new path each time so the app notices the change.
        jobs[id]?.conceptUrl = file.absoluteString + "#\(index)"
    }

    private func enter(_ id: String, _ stage: GenerationStage) {
        print("[engine] \(id) → \(stage.rawValue)")
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
        print("[engine] \(id) FAILED: \(message)")
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
