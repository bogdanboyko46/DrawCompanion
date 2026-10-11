import ARKit
import SwiftUI

/// App state and the turn loop. The microphone is always on; every finished
/// phrase goes to the AI with a photo of the page. The AI never answers back:
/// it draws a new outline, changes the current one, clears it, or ignores the
/// speech. The outline clears by itself 3 s after you stop tracing it.
@MainActor
final class AppModel: ObservableObject {
    @Published var headset = false
    /// The side-by-side headset view is switched off for now: the app uses the
    /// normal full-screen AR view. Flip to true to bring the headset view back.
    static let headsetAvailable = false
    @Published private(set) var listening = false
    @Published private(set) var working = false
    @Published private(set) var pageFound = false
    /// What to do so the page can be found (shown while it isn't).
    @Published private(set) var pageHint = "Looking for paper"
    @Published private(set) var hasOutline = false
    @Published private(set) var lastHeard = ""
    @Published private(set) var problem: String?
    @Published private(set) var usingMock = true
    /// A nicer version of the new outline is being drawn on the Mac.
    @Published private(set) var refining = false
    /// Bumped on each wave, so the view can flash the mic's new state.
    @Published private(set) var waves = 0

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
    /// The previous small reading, so the outline only moves when two in a row agree.
    private var lastReading: Affine2?
    /// Where the page was in the camera image at the last alignment, to skip
    /// frames taken while the head moves fast (blurry, and the match wobbles).
    private var lastAlignCorners: [CGPoint]?
    private let alignQueue = DispatchQueue(label: "drawcompanion.align", qos: .userInitiated)
    private static let alignWidth = 480
    private var trackState: CompletionTracker.State?
    private var fadeStart: TimeInterval?
    private var lastTrackCorners: [CGPoint]?
    private var tracking = false
    private var lastWarm: TimeInterval = 0
    private let trackQueue = DispatchQueue(label: "drawcompanion.track", qos: .userInitiated)

    // Turns: what was said and not yet acted on, the turn in flight, and how
    // to undo a half-drawn outline if that turn is cancelled.
    private var pending: [String] = []
    private var inflight: Task<Void, Never>?
    private var turnID = 0
    private var rollback: (() -> Void)?
    private var waitingForPage = false
    private var lastPhraseAt: TimeInterval = 0

