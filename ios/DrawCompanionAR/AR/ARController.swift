import ARKit
import Vision

/// Owns the AR session and finds the paper. Vision spots the sheet in the
/// camera image a couple of times a second; its corners are raycast onto the
/// desk and fitted as one rigid rectangle, which gets a fixed place in the
/// room. ARKit's world tracking keeps it there as your head moves, even when
/// your hand hides the page.
///
/// Vision's corners wobble by a centimeter or more from one detection to the
/// next, so detections don't steer the page directly: small differences are
/// treated as noise, and the page only moves when several detections in a
/// row agree it really moved (the paper was slid or turned).
final class ARController: NSObject, ARSessionDelegate {
    let session = ARSession()

    /// World-space page corners: top-left, top-right, bottom-right, bottom-left
    /// (top = the edge farther from you when first seen).
    private(set) var corners: [SIMD3<Float>]?
    private(set) var paper = PaperSize(aspect: 1.294)
    /// Keep paper units fixed while an outline is shown so it doesn't shift.
    var lockPaperSize = false
    private(set) var lastSeen: TimeInterval = 0
    private(set) var trackingNormal = false

    private let visionQueue = DispatchQueue(label: "drawcompanion.page-detect", qos: .userInitiated)
    private var detecting = false
    private var lastDetectStart: TimeInterval = 0
    private let detectInterval: TimeInterval = 0.4

