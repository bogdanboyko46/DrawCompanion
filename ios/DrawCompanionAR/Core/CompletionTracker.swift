import Foundation

/// Decides when the outline should go away: once the user has started
/// tracing it and then hasn't drawn on it for 3 seconds. Works on top-down
/// grayscale views of the page (0–255):
///
///   baseline = the page when the suggestion was requested
///   current  = the page now
///
/// New ink shows up as pixels that got darker. Each stroke is sampled into
/// points; a point counts as traced once new ink appears near it in several
/// consecutive frames. Things that look like ink but aren't:
///   - a hand or pencil over the page: a *solid* region of change, where ink
///     is thin lines (even when many lines are packed close together). It
///     isn't counted as ink, but it keeps the outline up, since a hand on the
///     outline means the user is probably still drawing.
///   - lighting shifts: overall brightness is matched to the baseline
///   - small tracking misalignment: a pixel only counts if it's darker than
///     everything near it in the baseline
final class CompletionTracker {
    struct Options {
        var idleSeconds = 3.0 // clear the outline after this long without drawing on it
        var darkerBy: Float = 28 // gray levels a pixel must darken to count as ink
        var alignPx = 2 // tolerated misalignment between baseline and current, in grid pixels
        var hitRadius = 0.018 // tolerance around the outline, fraction of page width
        var solidPx = 2 // change filling a whole (2n+1)^2 square is solid (a hand), not a line
        var frameOccludedFraction: Float = 0.15 // more of the page changed than this = hand over the page
        var confirmFrames = 3 // consecutive frames a point must look inked
        var strokeDoneAt = 0.8 // fraction of a stroke traced to show it as done
        var sampleSpacing = 0.012 // distance between samples along a stroke, fraction of page width
    }

    struct StrokeState: Equatable {
        var progress: Double
        var done: Bool
    }

    struct State: Equatable {
        var occluded: Bool
        var started: Bool
        var done: Bool
        var idleSeconds: Double
        var strokes: [StrokeState]
    }

    private struct Track {
        var samples: [(x: Int, y: Int)]
        var streak: [UInt8]
        var traced: [Bool]
        var progress = 0.0
        var done = false
    }

    let width: Int
    let height: Int
    private let opts: Options
    private let baseline: [Float]
    private let baseMean: Float
    private var tracks: [Track]
    private(set) var started = false
    private(set) var done = false
    private var lastActivity: TimeInterval

    init(baseline: [Float], width: Int, height: Int, paper: PaperSize, strokes: [Stroke],
         options: Options = Options(), now: TimeInterval) {
        precondition(baseline.count == width * height)
        self.width = width
        self.height = height
        opts = options
        self.baseline = Self.minFilter(baseline, width, height, options.alignPx)
        baseMean = Self.mean(baseline)
        lastActivity = now
        let spacing = options.sampleSpacing * paper.w
        tracks = strokes.map { s in
            let samples = Self.resample(s.points, closed: s.closed, spacing: spacing).map { p in
                (x: min(width - 1, max(0, Int((p.x / paper.w * Double(width)).rounded()))),
                 y: min(height - 1, max(0, Int((p.y / paper.h * Double(height)).rounded()))))
            }
            return Track(samples: samples, streak: Array(repeating: 0, count: samples.count),
                         traced: Array(repeating: false, count: samples.count))
        }
    }

