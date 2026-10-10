import ARKit
import SwiftUI

/// App state and the turn loop. The microphone is always on; every finished
/// phrase goes to the AI with a photo of the page. The AI never answers back:
/// it draws a new outline, changes the current one, clears it, or ignores the
/// speech. The outline clears by itself 3 s after you stop tracing it.
@MainActor
final class AppModel: ObservableObject {
    @Published var headset = false
    @Published private(set) var listening = false
    @Published private(set) var working = false
    @Published private(set) var pageFound = false
    @Published private(set) var hasOutline = false
    @Published private(set) var lastHeard = ""
    @Published private(set) var problem: String?
    @Published private(set) var usingMock = true

    let ar = ARController()
    private let speech = SpeechListener()

    // The outline and how far it's been traced.
    private var outline: Outline? { didSet { hasOutline = outline != nil; ar.lockPaperSize = outline != nil } }
    private var tracker: CompletionTracker?
    private var trackState: CompletionTracker.State?
    private var fadeStart: TimeInterval?
    private var lastTrackCorners: [CGPoint]?

    // Turns: what was said and not yet acted on, the turn in flight, and how
    // to undo a half-drawn outline if that turn is cancelled.
    private var pending: [String] = []
    private var inflight: Task<Void, Never>?
    private var turnID = 0
    private var rollback: (() -> Void)?
    private var waitingForPage = false

    private var timer: Timer?
    private static let trackWidth = 200 // completion-tracking grid; height follows the paper

    init() {
        speech.onPhrase = { [weak self] in self?.heard($0) }
        speech.onState = { [weak self] state in
            guard let self else { return }
            self.listening = state == .listening
            switch state {
            case .denied: self.report("Microphone or speech access is off. Allow it in Settings › DrawCompanion.")
            case .unavailable: self.report("Speech recognition isn't available right now.")
            default: break
            }
        }
        refreshKey()
    }

