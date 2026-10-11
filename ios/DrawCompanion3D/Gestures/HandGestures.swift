import ARKit
import Vision

/// Recognizes a few hand poses in the camera view (Vision hand-pose), so the
/// app can be driven by gestures in AR instead of buttons:
/// open palm, pointing, thumbs up, peace sign.
@MainActor
final class HandGestures {
    enum Pose: String { case palm, point, thumbsUp, peace }

    /// A pose held long enough to count started, or ended.
    var onBegan: ((Pose) -> Void)?
    var onEnded: ((Pose) -> Void)?
    /// While pointing: where the fingertip is on screen.
    var onPointing: ((CGPoint) -> Void)?

    private let queue = DispatchQueue(label: "hand-gestures", qos: .userInitiated)
    private var busy = false
    private var lastRun: TimeInterval = 0
    private var candidate: Pose?
    private var candidateCount = 0
    private var missingCount = 0
    private(set) var current: Pose?

    /// Feed camera frames; analyzes about 10 per second, off the main thread.
    func process(_ frame: ARFrame, toView: @escaping (CGPoint) -> CGPoint) {
        guard !busy, frame.timestamp - lastRun > 0.1 else { return }
        busy = true
        lastRun = frame.timestamp
        let buffer = frame.capturedImage
        queue.async { [weak self] in
            let result = HandGestures.classify(buffer, toView: toView)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.update(result)
            }
        }
    }

    private func update(_ result: (pose: Pose, tip: CGPoint)?) {
        let pose = result?.pose
        if pose == candidate { candidateCount += 1 } else { candidate = pose; candidateCount = 1 }

        if let pose, candidateCount >= 3, pose != current {
            // Held for ~0.3 s: it's deliberate.
            if let old = current { onEnded?(old) }
            current = pose
            missingCount = 0
            onBegan?(pose)
        } else if current != nil, pose != current {
            // Tolerate a frame or two of tracking loss before ending.
            missingCount += 1
            if missingCount >= 4, let old = current {
                current = nil
                onEnded?(old)
            }
        } else if pose == current {
            missingCount = 0
        }
        if current == .point, pose == .point, let tip = result?.tip { onPointing?(tip) }
    }

    private nonisolated static func classify(_ buffer: CVPixelBuffer, toView: (CGPoint) -> CGPoint) -> (pose: Pose, tip: CGPoint)? {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let hand = request.results?.first,
              let points = try? hand.recognizedPoints(.all)
        else { return nil }

        // Work in screen coordinates so "up" means up on screen.
        func p(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let pt = points[joint], pt.confidence > 0.3 else { return nil }
            return toView(pt.location)
        }
        func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        guard let wrist = p(.wrist), let indexMCP = p(.indexMCP), let littleMCP = p(.littleMCP) else { return nil }
        let palmSize = max(d(wrist, indexMCP), d(indexMCP, littleMCP), 1)

        // A finger is out when its tip is well beyond its middle joint from the wrist.
        func extended(_ tip: VNHumanHandPoseObservation.JointName, _ pip: VNHumanHandPoseObservation.JointName) -> Bool? {
            guard let t = p(tip), let m = p(pip) else { return nil }
            return d(wrist, t) > d(wrist, m) * 1.2
        }
        guard let index = extended(.indexTip, .indexPIP),
              let middle = extended(.middleTip, .middlePIP),
              let ring = extended(.ringTip, .ringPIP),
              let little = extended(.littleTip, .littlePIP)
        else { return nil }
        var thumbOut = false
        if let thumbTip = p(.thumbTip), let thumbIP = p(.thumbIP) {
            thumbOut = d(thumbTip, indexMCP) > d(thumbIP, indexMCP) * 1.15 && d(thumbTip, indexMCP) > palmSize * 0.6
        }
        let indexTip = p(.indexTip) ?? indexMCP

        switch (index, middle, ring, little) {
        case (true, true, true, true):
            return (.palm, indexTip)
        case (true, false, false, false):
            return (.point, indexTip)
        case (true, true, false, false):
            return (.peace, indexTip)
        case (false, false, false, false):
            // Thumbs up: thumb out and above the hand on screen.
            if thumbOut, let thumbTip = p(.thumbTip), thumbTip.y < wrist.y - palmSize * 0.6 {
                return (.thumbsUp, thumbTip)
            }
            return nil
        default:
            return nil
        }
    }
}
