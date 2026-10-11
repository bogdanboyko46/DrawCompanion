import CoreGraphics

/// The capture frame in the middle of the screen. Whatever is inside it, and
/// only that, is scanned, so it works on paper, a whiteboard, anything.
/// The SwiftUI overlay and the capture code both use this, so what you see
/// framed is exactly what's captured.
enum Reticle {
    static func rect(in size: CGSize) -> CGRect {
        let side = min(size.width * 0.82, size.height * 0.48)
        // Slightly above center, clear of the controls at the bottom.
        return CGRect(x: (size.width - side) / 2, y: size.height * 0.42 - side / 2, width: side, height: side)
    }

    /// Corners as seen on screen: top-left, top-right, bottom-right, bottom-left.
    static func corners(in size: CGSize) -> [CGPoint] {
        let r = rect(in: size)
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
}
