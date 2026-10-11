import ARKit
import Combine
import RealityKit
import UIKit

/// Owns the ARView: tracking, page detection, the portal while a character is
/// being made, and every character living in the room.
@MainActor
final class SceneController: NSObject, ARSessionDelegate {
    let arView: ARView
    private(set) var actors: [CharacterActor] = []
    private var portal: PaperPortal?
    private var updates: Cancellable?
    private let detectQueue = DispatchQueue(label: "page-detect", qos: .userInitiated)
    private var lastOverlay: TimeInterval = 0

    /// Called ~30×/s with where each speaking character's head is on screen.
    var onHeadPositions: (([String: CGPoint]) -> Void)?
    var onSpeak: ((CharacterActor, String) -> Void)?

    override init() {
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        super.init()
        configure()
    }

    private func configure() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth) // your hand passes in front of it
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh // LiDAR: real objects occlude it
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        arView.renderOptions.insert(.disableMotionBlur)
        arView.session.delegate = self
        arView.session.run(config)

        let coaching = ARCoachingOverlayView()
        coaching.session = arView.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(coaching)

        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))

        updates = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.tick(event.deltaTime) }
        }
    }

    private var interfaceOrientation: UIInterfaceOrientation {
        arView.window?.windowScene?.interfaceOrientation ?? .portrait
    }

    // MARK: Capture

    enum CaptureError: LocalizedError {
        case noFrame
        var errorDescription: String? { "The camera isn't ready yet. Try again in a moment." }
    }

    /// Takes a sharp still of what's inside the on-screen frame, straightens it
    /// to a square as seen on screen, finds the drawn figure in it, and measures
    /// where that frame sits on the surface in the room.
    func capturePage() async throws -> CapturedPage {
        let started = Date()
        func log(_ s: String) { print("[capture] \(String(format: "%.2f", Date().timeIntervalSince(started)))s \(s)") }
        log("start")
        let frame = try await highResolutionFrame()
        log("frame \(CVPixelBufferGetWidth(frame.capturedImage))x\(CVPixelBufferGetHeight(frame.capturedImage))")
        let viewport = arView.bounds.size
        let t = frame.displayTransform(for: interfaceOrientation, viewportSize: viewport).inverted()
        // View point -> camera image point in Vision's normalized space (origin bottom-left).
        let toImage: (CGPoint) -> CGPoint = { v in
            let n = CGPoint(x: v.x / viewport.width, y: v.y / viewport.height).applying(t)
            return CGPoint(x: n.x, y: 1 - n.y)
        }
        let viewCorners = Reticle.corners(in: viewport)
        let region = DetectedPage(imageCorners: viewCorners.map(toImage), confidence: 1)
        let buffer = frame.capturedImage

        // Where is the frame on the table?
        var world = viewCorners.compactMap { raycast($0) }
        let measured = world.count == 4
        if !measured {
            // No surface found yet: a 20 cm square in front of the camera.
            let center = raycast(CGPoint(x: Reticle.rect(in: viewport).midX, y: Reticle.rect(in: viewport).midY))
                ?? (arView.cameraTransform.translation + arView.cameraTransform.rotation.act([0, -0.25, -0.45]))
            let forward = arView.cameraTransform.rotation.act([0, 0, -1])
            let z = simd_normalize(SIMD3<Float>(-forward.x, 0, -forward.z) + [0, 0, 0.0001])
            let x = simd_normalize(simd_cross([0, 1, 0], z))
            let h: Float = 0.1
            world = [center - x * h - z * h, center + x * h - z * h, center + x * h + z * h, center - x * h + z * h]
        }
        let (transform, size) = PageScanner.frame(from: world)
        log("raycast measured=\(measured)")

        let result: (Data, CGImage)? = await withCheckedContinuation { c in
            detectQueue.async { c.resume(returning: PageScanner.rectify(buffer, page: region, aspect: 1)) }
        }
        guard let result else { throw CaptureError.noFrame }
        let (jpeg, image) = result
        log("rectified \(image.width)x\(image.height)")
        let isolated = await withCheckedContinuation { (c: CheckedContinuation<PageScanner.Isolated?, Never>) in
            detectQueue.async { c.resume(returning: PageScanner.isolate(image)) }
        }
        log("isolated: \(isolated.map { "figure \($0.figure.width)x\($0.figure.height) box \($0.box)" } ?? "none")")
        return CapturedPage(jpeg: jpeg, image: image, cutout: isolated?.cutout, figureJPEG: isolated?.figureJPEG, worldCorners: world,
                            transform: transform, size: size, measured: measured)
    }

    private func highResolutionFrame() async throws -> ARFrame {
        let session = arView.session
        let fallback = session.currentFrame
        return try await withCheckedThrowingContinuation { c in
            session.captureHighResolutionFrame { frame, _ in
                if let frame = frame ?? fallback { c.resume(returning: frame) } else { c.resume(throwing: CaptureError.noFrame) }
            }
        }
    }

    private func raycast(_ point: CGPoint) -> SIMD3<Float>? {
        let hits = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal)
        guard let hit = hits.first else { return nil }
        let c = hit.worldTransform.columns.3
        return [c.x, c.y, c.z]
    }

    // MARK: Portal

    func beginPortal(for page: CapturedPage) {
        portal?.remove()
        let p = PaperPortal(page: page)
        arView.scene.addAnchor(p.anchor)
        p.startScan()
        portal = p
    }

    func liftPortal() { portal?.lift() }

    func showConcept(_ cutout: CGImage) { portal?.showConcept(cutout) }

    func startTurntable(_ frames: [CGImage]) { portal?.startTurntable(frames) }

    func cancelPortal() {
        portal?.remove()
        portal = nil
    }

    // MARK: Characters

    /// Bursts the portal and brings the character to life where the drawing was.
    func materialize(job: CharacterJob, modelURL: URL, page: CapturedPage?, usePortal: Bool = true) async throws -> CharacterActor {
        let transform = page?.transform ?? placementInFront()
        let paperLong = page.map { max($0.size.x, $0.size.y) } ?? 0.28
        let height = min(0.5, max(0.15, paperLong * 0.85))
        let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let character = try await CharacterActor.load(job: job, modelURL: modelURL, transform: transform, height: height)
        character.onSpeak = { [weak self] a, line in self?.onSpeak?(a, line) }
        character.isWalkable = { [weak self] point in self?.isOnSurface(point, origin: origin) ?? true }
        character.root.isEnabled = false
        arView.scene.addAnchor(character.anchor)
        _ = arView.installGestures([.scale], for: character.root)
        actors.append(character)

        if usePortal, let portal {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                portal.dissolve {
                    character.root.isEnabled = true
                    character.appear()
                    c.resume()
                }
            }
            self.portal = nil
        } else {
            character.root.isEnabled = true
            character.appear()
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        return character
    }

    /// Places a saved character on the surface in the middle of the screen.
    func place(job: CharacterJob, modelURL: URL) async throws -> CharacterActor {
        try await materialize(job: job, modelURL: modelURL, page: nil, usePortal: false)
    }

    func removeAll() {
        for a in actors { a.anchor.removeFromParent() }
        actors.removeAll()
    }

    private func placementInFront() -> simd_float4x4 {
        let point = raycast(CGPoint(x: arView.bounds.midX, y: arView.bounds.midY * 1.2))
            ?? (arView.cameraTransform.translation + arView.cameraTransform.rotation.act([0, -0.3, -0.6]))
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(point, 1)
        return m
    }

    /// True if there's real surface under `point` at about the same height.
    private func isOnSurface(_ point: SIMD3<Float>, origin: SIMD3<Float>) -> Bool {
        let level = origin.y
        let query = ARRaycastQuery(origin: point + [0, 0.15, 0], direction: [0, -1, 0],
                                   allowing: .existingPlaneGeometry, alignment: .horizontal)
        guard let hit = arView.session.raycast(query).first else {
            // No plane geometry here (yet): only allow short trips from where it was born.
            return simd_distance(SIMD2(point.x, point.z), SIMD2(origin.x, origin.z)) < 0.25
        }
        return abs(hit.worldTransform.columns.3.y - level) < 0.04
    }

    // MARK: Input

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: arView)
        if let hit = arView.entity(at: point), let character = actors.first(where: { owns($0, hit) }) {
            character.react()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        // Tap the surface: the most recent character comes over.
        guard let character = actors.last, let world = raycast(point) else { return }
        character.walk(toWorld: world)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func owns(_ character: CharacterActor, _ entity: Entity) -> Bool {
        var e: Entity? = entity
        while let current = e {
            if current === character.root { return true }
            e = current.parent
        }
        return false
    }

    // MARK: Frame loop

    private func tick(_ dt: TimeInterval) {
        let camera = arView.cameraTransform.translation
        portal?.update(deltaTime: dt, cameraPosition: camera)
        for character in actors { character.update(deltaTime: dt, cameraPosition: camera) }

        lastOverlay += dt
        if lastOverlay > 1.0 / 30, let onHeadPositions {
            lastOverlay = 0
            var heads: [String: CGPoint] = [:]
            for character in actors {
                if let p = arView.project(character.headWorldPosition) { heads[character.job.id] = p }
            }
            onHeadPositions(heads)
        }
    }

    // MARK: Sharing

    func snapshot() async -> UIImage? {
        await withCheckedContinuation { c in
            arView.snapshot(saveToHDR: false) { c.resume(returning: $0) }
        }
    }
}