    /// current: grayscale page, same size as the baseline. now: seconds.
    @discardableResult
    func update(_ current: [Float], now: TimeInterval) -> State {
        if done { return state(false, now) }
        let w = width, h = height
        let scale = baseMean / max(1, Self.mean(current))
        var changed = [UInt8](repeating: 0, count: w * h)
        var changedCount = 0
        for i in 0..<(w * h) where baseline[i] - current[i] * scale > opts.darkerBy {
            changed[i] = 1
            changedCount += 1
        }
        if Float(changedCount) / Float(w * h) > opts.frameOccludedFraction {
            lastActivity = now // hand over the page: assume they're drawing
            return state(true, now)
        }

        let sat = Self.integral(changed, w, h)
        let solid = Self.integral(Self.erode(sat, w, h, opts.solidPx), w, h)
        let r = max(1, Int((opts.hitRadius * Double(w)).rounded()))
        let reach = r + opts.solidPx // a solid core this close means part of a hand is within r
        var active = false
        for t in tracks.indices {
            var tracedCount = 0
            for i in tracks[t].samples.indices {
                if !tracks[t].traced[i] {
                    let (x, y) = tracks[t].samples[i]
                    if Self.boxSum(sat, w, h, x - r, y - r, x + r, y + r) == 0 {
                        tracks[t].streak[i] = 0
                    } else if Self.boxSum(solid, w, h, x - reach, y - reach, x + reach, y + reach) > 0 {
                        active = true // hand on the outline
                    } else {
                        tracks[t].streak[i] = tracks[t].streak[i] &+ 1
                        if Int(tracks[t].streak[i]) >= opts.confirmFrames {
                            tracks[t].traced[i] = true
                            active = true
                            started = true
                        }
                    }
                }
                if tracks[t].traced[i] { tracedCount += 1 }
            }
            let n = tracks[t].samples.count
            tracks[t].progress = n == 0 ? 1 : Double(tracedCount) / Double(n)
            tracks[t].done = tracks[t].progress >= opts.strokeDoneAt
        }
        if active { lastActivity = now }
        done = started && now - lastActivity >= opts.idleSeconds
        return state(false, now)
    }

    private func state(_ occluded: Bool, _ now: TimeInterval) -> State {
        State(occluded: occluded, started: started, done: done, idleSeconds: now - lastActivity,
              strokes: tracks.map { StrokeState(progress: $0.progress, done: $0.done) })
    }

    /// Points every `spacing` units along a polyline.
    static func resample(_ points: [PaperPoint], closed: Bool, spacing: Double) -> [PaperPoint] {
        guard let first = points.first else { return [] }
        let pts = closed ? points + [first] : points
        var out = [first]
        var carry = 0.0
        for i in 1..<max(1, pts.count) {
            let a = pts[i - 1], b = pts[i]
            let len = hypot(b.x - a.x, b.y - a.y)
            var d = spacing - carry
            while d <= len {
                let t = d / len
                out.append(PaperPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                d += spacing
            }
            carry = len - (d - spacing)
        }
        return out
    }

    private static func mean(_ a: [Float]) -> Float {
        a.isEmpty ? 0 : a.reduce(0, +) / Float(a.count)
    }

    /// Darkest value within `r` pixels (separable square window).
    private static func minFilter(_ img: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        guard r > 0 else { return img }
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var m = Float.infinity
                for k in max(0, x - r)...min(w - 1, x + r) { m = min(m, img[y * w + k]) }
                tmp[y * w + x] = m
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var m = Float.infinity
                for k in max(0, y - r)...min(h - 1, y + r) { m = min(m, tmp[k * w + x]) }
                out[y * w + x] = m
            }
        }
        return out
    }

    /// Summed-area table with a zero border: sat[(y+1)*(w+1) + (x+1)] = sum over [0...x]x[0...y].
    private static func integral(_ mask: [UInt8], _ w: Int, _ h: Int) -> [UInt32] {
        let W = w + 1
        var sat = [UInt32](repeating: 0, count: W * (h + 1))
        for y in 0..<h {
            var row: UInt32 = 0
            for x in 0..<w {
                row += UInt32(mask[y * w + x])
                sat[(y + 1) * W + x + 1] = sat[y * W + x + 1] + row
            }
        }
        return sat
    }

    private static func boxSum(_ sat: [UInt32], _ w: Int, _ h: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> UInt32 {
        let x0 = max(0, x0), y0 = max(0, y0), x1 = min(w - 1, x1), y1 = min(h - 1, y1)
        guard x0 <= x1, y0 <= y1 else { return 0 }
        let W = w + 1
        return sat[(y1 + 1) * W + x1 + 1] &- sat[y0 * W + x1 + 1] &- sat[(y1 + 1) * W + x0] &+ sat[y0 * W + x0]
    }

    /// Pixels whose whole (2r+1)^2 neighborhood changed (morphological erosion).
    private static func erode(_ sat: [UInt32], _ w: Int, _ h: Int, _ r: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        let full = UInt32((2 * r + 1) * (2 * r + 1))
        guard w > 2 * r, h > 2 * r else { return out }
        for y in r..<(h - r) {
            for x in r..<(w - r) where boxSum(sat, w, h, x - r, y - r, x + r, y + r) == full {
                out[y * w + x] = 1
            }
        }
        return out
    }
}
