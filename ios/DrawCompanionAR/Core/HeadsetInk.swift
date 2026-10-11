import Foundation

/// Makes the outline look printed on the paper rather than pasted on top of
/// the video: ink darkens what's under it (multiply), so paper texture,
/// lighting gradients and the shadow of your hand show through the lines
/// just as they do through real pencil lines.
///
/// The ink color (InkStyle) is what the camera saw on the paper; dividing by
/// the paper color around the outline gives the ink's transmittance, so on
/// average-lit paper the line comes out exactly the drawing's own color.
enum HeadsetInk {
    /// UserDefaults key (Bool, default true): printed-ink look on/off.
    static let printedKey = "outline.printedInk"

    /// One camera pixel (full-range YCbCr, as ARKit delivers it) as RGB 0…1,
    /// with the same matrix the camera shader uses.
    static func rgb(y: UInt8, cb: UInt8, cr: UInt8) -> SIMD3<Float> {
        let Y = Float(y) / 255, Cb = Float(cb) / 255 - 0.5, Cr = Float(cr) / 255 - 0.5
        let c = SIMD3(Y + 1.402 * Cr, Y - 0.3441 * Cb - 0.7141 * Cr, Y + 1.772 * Cb)
        return c.clamped(lowerBound: .zero, upperBound: .one)
    }

    static func luminance(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

    /// The paper's color from samples taken just beside the outline: the
    /// average of the brighter ones (the others may be pencil lines, the hand
    /// or a shadow). Nil with too few samples.
    static func paper(from samples: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard samples.count >= 8 else { return nil }
        var mean: Float = 0
        for s in samples { mean += luminance(s) }
        mean /= Float(samples.count)
        var sum = SIMD3<Float>.zero, n: Float = 0
        for s in samples where luminance(s) >= mean {
            sum += s
            n += 1
        }
        return n > 0 ? sum / n : nil
    }

    /// Per-channel fraction of light the ink lets through, or nil when the ink
    /// isn't clearly darker than the paper (light ink on dark paper), where
    /// ordinary blending works better.
    static func transmittance(ink: SIMD3<Float>, paper: SIMD3<Float>) -> SIMD3<Float>? {
        guard luminance(paper) > 0.05, luminance(ink) < 0.8 * luminance(paper) else { return nil }
        let t = ink / paper.replacing(with: SIMD3(repeating: 0.02), where: paper .< 0.02)
        return t.clamped(lowerBound: SIMD3(repeating: 0.02), upperBound: .one)
    }
}
