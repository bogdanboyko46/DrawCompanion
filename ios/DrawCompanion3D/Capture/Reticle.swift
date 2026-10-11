import CoreGraphics

/// The capture frame in the middle of the screen. Whatever is inside it, and
/// only that, is scanned, so it works on paper, a whiteboard, anything.
/// The SwiftUI overlay and the capture code both use this, so what you see
/// framed is exactly what's captured.
enum Reticle {
    /// Portrait 3:4, since standing figures are taller than wide (and their feet
    /// shouldn't end up at the very edge).
    static func rect(in size: CGSize) -> CGRect {
        if size.width > size.height {
            // Landscape: on the left, clear of the panels on the right.
            let height = size.height * 0.72
            let width = height * 3 / 4
            return CGRect(x: size.width * 0.36 - width / 2, y: size.height * 0.53 - height / 2, width: width, height: height)
        }
        let height = min(size.width * 0.82 * 4 / 3, size.height * 0.56)
        let width = height * 3 / 4
        // Slightly above center, clear of the controls at the bottom.
        return CGRect(x: (size.width - width) / 2, y: size.height * 0.42 - height / 2, width: width, height: height)
    }

    /// Corners as seen on screen: top-left, top-right, bottom-right, bottom-left.
    static func corners(in size: CGSize) -> [CGPoint] {
        let r = rect(in: size)
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
}
