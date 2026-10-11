import Observation
import ReplayKit
import SwiftUI

struct SpeechLine: Equatable, Identifiable {
    let id = UUID()
    var characterID: String
    var name: String
    var text: String
}

struct SnapshotItem: Identifiable {
    let id = UUID()
    var image: UIImage
}

struct RecordingItem: Identifiable {
    let id = UUID()
    var controller: RPPreviewViewController
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case scanning, capturing, making, alive }

    var phase: Phase = .scanning
    var hint = ""
    var job: CharacterJob?
    var drawingImage: UIImage?
    var conceptImage: UIImage?
    var errorMessage: String?
    var failedJobID: String?
    var speech: [String: SpeechLine] = [:]
    var heads: [String: CGPoint] = [:]
    var library: [CharacterJob] = []
    var showLibrary = false
    var showSettings = false
    var snapshot: SnapshotItem?
    var recording: RecordingItem?
    var isRecording = false
    var serverAddress: String
    /// Generate with the companion server on a Mac instead of on this phone.
    var useServer: Bool
    var keysReady = Keys.haveBoth

    @ObservationIgnored let scene = SceneController()
    @ObservationIgnored private let local = LocalLibrary()
    @ObservationIgnored private var page: CapturedPage?
    @ObservationIgnored private var speechTimers: [String: Task<Void, Never>] = [:]

    var hasCharacters: Bool { !scene.actors.isEmpty }

    var api: CharacterAPI {
        CharacterAPI(baseURL: URL(string: serverAddress.trimmingCharacters(in: .whitespaces)) ?? URL(string: "http://localhost:8787")!)
    }

    /// Where characters are made: this phone by default, or the Mac server.
    var backend: any CharacterBackend { useServer ? api : OnDeviceEngine.shared }

    /// The stages shown while making a character. On the phone there's no rig or animation.
    var stages: [GenerationStage] {
        useServer ? GenerationStage.allCases : [.read, .concept, .review, .sculpt, .package]
    }

    init() {
        serverAddress = UserDefaults.standard.string(forKey: "serverAddress") ?? "http://192.168.1.10:8787"
        useServer = UserDefaults.standard.bool(forKey: "useServer")
        Keys.importBundledDevKeys()
        keysReady = Keys.haveBoth
        scene.onHeadPositions = { [weak self] heads in
            guard let self, !self.speech.isEmpty else { return }
            self.heads = heads
        }
        scene.onSpeak = { [weak self] character, text in self?.say(text, by: character) }
        refreshLibrary()
    }

    // MARK: Making a character

    func bringToLife() {
        guard phase == .scanning || phase == .alive else { return }
        Task { await make() }
    }

    private func make() async {
        if !useServer && !keysReady {
            errorMessage = "Add your Anthropic and Meshy API keys in Settings to make characters on this phone."
            showSettings = true
            return
        }
        errorMessage = nil
        failedJobID = nil
        phase = .capturing
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()

        let captured: CapturedPage
        do {
            captured = try await scene.capturePage()
        } catch {
            return fail(error)
        }
        page = captured
        drawingImage = UIImage(cgImage: captured.image)
        conceptImage = nil
        scene.beginPortal(for: captured)
        phase = .making

        do {
            let job = try await backend.create(jpeg: captured.figureJPEG ?? captured.jpeg, hint: hint)
            self.job = job
            try await follow(job)
        } catch {
            scene.cancelPortal()
            fail(error)
        }
    }

    func retryFailed() {
        guard let id = failedJobID, phase == .scanning || phase == .alive else { return }
        errorMessage = nil
        failedJobID = nil
        phase = .making
        Task {
                do {
                let job = try await backend.retry(id)
                self.job = job
                if let page { scene.beginPortal(for: page) }
                try await follow(job)
            } catch {
                scene.cancelPortal()
                fail(error)
            }
        }
    }

    /// Polls the job, driving the portal, until the character can come out.
    private func follow(_ start: CharacterJob) async throws {
        var job = start
        var misses = 0
        var shownConcept: String?
        var lifted = false
        while job.status == .queued || job.status == .running {
            try await Task.sleep(for: .seconds(1.2))
            do {
                job = try await backend.job(job.id)
                misses = 0
            } catch {
                misses += 1
                if misses > 10 { throw error } // ~12 s of no server
                continue
            }
            self.job = job
            if !lifted {
                lifted = true
                scene.liftPortal()
            }
            // The concept can change once (when the front view is picked); show the latest.
            if let url = job.conceptUrl, url != shownConcept {
                shownConcept = url
                Task {
                    let image = try? await backend.image(at: url)
                    guard let image, let cg = image.cgImage else { return }
                    // Vision is slow; keep it off the main thread.
                    let cut = await Task.detached { PageScanner.subjectCutout(cg) ?? cg }.value
                    conceptImage = image
                    scene.showConcept(cut)
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
            }
        }
        guard job.status == .ready else {
            failedJobID = job.id
            throw CharacterAPI.ServerError(message: job.error ?? "The character couldn't be made.")
        }
        let url = try await local.save(job, using: backend)
        _ = try await scene.materialize(job: job, modelURL: url, page: page)
        phase = .alive
        hint = ""
        refreshLibrary()
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        phase = hasCharacters ? .alive : .scanning
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    func dismissError() {
        errorMessage = nil
        failedJobID = nil
    }

    // MARK: Library

    func refreshLibrary() {
        library = local.all()
        Task {
            guard let remote = try? await backend.list() else { return }
            let known = Set(library.map(\.id))
            library += remote.filter { $0.status == .ready && !known.contains($0.id) }
        }
    }

    func place(_ job: CharacterJob) {
        showLibrary = false
        guard phase == .scanning || phase == .alive else {
            errorMessage = "Wait for the current character to finish, then place this one."
            return
        }
        Task {
            do {
                let url = try await local.save(job, using: backend)
                _ = try await scene.place(job: job, modelURL: url)
                phase = .alive
                refreshLibrary()
            } catch {
                fail(error)
            }
        }
    }

    func delete(_ job: CharacterJob) {
        local.delete(job.id)
        library.removeAll { $0.id == job.id }
    }

    func thumbnail(for job: CharacterJob) -> URL {
        let file = local.thumbnailURL(job.id)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        return backend.resolve(job.thumbnailUrl ?? job.drawingUrl)
    }

    func clearRoom() {
        scene.removeAll()
        speech.removeAll()
        phase = .scanning
    }

    // MARK: Speech

    private func say(_ text: String, by character: CharacterActor) {
        let id = character.job.id
        speech[id] = SpeechLine(characterID: id, name: character.name, text: text)
        speechTimers[id]?.cancel()
        speechTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { _ = self?.speech.removeValue(forKey: id) }
        }
    }

    // MARK: Sharing

    func takeSnapshot() {
        Task {
            if let image = await scene.snapshot() {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                snapshot = SnapshotItem(image: image)
            }
        }
    }

    func toggleRecording() {
        let recorder = RPScreenRecorder.shared()
        if recorder.isRecording {
            recorder.stopRecording { [weak self] preview, error in
                Task { @MainActor in
                    self?.isRecording = false
                    if let preview { self?.recording = RecordingItem(controller: preview) }
                    if let error { self?.errorMessage = error.localizedDescription }
                }
            }
        } else {
            recorder.isMicrophoneEnabled = false
            recorder.startRecording { [weak self] error in
                Task { @MainActor in
                    self?.isRecording = error == nil
                    if let error { self?.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    // MARK: Server

    func saveServerAddress() {
        UserDefaults.standard.set(serverAddress, forKey: "serverAddress")
    }

    func saveUseServer() {
        UserDefaults.standard.set(useServer, forKey: "useServer")
        refreshLibrary()
    }

    func saveKeys(anthropic: String, meshy: String) {
        if !anthropic.isEmpty { Keys.set(anthropic, for: Keys.anthropic) }
        if !meshy.isEmpty { Keys.set(meshy, for: Keys.meshy) }
        keysReady = Keys.haveBoth
    }

    /// Checks both keys with free calls (Anthropic model list, Meshy balance).
    func testKeys() async -> String {
        guard let a = Keys.value(Keys.anthropic), let m = Keys.value(Keys.meshy) else {
            return "Add both keys first."
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        request.setValue(a, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let claude: String
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            claude = status == 200 ? "Anthropic ✓" : "Anthropic key rejected (\(status))"
        } catch {
            claude = "Anthropic unreachable"
        }
        let meshy: String
        do {
            try await MeshyClient(apiKey: m).checkKey()
            meshy = "Meshy ✓"
        } catch {
            meshy = error.localizedDescription
        }
        return "\(claude) · \(meshy)"
    }

    func testConnection() async -> String {
        do {
            let list = try await api.list()
            return "Connected · \(list.count) character\(list.count == 1 ? "" : "s") on the server"
        } catch {
            return "Couldn't reach the server: \(error.localizedDescription)"
        }
    }
}
