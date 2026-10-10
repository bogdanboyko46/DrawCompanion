import ARKit
import UIKit

extension ARFrame {
    /// Maps Vision-normalized image points (origin bottom-left) to view points.
    func viewPointMapper(orientation: UIInterfaceOrientation, viewport: CGSize) -> (CGPoint) -> CGPoint {
        let t = displayTransform(for: orientation, viewportSize: viewport)
        return { p in
            let n = CGPoint(x: p.x, y: 1 - p.y).applying(t)
            return CGPoint(x: n.x * viewport.width, y: n.y * viewport.height)
        }
    }
}
