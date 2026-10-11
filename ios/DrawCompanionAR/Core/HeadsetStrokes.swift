import Foundation

/// Stroke geometry and timing for the outline renderer, kept here (plain
/// Swift) so it can be unit-tested.
enum HeadsetStrokes {
    /// Walks a polyline and calls `body` with each straight piece to draw:
    /// the polyline cut into dashes (`dash` = on and off lengths, nil for a
    /// solid line), stopping after `reveal` (0…1) of its total length. The
    /// renderer draws each piece as a round-capped capsule.
    static func forEachPiece(_ points: [SIMD2<Float>], dash: (on: Float, off: Float)?, reveal: Float = 1,
                             _ body: (SIMD2<Float>, SIMD2<Float>) -> Void) {
        guard points.count >= 2, reveal > 0 else { return }
        var budget = Float.infinity
        if reveal < 1 {
            var total: Float = 0
            for k in 1..<points.count { total += length(points[k] - points[k - 1]) }
            budget = total * reveal
        }
        let dash = dash.flatMap { $0.on > 0 && $0.off > 0 ? $0 : nil }
        var on = true
        var left = dash?.on ?? .infinity // length left in the current dash or gap
        for k in 1..<points.count {
            guard budget > 0 else { return }
            let a = points[k - 1], b = points[k]
            let len = length(b - a)
            guard len > 1e-4 else { continue }
            let dir = (b - a) / len
            var t: Float = 0
            let end = min(len, budget)
            budget -= end
            while t < end {
                let step = min(left, end - t)
                if on, step > 1e-4 { body(a + dir * t, a + dir * (t + step)) }
                t += step
                left -= step
                if left <= 1e-5, let dash {
                    on.toggle()
                    left = on ? dash.on : dash.off
                }
            }
        }
    }

    static func length(_ v: SIMD2<Float>) -> Float { (v * v).sum().squareRoot() }

    /// How strongly a stroke shows, given how much of it you've traced:
    /// traced strokes step back so the untraced ones stand out, and a
    /// finished one leaves your own pencil line in charge.
    static func tracedLevel(progress: Double, done: Bool) -> Float {
        done ? 0.25 : 1 - 0.5 * Float(min(1, max(0, progress)))
    }

    /// Moves `current` toward `target` smoothly (exponential, `timeConstant`
    /// seconds), so values that arrive in steps (the tracker updates a few
    /// times a second) don't make the lines blink.
    static func approach(_ current: Float, _ target: Float, dt: Double, timeConstant: Double = 0.25) -> Float {
        guard dt > 0 else { return current }
        let k = Float(1 - exp(-dt / timeConstant))
        let next = current + (target - current) * k
        return abs(next - target) < 0.002 ? target : next
    }

    /// When each stroke of the outline arrived, for the draw-on animation.
    /// A stroke counts as new when its path data differs from what was at
    /// its index before, so strokes moved by drift correction don't replay.
    struct Arrivals {
        /// How long a new stroke takes to draw itself on, in seconds.
        static let duration: Double = 0.45

        private var paths: [String] = []
        private var times: [Double] = []

        init() {}

        mutating func update(_ strokes: [Stroke], now: Double) {
            if paths.count > strokes.count {
                paths.removeLast(paths.count - strokes.count)
                times.removeLast(times.count - strokes.count)
            }
            for (i, stroke) in strokes.enumerated() {
                if i < paths.count {
                    if paths[i] != stroke.d { paths[i] = stroke.d; times[i] = now }
                } else {
                    paths.append(stroke.d)
                    times.append(now)
                }
            }
        }

        /// 0 just arrived … 1 fully drawn.
        func progress(_ i: Int, now: Double) -> Double {
            guard i < times.count else { return 1 }
            return min(1, max(0, (now - times[i]) / Self.duration))
        }

        /// How much of the stroke's length to show (eased: fast, then settling).
        static func reveal(_ progress: Double) -> Float {
            let p = 1 - progress
            return Float(1 - p * p * p)
        }

        /// Opacity multiplier: a quick fade-in at the start of the draw-on.
        static func opacity(_ progress: Double) -> Float {
            Float(min(1, 0.35 + progress * 1.6))
        }
    }
}
