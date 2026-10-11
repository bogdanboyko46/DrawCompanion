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
    var onHeadPositions: (([String: BubbleSpot]) -> Void)?
    var onSpeak: ((CharacterActor, String) -> Void)?
    /// Characters who meet talk to each other (Character/Encounters.swift).
    let encounters = Encounters()

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
        // No LiDAR scene-mesh occlusion: the reconstructed table surface sits a
        // little above the real one and cut off characters' feet. (It also costs
        // CPU we'd rather spend on rendering.) Hands still occlude via people
        // segmentation above.
        arView.renderOptions.insert(.disableMotionBlur)
        arView.session.delegate = self
        arView.session.run(config)

        let coaching = ARCoachingOverlayView()
        coaching.session = arView.session
        coaching.goal = .tracking
        coaching.activatesAutomatically = true
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(coaching)

        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))

        updates = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.tick(event.deltaTime) }
        }
    }

    /// Every camera frame (for hand gestures). Don't hold on to the frame.
    var onFrame: ((ARFrame) -> Void)?

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { self.onFrame?(frame) }
    }

    /// Maps Vision-normalized points in this frame to points on screen.
    func viewMapper(for frame: ARFrame) -> (CGPoint) -> CGPoint {
        frame.viewPointMapper(orientation: interfaceOrientation, viewport: arView.bounds.size)
    }

    /// The surface point under a screen point, if any.
    func surfacePoint(at point: CGPoint) -> SIMD3<Float>? { raycast(point) }

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
        let frameAspect = Reticle.rect(in: viewport).width / Reticle.rect(in: viewport).height
        let region = DetectedPage(imageCorners: viewCorners.map(toImage), confidence: 1)
        let buffer = frame.capturedImage

        // Where is the frame on the table?
        var world = viewCorners.compactMap { raycast($0) }
        if world.count < 4 {
            // Only part of the frame hit a known surface: if the table is found
            // anywhere in the frame, extend it as a flat plane and intersect each
            // corner's camera ray with it.
            let r = Reticle.rect(in: viewport)
            let probes = [CGPoint(x: r.midX, y: r.midY)] + world.indices.map { viewCorners[$0] } + viewCorners
            if let level = probes.lazy.compactMap({ self.raycast($0) }).first?.y {
                world = viewCorners.compactMap { point in
                    guard let ray = arView.ray(through: point), ray.direction.y < -0.05 else { return nil }
                    let t = (level - ray.origin.y) / ray.direction.y
                    return t > 0 ? ray.origin + ray.direction * t : nil
                }
            }
        }
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
            detectQueue.async { c.resume(returning: PageScanner.rectify(buffer, page: region, aspect: frameAspect)) }
        }
        guard let result else { throw CaptureError.noFrame }
        let (jpeg, image) = result
        log("rectified \(image.width)x\(image.height)")
        let isolated = await withCheckedContinuation { (c: CheckedContinuation<PageScanner.Isolated?, Never>) in
            detectQueue.async { c.resume(returning: PageScanner.isolate(image)) }
        }
        log("isolated: \(isolated.map { "figure \($0.figure.width)x\($0.figure.height) box \($0.box)" } ?? "none")")
        return CapturedPage(jpeg: jpeg, image: image, cutout: isolated?.cutout, figureJPEG: isolated?.figureJPEG, worldCorners: world,
                            transform: transform, size: size, measured: measured, figureBox: isolated?.box)
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
        let character = try await prepare(job: job, modelURL: modelURL, page: page)
        await reveal(character, usePortal: usePortal)
        return character
    }

    /// Loads the character into the room, hidden, so revealing it is instant.
    func prepare(job: CharacterJob, modelURL: URL, page: CapturedPage?) async throws -> CharacterActor {
        // To scale and in place: as tall as the figure is drawn, standing on its
        // drawn feet. Without a measurement, a 25 cm character in front of you.
        let transform = page?.feetTransform ?? page?.transform ?? placementInFront()
        let height = min(0.6, max(0.04, page?.figureHeight ?? 0.25))
        print("[place] height \(String(format: "%.3f", height)) m, measured \(page?.measured ?? false)")
        let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let character = try await CharacterActor.load(job: job, modelURL: modelURL, transform: transform, height: height)
        character.onSpeak = { [weak self] a, line in self?.onSpeak?(a, line) }
        character.isWalkable = { [weak self] point in self?.isOnSurface(point, origin: origin) ?? true }
        character.root.isEnabled = false
        arView.scene.addAnchor(character.anchor)
        _ = arView.installGestures([.scale], for: character.root)
        actors.append(character)
        return character
    }

    /// Bursts the portal (if there is one) and pops the character out.
    func reveal(_ character: CharacterActor, usePortal: Bool) async {
        if usePortal, let portal {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                portal.dissolve {
                    character.root.isEnabled = true
                    character.emergeFromPaper()
                    c.resume()
                }
            }
            self.portal = nil
        } else {
            character.root.isEnabled = true
            character.appear()
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Places a saved character on the surface in the middle of the screen.
    func place(job: CharacterJob, modelURL: URL) async throws -> CharacterActor {
        try await materialize(job: job, modelURL: modelURL, page: nil, usePortal: false)
    }

    func removeAll() {
        encounters.cancel()
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
            // With someone nearby, a tap can start a conversation instead.
            if !encounters.tapped(character, among: actors) { character.react() }
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
        encounters.update(deltaTime: dt, actors: actors, cameraRight: arView.cameraTransform.rotation.act([1, 0, 0]))

        lastOverlay += dt
        if lastOverlay > 1.0 / 30, let onHeadPositions {
            lastOverlay = 0
            let right = arView.cameraTransform.rotation.act([1, 0, 0])
            let faces = actors.map { character in
                let sides = character.faceSidePoints(cameraRight: right)
                return (id: character.job.id, left: arView.project(sides.left), right: arView.project(sides.right))
            }
            // Beside the face, on the side away from any neighbor (Encounters.swift).
            onHeadPositions(BubbleLayout.spots(faces, screenWidth: arView.bounds.width))
        }
    }

    // MARK: Sharing

    func snapshot() async -> UIImage? {
        await withCheckedContinuation { c in
            arView.snapshot(saveToHDR: false) { c.resume(returning: $0) }
        }
    }
}