    /// A detection that disagrees with the pinned page, waiting for agreement.
    private var candidate: [SIMD3<Float>]?
    private var candidateVotes = 0
    private static let noise: Float = 0.015 // m: closer than this to the pinned page is detection jitter
    private static let agree: Float = 0.012 // m: candidates this close count as the same new placement
    private static let votesToMove = 3 // ≈1.2 s of agreeing detections
    private static let votesToStart = 2

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        // LiDAR phones map the desk surface quickly; raycasts then hit real geometry.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        // The sharpest 4:3 format: the page photo sent to the AI comes from this image.
        if let format = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({ abs($0.imageResolution.width / $0.imageResolution.height - 4.0 / 3.0) < 0.01 })
            .max(by: { $0.imageResolution.width < $1.imageResolution.width }) {
            config.videoFormat = format
        }
        session.delegate = self
        session.run(config)
    }

    func pause() { session.pause() }

    // MARK: ARSessionDelegate (main queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if case .normal = frame.camera.trackingState { trackingNormal = true } else { trackingNormal = false }
        guard !detecting, frame.timestamp - lastDetectStart >= detectInterval else { return }
        detecting = true
        lastDetectStart = frame.timestamp
        let pixelBuffer = frame.capturedImage
        visionQueue.async { [weak self] in
            let found = Self.detectPage(in: pixelBuffer)
            DispatchQueue.main.async {
                guard let self else { return }
                self.detecting = false
                if let found { self.place(found, using: frame) }
            }
        }
    }

    // MARK: finding the page

    /// Page corners in normalized image coordinates (origin top-left),
    /// ordered top-left, top-right, bottom-right, bottom-left.
    static func detectPage(in pixelBuffer: CVPixelBuffer) -> [CGPoint]? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first, obs.confidence > 0.6 else { return nil }
        // Vision's origin is bottom-left; flip to top-left.
        let pts = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft].map { CGPoint(x: $0.x, y: 1 - $0.y) }
        // A corner on the image border means the page is cut off: its "corner" is
        // really the edge of the view, and the page would come out the wrong shape.
        let margin = 0.015
        guard pts.allSatisfy({ $0.x > margin && $0.x < 1 - margin && $0.y > margin && $0.y < 1 - margin }) else { return nil }
        let tl = pts.min { $0.x + $0.y < $1.x + $1.y }!
        let br = pts.max { $0.x + $0.y < $1.x + $1.y }!
        let tr = pts.max { $0.x - $0.y < $1.x - $1.y }!
        let bl = pts.min { $0.x - $0.y < $1.x - $1.y }!
        let ordered = [tl, tr, br, bl]
        return Set(ordered.map { "\($0.x),\($0.y)" }).count == 4 ? ordered : nil
    }

    private func place(_ imageCorners: [CGPoint], using frame: ARFrame) {
        let hits = imageCorners.compactMap { raycast($0, frame) }
        guard hits.count == 4, var next = Self.fitRectangle(hits) else { return }
        if let old = corners {
            // Keep corner identity (which edge is "top") when the paper moves or turns.
            next = (0..<4).map { k in (0..<4).map { next[($0 + k) % 4] } }.min { Self.spread($0, old) < Self.spread($1, old) }!
        }
        lastSeen = frame.timestamp

        guard let current = corners else {
            // First sighting: wait for a second detection to agree before showing anything.
            if let agreed = vote(next, needed: Self.votesToStart) { pin(agreed) }
            return
        }
        if Self.spread(next, current) < Self.noise {
            candidate = nil
            candidateVotes = 0
            // While an outline is shown, hold perfectly still. Otherwise refine slowly.
            if !lockPaperSize { pin(zip(current, next).map { $0 + ($1 - $0) * 0.15 }) }
            return
        }
        if let agreed = vote(next, needed: Self.votesToMove) { pin(agreed) } // the paper really moved
    }

    /// Counts agreeing detections; returns their average once there are enough.
    private func vote(_ next: [SIMD3<Float>], needed: Int) -> [SIMD3<Float>]? {
        if let c = candidate, Self.spread(next, c) < Self.agree {
            candidate = zip(c, next).map { $0 + ($1 - $0) * 0.5 }
            candidateVotes += 1
        } else {
            candidate = next
            candidateVotes = 1
        }
        return candidateVotes >= needed ? candidate : nil
    }

    private func pin(_ next: [SIMD3<Float>]) {
        corners = next
        candidate = nil
        candidateVotes = 0
        if !lockPaperSize {
            let w = simd_distance(next[0], next[1])
            let h = simd_distance(next[0], next[3])
            paper = PaperSize(aspect: Double(h / w))
        }
    }

    /// Prefer the desk surface ARKit has already mapped; fall back to an estimate.
    private func raycast(_ point: CGPoint, _ frame: ARFrame) -> SIMD3<Float>? {
        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            let query = frame.raycastQuery(from: point, allowing: target, alignment: .any)
            if let hit = session.raycast(query).first {
                let t = hit.worldTransform.columns.3
                return SIMD3(t.x, t.y, t.z)
            }
        }
        return nil
    }

    /// Largest distance between matching corners.
    static func spread(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        zip(a, b).map { simd_distance($0, $1) }.max() ?? .infinity
    }

    /// Standard sheets (width × height, meters), either orientation.
    private static let sheets: [SIMD2<Float>] = [
        SIMD2(0.2159, 0.2794), SIMD2(0.2794, 0.2159), // US Letter
        SIMD2(0.210, 0.297), SIMD2(0.297, 0.210), // A4
        SIMD2(0.148, 0.210), SIMD2(0.210, 0.148), // A5
    ]

    /// Fits a flat, square-cornered rectangle to four noisy corner hits
    /// (TL, TR, BR, BL), snapping to a standard sheet size when it's close.
    static func fitRectangle(_ p: [SIMD3<Float>]) -> [SIMD3<Float>]? {
        let center = (p[0] + p[1] + p[2] + p[3]) / 4
        let across = (p[1] - p[0]) + (p[2] - p[3])
        let down = (p[3] - p[0]) + (p[2] - p[1])
        guard simd_length(across) > 0.01, simd_length(down) > 0.01 else { return nil }
        let ex = simd_normalize(across)
        let normal = simd_normalize(simd_cross(ex, down))
        var ey = simd_normalize(simd_cross(normal, ex))
        if simd_dot(ey, down) < 0 { ey = -ey }
        var size = SIMD2(simd_length(across) / 2, simd_length(down) / 2)
        guard (0.05...1.2).contains(size.x), (0.05...1.2).contains(size.y) else { return nil }
        if let sheet = sheets.first(where: { abs($0.x / size.x - 1) < 0.15 && abs($0.y / size.y - 1) < 0.15 }) {
            size = sheet
        }
        let hx = ex * size.x / 2, hy = ey * size.y / 2
        return [center - hx - hy, center + hx - hy, center + hx + hy, center - hx + hy]
    }

    // MARK: paper <-> camera

    /// World position of a point on the page (bilinear across the four corners).
    func world(_ p: PaperPoint) -> SIMD3<Float>? {
        guard let c = corners else { return nil }
        let u = Float(p.x / paper.w), v = Float(p.y / paper.h)
        let top = c[0] + (c[1] - c[0]) * u
        let bottom = c[3] + (c[2] - c[3]) * u
        return top + (bottom - top) * v
    }

    /// Where a page point appears in the camera image, in image pixels
    /// (landscape, origin top-left). Nil if it's behind the camera.
    static func project(_ world: SIMD3<Float>, camera: ARCamera) -> CGPoint? {
        let local = camera.transform.inverse * SIMD4(world, 1)
        guard local.z < -0.01 else { return nil }
        return camera.projectPoint(world, orientation: .landscapeRight, viewportSize: camera.imageResolution)
    }

    func imageCorners(in frame: ARFrame) -> [CGPoint]? {
        guard let c = corners else { return nil }
        let pts = c.compactMap { Self.project($0, camera: frame.camera) }
        return pts.count == 4 ? pts : nil
    }
}