    private var upgradeTask: Task<Void, Never>?
    /// The tracing baseline of the current outline, to restart tracking when
    /// its strokes are swapped for the upgraded ones.
    private var trackBaseline: (gray: [Float], height: Int, paper: PaperSize)?

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
        // Fully hands-free: wave an open hand at the camera to turn the mic off or on.
        ar.onWave = { [weak self] in
            guard let self else { return }
            self.toggleListening()
            self.waves += 1
        }
    }

    func start() {
        // Drawing takes a while and the phone sits still: don't let it lock.
        UIApplication.shared.isIdleTimerDisabled = true
        ar.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        alignTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.alignStep() }
        }
        checkUpgradeServer()
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
    }

    /// A finished phrase (spoken, or typed in the phone view).
    func heard(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastHeard = text
        // While a drawing is coming in, speech is ignored: the drawing always
        // finishes, and nothing said meanwhile changes or restarts it.
        // (Restarting on every pause made a request take 2-3x as long.)
        // Before the filter has decided, phrases still combine into one request.
        if inflight != nil, turnAction == .new || turnAction == .revise {
            print("[DC] ignored while drawing: \(text)")
            return
        }
        // Waiting for the page: what was said long ago is stale; don't send it
        // later bundled with today's request ("draw a cat" said five times).
        let now = CACurrentMediaTime()
        if waitingForPage, now - lastPhraseAt > 15 { pending.removeAll() }
        lastPhraseAt = now
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
        let alignH = alignHeight
        guard let frame = ar.session.currentFrame, let corners = ar.imageCorners(in: frame) else {
            print("[DC] page not ready, waiting")
            waitingForPage = true // sent from tick() once the page is in view
            return
        }
        waitingForPage = false
        let pixelBuffer = frame.capturedImage
        let utterances = pending
        let current = outline
        let paper = ar.paper
        let backend = makeBackend()
        let t0 = CACurrentMediaTime()
        turnAction = .ignore
        turnDrawing = false
        working = true
        inflight = Task { [weak self] in
            // Photo work happens off the main thread so the camera and UI stay live.
            let prepared = await Task.detached(priority: .userInitiated) { () -> (PagePhotos, InkStyle, [Float], [Float])? in
                guard let (photos, style) = PageImaging.photos(pixelBuffer, corners: corners, paper: paper),
                      let baseline = PageImaging.gray(pixelBuffer, corners: corners, width: Self.trackWidth, height: trackH),
                      let reference = PageImaging.gray(pixelBuffer, corners: corners, width: Self.alignWidth, height: alignH)
                else { return nil }
                if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? photos.full.write(to: dir.appendingPathComponent("last-page.jpg"))
                    try? photos.closeUp?.write(to: dir.appendingPathComponent("last-closeup.jpg"))
                }
                return (photos, style, baseline, reference)
            }.value
            guard let self, id == self.turnID, !Task.isCancelled else { return }
            guard let (photos, style, baseline, reference) = prepared else {
                self.working = false
                self.inflight = nil
                self.waitingForPage = true
                return
            }
            print(String(format: "[DC] t+%.0f ms photos ready (page %d B, close-up %d B), paper %@, ink %@",
                         (CACurrentMediaTime() - t0) * 1000, photos.full.count, photos.closeUp?.count ?? 0,
                         String(describing: paper), String(describing: style)))
            do {
                try await backend.run(utterances: utterances, current: current, page: photos, paper: paper) { event in
                    if case .action(let a) = event { print(String(format: "[DC] t+%.0f ms action %@", (CACurrentMediaTime() - t0) * 1000, a.rawValue)) }
                    if case .stroke = event, self.turnDrawing == false { print(String(format: "[DC] t+%.0f ms first stroke", (CACurrentMediaTime() - t0) * 1000)) }
                    if case .done = event { print(String(format: "[DC] t+%.0f ms done", (CACurrentMediaTime() - t0) * 1000)) }
                    self.handle(event, turn: id, utterances: utterances, baseline: (baseline, trackH), paper: paper, style: style, reference: reference, page: photos.full)
                }
            } catch {
                guard id == self.turnID, !Task.isCancelled else { return }
                self.rollback?()
                self.rollback = nil
                self.pending.removeFirst(min(utterances.count, self.pending.count)) // don't retry forever
                print("[DC] turn error: \(error)")
                self.report(error.localizedDescription)
            }
            if id == self.turnID {
                self.working = false
                self.inflight = nil
            }
        }
    }

    private var turnAction: TurnAction = .ignore
    private var turnDrawing = false

    private func handle(_ event: TurnEvent, turn id: Int, utterances: [String], baseline: (gray: [Float], height: Int),
                        paper: PaperSize, style: InkStyle, reference: [Float], page: Data) {
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
            if turnDrawing {
                startTracking(baseline: baseline, paper: paper)
                if turnAction == .new { startUpgrade(page: page, paper: paper, said: utterances) }
            }
        }
    }

    // MARK: upgrade (image model on the Mac)

    /// Reaches the Mac's drawing server once at launch, so iOS asks for
    /// local-network access right away (not in the middle of a drawing), and
    /// the log says whether refining can work at all.
    /// Tries each address the Mac might be reachable at (Wi-Fi, or the USB
    /// cable's own link when the Wi-Fi keeps devices apart) and keeps the first
    /// that answers. Repeats every 30 s until one does.
    private func checkUpgradeServer() {
        guard AppSettings.upgradeEnabled else { return }
        for base in AppSettings.upgradeCandidates {
            var req = URLRequest(url: base.appendingPathComponent("health"))
            req.timeoutInterval = 6
            URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
                let ok = error == nil && (data.flatMap { String(data: $0, encoding: .utf8) } ?? "").contains("true")
                print("[DC] refine server \(base.absoluteString): \(ok ? "ok" : "unreachable (\(error?.localizedDescription ?? "bad reply"))")")
                guard ok else { return }
                DispatchQueue.main.async { if self?.upgradeBase == nil { self?.upgradeBase = base } }
            }.resume()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.upgradeBase == nil { self?.checkUpgradeServer() }
        }
    }
    /// The address of the Mac's drawing server that answered.
    private var upgradeBase: URL?

    /// Asks the Mac's drawing server for a nicer version of the outline just
    /// drawn. It swaps in only if this outline is still up and you haven't
    /// started tracing it; otherwise Claude's outline simply stays.
    private func startUpgrade(page: Data, paper: PaperSize, said: [String]) {
        upgradeTask?.cancel()
        refining = false
        guard !usingMock, AppSettings.upgradeEnabled, let url = upgradeBase ?? AppSettings.upgradeURL, let key = Keychain.apiKey,
              let strokes = outline?.strokes, let box = UpgradeClient.bounds(of: strokes) else { return }
        let revision = outlineRevision
        let id = String(format: "%04d", turnID)
        let t0 = CACurrentMediaTime()
        refining = true
        print("[DC] upgrade: asking \(url.absoluteString) for \(said)")
        upgradeTask = Task { [weak self] in
            let result: [Stroke]?
            do {
                result = try await UpgradeClient(baseURL: url, apiKey: key).upgrade(page: page, paper: paper, said: said, box: box, id: id)
            } catch {
                print("[DC] upgrade failed: \(error.localizedDescription)")
                result = nil
            }
            guard let self, !Task.isCancelled else { return }
            self.refining = false
            let secs = CACurrentMediaTime() - t0
            guard let result else { return }
            guard self.outlineRevision == revision, self.fadeStart == nil, var outline = self.outline else {
                print(String(format: "[DC] upgrade arrived after %.1f s but the outline changed: dropped", secs))
                return
            }
            let traced = self.trackState?.strokes.map(\.progress) ?? []
            let progress = traced.isEmpty ? 0 : traced.reduce(0, +) / Double(traced.count)
            guard progress < 0.15 else {
                print(String(format: "[DC] upgrade arrived after %.1f s, already %.0f%% traced: kept Claude's", secs, progress * 100))
                return
            }
            print(String(format: "[DC] upgrade: %d strokes after %.1f s, swapped in", result.count, secs))
            outline.strokes = result
            self.outline = outline
            if let b = self.trackBaseline { self.startTracking(baseline: (b.gray, b.height), paper: b.paper) }
        }
    }

    /// Show a new outline that is still arriving. Clearing is paused until
    /// it's complete; if the turn is cancelled first, the old outline returns.
    private func beginOutline(action: TurnAction, utterances: [String], style: InkStyle, reference: [Float]) {
        upgradeTask?.cancel()
        refining = false
        let previous = (outline, tracker, trackState, fadeStart, aligner, correction)
        rollback = { [weak self] in
            guard let self else { return }
            (self.outline, self.tracker, self.trackState, self.fadeStart, self.aligner, self.correction) = previous
        }
        // The new outline's coordinates refer to this exact photo: align to it.
        aligner = DrawingAligner(reference: reference, width: Self.alignWidth, height: alignHeight)
        correction = .identity
        lastReading = nil
        pendingJump = nil
        // From now on the drawing decides where the page is; paper-edge
        // detection (noisy on folded or curled paper) only takes over again if
        // the drawing is lost for a while.
        ar.followDrawing = aligner != nil
        dumpedAlignImages = false
        let h = alignHeight
        alignQueue.async { Self.dumpGray(reference, Self.alignWidth, h, name: "align-reference.pgm") }
        lastLock = CACurrentMediaTime()
        print("[DC] aligner \(aligner == nil ? "unavailable (no drawing found)" : "ready")")
        let history = action == .revise && outline != nil ? outline!.history + utterances : utterances
        outline = Outline(strokes: [], history: history, style: style)
        tracker = nil
        trackState = nil
        fadeStart = nil
    }

    private func startTracking(baseline: (gray: [Float], height: Int), paper: PaperSize) {
        guard let outline else { return }
        trackBaseline = (baseline.gray, baseline.height, paper)
        trackState = nil
        tracker = CompletionTracker(baseline: baseline.gray, width: Self.trackWidth, height: baseline.height,
                                    paper: paper, strokes: outline.strokes, now: CACurrentMediaTime())
    }

    func clearOutline() {
        upgradeTask?.cancel()
        refining = false
        ar.followDrawing = false
        aligner = nil
        correction = .identity
        pendingJump = nil
        lastReading = nil
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
        debugTick(now)
        pageFound = ar.corners != nil && ar.trackingNormal
        if !pageFound {
            let hint: String
            switch ar.lastMiss?.reason {
            case "page cut off by the view edge"?: hint = "Move back so the whole page is in view"
            case "page unsure"?, "no page seen"?: hint = "Show the whole page, hands off, for a second"
            case let r? where r.hasPrefix("detections"): hint = "Hold the phone still for a second"
            default: hint = "Looking for paper"
            }
            if pageHint != hint { pageHint = hint }
        }
        if waitingForPage, ar.corners != nil, inflight == nil { sendTurn() }
        // You started talking: open the connection to the API now, so the
        // request at the end of the phrase doesn't also wait for the handshake.
        if !usingMock, !LiveSpeech.shared.partial.isEmpty, now - lastWarm > 20 {
            lastWarm = now
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "HEAD" // unauthenticated and free; only the connection matters
            URLSession.shared.dataTask(with: req).resume()
        }

        if let start = fadeStart, now - start > 0.9 { clearOutline() }
        guard let tracker, fadeStart == nil, let frame = ar.session.currentFrame,
              let corners = ar.imageCorners(in: frame) else { return }
        // Skip frames while the head (or page) moves fast: blurry and misaligned.
        defer { lastTrackCorners = corners }
        if let last = lastTrackCorners {
            let moved = zip(last, corners).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
            if moved > frame.camera.imageResolution.width * 0.02 { return }
        }
        // Building the page image and comparing it takes several milliseconds:
        // done on the main thread it made the view hitch every 0.3 s.
        guard !tracking else { return }
        tracking = true
        let pixelBuffer = frame.capturedImage
        let map = referenceToCurrent
        let k = ar.paper.w / Double(tracker.width)
        trackQueue.async { [weak self] in
            var state: CompletionTracker.State?
            if let raw = PageImaging.gray(pixelBuffer, corners: corners, width: tracker.width, height: tracker.height) {
                // Compare in the reference photo's frame, so drift doesn't look like ink.
                let gray = Self.warped(raw, width: tracker.width, height: tracker.height, map: map, unitsPerPixel: k)
                state = tracker.update(gray, now: now)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.tracking = false
                // The outline was replaced or is already fading: this result is stale.
                guard let state, self.tracker === tracker, self.fadeStart == nil else { return }
                self.trackState = state
                if state.done {
                    let traced = state.strokes.map(\.progress)
                    print(String(format: "[DC] outline traced (%.0f%%) and left alone %.0f s: clearing", 100 * traced.reduce(0, +) / Double(max(1, traced.count)), state.idleSeconds))
                    self.fadeStart = now
                }
            }
        }
    }

    // MARK: rendering

    // MARK: drift correction

    /// Measures how far the outline has drifted from the pencil lines (runs
    /// off the main thread, several times a second).
    private func alignStep() {
        if ar.followDrawing, CACurrentMediaTime() - lastLock > 3 { ar.followDrawing = false }
        guard let aligner, !aligning, fadeStart == nil, let frame = ar.session.currentFrame,
              let corners = ar.imageCorners(in: frame) else { return }
        defer { lastAlignCorners = corners }
        if let last = lastAlignCorners {
            let moved = zip(last, corners).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
            if moved > frame.camera.imageResolution.width * 0.015 { return }
        }
        aligning = true
        let pixelBuffer = frame.capturedImage
        let prior = correction
        let version = ar.version
        let base = ar.corners
        let (w, h) = (aligner.width, aligner.height)
        let dump = !dumpedAlignImages
        dumpedAlignImages = true
        alignQueue.async { [weak self] in
            let current = PageImaging.gray(pixelBuffer, corners: corners, width: w, height: h)
            if dump, let current { Self.dumpGray(current, w, h, name: "align-current.pgm") }
            let found = current.flatMap { aligner.align(current: $0, prior: prior) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.aligning = false
                // The page was re-pinned since this started: the reading is stale.
                guard self.ar.version == version else {
                    print("[DC] align: dropped (page moved meanwhile)")
                    self.lastReading = nil
                    return
                }
                guard self.aligner === aligner, let found else {
                    print("[DC] align: no match")
                    return
                }
                let jump = Self.movement(found, w, h)
                if jump > 12 {
                    // Accept a big change only when the next reading agrees with it.
                    if let pending = self.pendingJump, hypot(found.tx - pending.tx, found.ty - pending.ty) < 5 {
                        self.pendingJump = nil
                        self.correction = found
                        print(String(format: "[DC] align: jump %.0f px confirmed", jump))
                        self.repinToDrawing(from: base)
                    } else {
                        self.pendingJump = found
                        print(String(format: "[DC] align: jump %.0f px held for confirmation", jump))
                    }
                    return
                }
                self.pendingJump = nil
                self.lastLock = CACurrentMediaTime()
                // Readings of a still page differ by up to about a pixel (under a
                // millimeter). Moving the outline on each one made it shimmer, so
                // it holds perfectly still until the drift is real: bigger than
                // that, and seen by two readings in a row that agree.
                let previous = self.lastReading
                self.lastReading = found
                guard jump > 1.2, let previous, Self.movement(previous, w, h) > 1.2,
                      Self.distance(previous, found, w, h) < 1.5 else { return }
                self.lastReading = nil
                print(String(format: "[DC] align: move %.1f px  shift %.1f,%.1f  scale %.3f  rot %.3f", jump, found.tx, found.ty, (found.a + found.d) / 2, (found.c - found.b) / 2))
                self.correction = previous.blended(toward: found, by: 0.5)
                self.repinToDrawing(from: base)
            }
        }
    }

    /// How far (alignment pixels) a map moves the page: the largest shift
    /// among points spread over it.
    nonisolated private static func movement(_ t: Affine2, _ w: Int, _ h: Int) -> Double {
        distance(.identity, t, w, h)
    }

    nonisolated private static func distance(_ p: Affine2, _ q: Affine2, _ w: Int, _ h: Int) -> Double {
        [(0.2, 0.2), (0.8, 0.2), (0.8, 0.8), (0.2, 0.8)].map { u, v in
            let x = u * Double(w), y = v * Double(h)
            let a = p.apply(x, y), b = q.apply(x, y)
            return hypot(a.0 - b.0, a.1 - b.1)
        }.max() ?? 0
    }

    /// Moves ARKit's page so the drawing sits exactly where it was measured,
    /// then starts the correction over from zero. Without this, ARKit's own
    /// error builds up as the phone moves and the correction has to chase it.
    /// `base`: the page corners the reading was measured against (the outline
    /// may have glided on since); the correction applies to those.
    private func repinToDrawing(from base: [SIMD3<Float>]?) {
        guard let map = referenceToCurrent, let base, base.count == 4 else { return }
        let paper = ar.paper
        let cornersNow = [PaperPoint(x: 0, y: 0), PaperPoint(x: paper.w, y: 0),
                          PaperPoint(x: paper.w, y: paper.h), PaperPoint(x: 0, y: paper.h)]
        let moved = cornersNow.map { ARController.world(map.apply($0), corners: base, paper: paper) }
        ar.repin(moved)
        ar.followDrawing = true
        lastLock = CACurrentMediaTime()
        correction = .identity
        pendingJump = nil
        lastReading = nil
    }

    /// One pair of alignment images per outline, saved for debugging
    /// (Documents/align-reference.pgm and align-current.pgm).
    private var dumpedAlignImages = true

    nonisolated private static func dumpGray(_ g: [Float], _ w: Int, _ h: Int, name: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let bytes = g.map { UInt8(max(0, min(255, $0))) }
        try? (Data("P5\n\(w) \(h)\n255\n".utf8) + Data(bytes)).write(to: dir.appendingPathComponent(name))
    }

    /// Paper-units map from the reference photo (where the AI drew) to where
    /// that spot is in the current view of the page.
    private var referenceToCurrent: Affine2? {
        guard aligner != nil, correction != .identity, let inv = correction.inverse else { return nil }
        let k = ar.paper.w / Double(Self.alignWidth) // paper units per alignment pixel
        // inv is in pixels: convert p (units) -> px, map, -> units.
        return Affine2(a: inv.a, b: inv.b, tx: inv.tx * k, c: inv.c, d: inv.d, ty: inv.ty * k)
    }

    nonisolated private static func warped(_ gray: [Float], width: Int, height: Int, map: Affine2?, unitsPerPixel k: Double) -> [Float] {
        guard let map else { return gray }
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

    // MARK: debugging from the Mac (devicectl copies files in and out of Documents)

    private var lastOverlay: TimeInterval = 0
    private var overlayBusy = false

    /// Documents/say.txt, pushed from the Mac, is treated as speech (then
    /// deleted), so the whole flow can be tested without anyone talking.
    /// While an outline is up, Documents/overlay.jpg shows the camera image
    /// with the outline drawn where the screen draws it (same projection).
    private func debugTick(_ now: TimeInterval) {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let say = dir.appendingPathComponent("say.txt")
            if let text = try? String(contentsOf: say, encoding: .utf8) {
                try? FileManager.default.removeItem(at: say)
                print("[DC] debug say: \(text)")
                heard(text)
            }
        }
        guard let outline, !outline.strokes.isEmpty, !overlayBusy, now - lastOverlay > 2,
              let frame = ar.session.currentFrame else { return }
        lastOverlay = now
        let map = referenceToCurrent
        let strokes: [[CGPoint]] = outline.strokes.map { s in
            s.points.compactMap { p in
                let q = map?.apply(p) ?? p
                return ar.world(q).flatMap { ARController.project($0, camera: frame.camera) }
            }
        }
        let style = outline.style
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        overlayBusy = true
        alignQueue.async { [weak self] in
            defer { DispatchQueue.main.async { self?.overlayBusy = false } }
            let size = image.extent.size
            guard let cg = CIContext().createCGImage(image, from: image.extent) else { return }
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.width / 2, height: size.height / 2))
            let jpeg = renderer.jpegData(withCompressionQuality: 0.75) { ctx in
                let g = ctx.cgContext
                g.translateBy(x: 0, y: size.height / 2)
                g.scaleBy(x: 0.5, y: -0.5)
                g.draw(cg, in: CGRect(origin: .zero, size: size))
                g.scaleBy(x: 1, y: -1)
                g.translateBy(x: 0, y: -size.height)
                g.setStrokeColor(UIColor.red.cgColor)
                g.setLineWidth(3)
                for pts in strokes where pts.count > 1 {
                    g.move(to: pts[0]); pts.dropFirst().forEach { g.addLine(to: $0) }
                }
                g.strokePath()
                let label = String(format: "ink rgb %.2f %.2f %.2f  width %.1f u", style.red, style.green, style.blue, style.width)
                (label as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 36), .foregroundColor: UIColor.yellow])
            }
            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? jpeg.write(to: dir.appendingPathComponent("overlay.jpg"))
            }
        }
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