    func start() {
        ar.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func refreshKey() {
        usingMock = Keychain.apiKey == nil
    }

    // MARK: listening

    func startListening() { Task { await speech.start() } }
    func stopListening() { speech.stop() }
    func toggleListening() { listening ? stopListening() : startListening() }

    func enterHeadset() {
        headset = true
        UIApplication.shared.isIdleTimerDisabled = true
        startListening()
    }

    func exitHeadset() {
        headset = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// A finished phrase (spoken, or typed in the phone view).
    func heard(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastHeard = text
        pending.append(text)
        sendTurn()
    }

    // MARK: turns

    private func makeBackend() -> TurnBackend {
        if let key = Keychain.apiKey { return ClaudeBackend(client: ClaudeClient(config: .init(apiKey: key))) }
        return MockBackend()
    }

    private func sendTurn() {
        // You kept talking: the turn in flight is out of date. Cancel it, put
        // back any outline it had started drawing, and send everything said
        // since the last completed turn together.
        inflight?.cancel()
        inflight = nil
        working = false
        rollback?()
        rollback = nil
        turnID += 1
        let id = turnID

        let trackH = trackHeight
        guard let frame = ar.session.currentFrame, let corners = ar.imageCorners(in: frame),
              let (photos, style) = PageImaging.photos(frame.capturedImage, corners: corners, paper: ar.paper),
              let baseline = PageImaging.gray(frame.capturedImage, corners: corners, width: Self.trackWidth, height: trackH)
        else {
            print("[DC] page not ready, waiting")
            waitingForPage = true // sent from tick() once the page is in view
            return
        }
        waitingForPage = false
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? photos.full.write(to: dir.appendingPathComponent("last-page.jpg"))
            try? photos.closeUp?.write(to: dir.appendingPathComponent("last-closeup.jpg"))
            print("[DC] page \(photos.full.count) B, close-up \(photos.closeUp?.count ?? 0) B of \(String(describing: photos.region)), paper \(ar.paper), ink \(style)")
        }
        let utterances = pending
        let current = outline
        let paper = ar.paper
        let backend = makeBackend()
        turnAction = .ignore
        turnDrawing = false
        working = true
        inflight = Task { [weak self] in
            do {
                try await backend.run(utterances: utterances, current: current, page: photos, paper: paper) { event in
                    self?.handle(event, turn: id, utterances: utterances, baseline: (baseline, trackH), paper: paper, style: style)
                }
            } catch {
                guard let self, id == self.turnID, !Task.isCancelled else { return }
                self.rollback?()
                self.rollback = nil
                self.pending.removeFirst(min(utterances.count, self.pending.count)) // don't retry forever
                print("[DC] turn error: \(error)")
                self.report(error.localizedDescription)
            }
            if let self, id == self.turnID {
                self.working = false
                self.inflight = nil
            }
        }
    }

    private var turnAction: TurnAction = .ignore
    private var turnDrawing = false

    private func handle(_ event: TurnEvent, turn id: Int, utterances: [String], baseline: (gray: [Float], height: Int),
                        paper: PaperSize, style: InkStyle) {
        guard id == turnID else { return } // a newer turn replaced this one
        switch event {
        case let .action(action):
            turnAction = action
            if action == .hide { clearOutline() }
        case let .stroke(stroke):
            if let f = stroke.points.first, let w = ar.world(f), let frame = ar.session.currentFrame {
                print("[DC] stroke \(stroke.role.rawValue) pts=\(stroke.points.count) first=\(f) img=\(String(describing: ARController.project(w, camera: frame.camera))) imgSize=\(frame.camera.imageResolution)")
            }
            if !turnDrawing {
                turnDrawing = true
                beginOutline(action: turnAction, utterances: utterances, style: style)
            }
            outline?.strokes.append(stroke)
        case .done:
            pending.removeFirst(min(utterances.count, pending.count))
            rollback = nil
            if turnDrawing { startTracking(baseline: baseline, paper: paper) }
        }
    }

    /// Show a new outline that is still arriving. Clearing is paused until
    /// it's complete; if the turn is cancelled first, the old outline returns.
    private func beginOutline(action: TurnAction, utterances: [String], style: InkStyle) {
        let previous = (outline, tracker, trackState, fadeStart)
        rollback = { [weak self] in
            guard let self else { return }
            (self.outline, self.tracker, self.trackState, self.fadeStart) = previous
        }
        let history = action == .revise && outline != nil ? outline!.history + utterances : utterances
        outline = Outline(strokes: [], history: history, style: style)
        tracker = nil
        trackState = nil
        fadeStart = nil
    }

    private func startTracking(baseline: (gray: [Float], height: Int), paper: PaperSize) {
        guard let outline else { return }
        tracker = CompletionTracker(baseline: baseline.gray, width: Self.trackWidth, height: baseline.height,
                                    paper: paper, strokes: outline.strokes, now: CACurrentMediaTime())
    }

    func clearOutline() {
        outline = nil
        tracker = nil
        trackState = nil
        fadeStart = nil
    }

    private var trackHeight: Int { Int((Double(Self.trackWidth) * ar.paper.h / ar.paper.w).rounded()) }

    // MARK: every 0.3 s: page status, waiting turns, tracing

    private func tick() {
        let now = CACurrentMediaTime()
        pageFound = ar.corners != nil && ar.trackingNormal
        if waitingForPage, ar.corners != nil, inflight == nil { sendTurn() }

        if let start = fadeStart, now - start > 0.9 { clearOutline() }
        guard let tracker, fadeStart == nil, let frame = ar.session.currentFrame,
              let corners = ar.imageCorners(in: frame) else { return }
        // Skip frames while the head (or page) moves fast: blurry and misaligned.
        defer { lastTrackCorners = corners }
        if let last = lastTrackCorners {
            let moved = zip(last, corners).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
            if moved > frame.camera.imageResolution.width * 0.02 { return }
        }
        guard let gray = PageImaging.gray(frame.capturedImage, corners: corners, width: tracker.width, height: tracker.height) else { return }
        let state = tracker.update(gray, now: now)
        trackState = state
        if state.done { fadeStart = now }
    }

    // MARK: rendering

    func scene() -> Renderer.Scene {
        let fade = fadeStart.map { Float(max(0, 1 - (CACurrentMediaTime() - $0) / 0.9)) } ?? 1
        return Renderer.Scene(headset: headset, strokes: outline?.strokes ?? [], style: outline?.style ?? .fallback,
                              progress: trackState?.strokes, fade: fade)
    }

    // MARK: problems (setup issues only; the AI itself never "says" anything)

    private func report(_ message: String) {
        problem = message
        let shown = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.problem == shown { self?.problem = nil }
        }
    }
}
