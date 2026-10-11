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
    private var outline: Outline? {
        didSet {
            hasOutline = outline != nil
            ar.lockPaperSize = outline != nil
            outlineRevision += 1
        }
    }
    private var outlineRevision = 0
    /// Strokes moved by the drift correction, rebuilt only when the outline or
    /// the correction changes (not on every rendered frame).
    private var mappedStrokes: (revision: Int, map: Affine2?, strokes: [Stroke])?
    private var tracker: CompletionTracker?

    // Drift correction: keeps the outline on the actual pencil lines. The
    // reference is the page as the AI saw it; `correction` maps the current
    // top-down view onto it (pixels of an alignWidth-wide image).
    private var aligner: DrawingAligner?
    private var correction = Affine2.identity
    private var aligning = false
    /// A big jump waiting for a second reading to confirm it (repeated shapes,
    /// like two identical legs, can fool a single match by exactly one shape).
    private var pendingJump: Affine2?
    /// When the drawing aligner last locked on. If it loses the drawing for a
    /// while (page moved far, looking away), paper-edge detection takes over again.
    private var lastLock: TimeInterval = 0
    private let alignQueue = DispatchQueue(label: "drawcompanion.align", qos: .userInitiated)
    private static let alignWidth = 480
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
    private var alignTimer: Timer?
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
        alignTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.alignStep() }
        }
    }

    func refreshKey() {
        usingMock = Keychain.apiKey == nil || UserDefaults.standard.bool(forKey: AppSettings.mockMode)
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
        if !usingMock, let key = Keychain.apiKey { return ClaudeBackend(client: ClaudeClient(config: .init(apiKey: key))) }
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
              let baseline = PageImaging.gray(frame.capturedImage, corners: corners, width: Self.trackWidth, height: trackH),
              let reference = PageImaging.gray(frame.capturedImage, corners: corners, width: Self.alignWidth, height: alignHeight)
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
                    self?.handle(event, turn: id, utterances: utterances, baseline: (baseline, trackH), paper: paper, style: style, reference: reference)
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
                        paper: PaperSize, style: InkStyle, reference: [Float]) {
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
                beginOutline(action: turnAction, utterances: utterances, style: style, reference: reference)
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
    private func beginOutline(action: TurnAction, utterances: [String], style: InkStyle, reference: [Float]) {
        let previous = (outline, tracker, trackState, fadeStart, aligner, correction)
        rollback = { [weak self] in
            guard let self else { return }
            (self.outline, self.tracker, self.trackState, self.fadeStart, self.aligner, self.correction) = previous
        }
        // The new outline's coordinates refer to this exact photo: align to it.
        aligner = DrawingAligner(reference: reference, width: Self.alignWidth, height: alignHeight)
        correction = .identity
        pendingJump = nil
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
        ar.followDrawing = false
        aligner = nil
        correction = .identity
        pendingJump = nil
        outline = nil
        tracker = nil
        trackState = nil
        fadeStart = nil
    }

    private var alignHeight: Int { Int((Double(Self.alignWidth) * ar.paper.h / ar.paper.w).rounded()) }

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
        guard let raw = PageImaging.gray(frame.capturedImage, corners: corners, width: tracker.width, height: tracker.height) else { return }
        // Compare in the reference photo's frame, so drift doesn't look like ink.
        let gray = warpedToReference(raw, width: tracker.width, height: tracker.height)
        let state = tracker.update(gray, now: now)
        trackState = state
        if state.done { fadeStart = now }
    }

    // MARK: rendering

    // MARK: drift correction

    /// Measures how far the outline has drifted from the pencil lines (runs
    /// off the main thread, several times a second).
    private func alignStep() {
        if ar.followDrawing, CACurrentMediaTime() - lastLock > 1.5 { ar.followDrawing = false }
        guard let aligner, !aligning, fadeStart == nil, let frame = ar.session.currentFrame,
              let corners = ar.imageCorners(in: frame) else { return }
        aligning = true
        let pixelBuffer = frame.capturedImage
        let prior = correction
        let version = ar.version
        let (w, h) = (aligner.width, aligner.height)
        alignQueue.async { [weak self] in
            let found = PageImaging.gray(pixelBuffer, corners: corners, width: w, height: h)
                .flatMap { aligner.align(current: $0, prior: prior) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.aligning = false
                // The page was re-pinned since this started: the reading is stale.
                guard self.ar.version == version else { return }
                guard self.aligner === aligner, let found else {
                    print("[DC] align: no match")
                    return
                }
                let jump = hypot(found.tx - prior.tx, found.ty - prior.ty)
                if jump > 12 {
                    // Accept a big change only when the next reading agrees with it.
                    if let pending = self.pendingJump, hypot(found.tx - pending.tx, found.ty - pending.ty) < 5 {
                        self.pendingJump = nil
                        self.correction = found
                        print(String(format: "[DC] align: jump %.0f px confirmed", jump))
                        self.repinToDrawing()
                    } else {
                        self.pendingJump = found
                        print(String(format: "[DC] align: jump %.0f px held for confirmation", jump))
                    }
                    return
                }
                self.pendingJump = nil
                print(String(format: "[DC] align: shift %.1f,%.1f px  scale %.3f  rot %.3f", found.tx, found.ty, (found.a + found.d) / 2, (found.c - found.b) / 2))
                // Follow quickly; a little smoothing hides measurement jitter.
                self.correction = self.correction.blended(toward: found, by: 0.8)
                self.repinToDrawing()
            }
        }
    }

    /// Moves ARKit's page so the drawing sits exactly where it was measured,
    /// then starts the correction over from zero. Without this, ARKit's own
    /// error builds up as the phone moves and the correction has to chase it.
    private func repinToDrawing() {
        guard let map = referenceToCurrent else { return }
        let paper = ar.paper
        let cornersNow = [PaperPoint(x: 0, y: 0), PaperPoint(x: paper.w, y: 0),
                          PaperPoint(x: paper.w, y: paper.h), PaperPoint(x: 0, y: paper.h)]
        let moved = cornersNow.compactMap { ar.world(map.apply($0)) }
        guard moved.count == 4 else { return }
        ar.repin(moved)
        ar.followDrawing = true
        lastLock = CACurrentMediaTime()
        correction = .identity
        pendingJump = nil
    }

    /// Paper-units map from the reference photo (where the AI drew) to where
    /// that spot is in the current view of the page.
    private var referenceToCurrent: Affine2? {
        guard aligner != nil, correction != .identity, let inv = correction.inverse else { return nil }
        let k = ar.paper.w / Double(Self.alignWidth) // paper units per alignment pixel
        // inv is in pixels: convert p (units) -> px, map, -> units.
        return Affine2(a: inv.a, b: inv.b, tx: inv.tx * k, c: inv.c, d: inv.d, ty: inv.ty * k)
    }

    private func warpedToReference(_ gray: [Float], width: Int, height: Int) -> [Float] {
        guard let map = referenceToCurrent else { return gray }
        let k = ar.paper.w / Double(width) // paper units per pixel of this image
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = map.apply(PaperPoint(x: (Double(x) + 0.5) * k, y: (Double(y) + 0.5) * k))
                let sx = min(width - 1, max(0, Int(p.x / k))), sy = min(height - 1, max(0, Int(p.y / k)))
                out[y * width + x] = gray[sy * width + sx]
            }
        }
        return out
    }

    func scene() -> Renderer.Scene {
        let fade = fadeStart.map { Float(max(0, 1 - (CACurrentMediaTime() - $0) / 0.9)) } ?? 1
        let map = referenceToCurrent
        let strokes: [Stroke]
        if let cached = mappedStrokes, cached.revision == outlineRevision, cached.map == map {
            strokes = cached.strokes
        } else {
            var fresh = outline?.strokes ?? []
            if let map { fresh = fresh.map { var s = $0; s.points = s.points.map(map.apply); return s } }
            mappedStrokes = (outlineRevision, map, fresh)
            strokes = fresh
        }
        return Renderer.Scene(headset: headset, strokes: strokes, style: outline?.style ?? .fallback,
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
