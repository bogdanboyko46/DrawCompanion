import ARKit
import Vision

/// Owns the AR session and finds the paper. Vision spots the sheet in the
/// camera image a couple of times a second; each corner is raycast onto the
/// desk so the page gets a fixed place in the room. ARKit's world tracking
/// then keeps it there as your head moves, even when your hand hides the
/// page, and fresh detections follow the paper if it's moved or turned.
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

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
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
        let tl = pts.min { $0.x + $0.y < $1.x + $1.y }!
        let br = pts.max { $0.x + $0.y < $1.x + $1.y }!
        let tr = pts.max { $0.x - $0.y < $1.x - $1.y }!
        let bl = pts.min { $0.x - $0.y < $1.x - $1.y }!
        let ordered = [tl, tr, br, bl]
        return Set(ordered.map { "\($0.x),\($0.y)" }).count == 4 ? ordered : nil
    }

    private func place(_ imageCorners: [CGPoint], using frame: ARFrame) {
        let world = imageCorners.compactMap { point -> SIMD3<Float>? in
            let query = frame.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any)
            guard let hit = session.raycast(query).first else { return nil }
            let t = hit.worldTransform.columns.3
            return SIMD3(t.x, t.y, t.z)
        }
        guard world.count == 4 else { return }
        let width = (simd_distance(world[0], world[1]) + simd_distance(world[3], world[2])) / 2
        let height = (simd_distance(world[0], world[3]) + simd_distance(world[1], world[2])) / 2
        guard (0.05...1.2).contains(width), (0.05...1.2).contains(height) else { return }

        var next = world
        if let old = corners {
            // Keep corner identity (which edge is "top") when the paper moves or turns.
            let rotations = (0..<4).map { k in (0..<4).map { next[($0 + k) % 4] } }
            let cost = { (c: [SIMD3<Float>]) in zip(c, old).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) } }
            let best = rotations.min { cost($0) < cost($1) }!
            if cost(best) < 0.6 { next = best }
            // Small changes are detection jitter: ease toward them. Big ones are a moved page.
            next = zip(next, old).map { new, prev in simd_distance(new, prev) < 0.01 ? prev + (new - prev) * 0.25 : new }
        }
        corners = next
        lastSeen = frame.timestamp
        if !lockPaperSize {
            let w = (simd_distance(next[0], next[1]) + simd_distance(next[3], next[2])) / 2
            let h = (simd_distance(next[0], next[3]) + simd_distance(next[1], next[2])) / 2
            paper = PaperSize(aspect: Double(h / w))
        }
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
