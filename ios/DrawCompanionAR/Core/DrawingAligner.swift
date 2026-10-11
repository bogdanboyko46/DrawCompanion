import Foundation

/// A 2D affine map: x' = a·x + b·y + tx, y' = c·x + d·y + ty.
struct Affine2: Equatable {
    var a = 1.0, b = 0.0, tx = 0.0
    var c = 0.0, d = 1.0, ty = 0.0

    static let identity = Affine2()

    func apply(_ x: Double, _ y: Double) -> (Double, Double) {
        (a * x + b * y + tx, c * x + d * y + ty)
    }

    func apply(_ p: PaperPoint) -> PaperPoint {
        let (x, y) = apply(p.x, p.y)
        return PaperPoint(x: x, y: y)
    }

    var inverse: Affine2? {
        let det = a * d - b * c
        guard abs(det) > 1e-9 else { return nil }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return Affine2(a: ia, b: ib, tx: -(ia * tx + ib * ty), c: ic, d: id, ty: -(ic * tx + id * ty))
    }

    /// The same map in another unit: pixels at `k` pixels per unit.
    func scaled(_ k: Double) -> Affine2 {
        Affine2(a: a, b: b, tx: tx * k, c: c, d: d, ty: ty * k)
    }

    /// Moves part of the way toward `other` (smooths jitter between measurements).
    func blended(toward other: Affine2, by t: Double) -> Affine2 {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return Affine2(a: m(a, other.a), b: m(b, other.b), tx: m(tx, other.tx),
                       c: m(c, other.c), d: m(d, other.d), ty: m(ty, other.ty))
    }
}

/// Keeps the outline locked to the user's actual pencil lines.
///
/// ARKit pins the page in 3D, but its guess of the paper's distance and size
/// is a little off on a plain white sheet, so the outline slides against the
/// drawing as the phone moves. This measures that slide directly: it compares
/// a top-down view of the page now with the photo the AI drew on, and finds
/// the shift, rotation and scale that put today's pencil lines back on the
/// photo's lines (chamfer matching). Pixels that match nothing, such as new
/// ink being traced or a hand, are capped so they can't pull the result.
///
/// All images are grayscale (0–255), row 0 at the top, the same size, in the
/// page's own top-down coordinates.
final class DrawingAligner {
    let width: Int
    let height: Int
    /// Distance (px) from each reference pixel to the nearest reference ink.
    private let distance: [Float]
    private let referenceInk: Int
    /// Bounding box of the reference drawing (px). Ink far outside it in the
    /// current view, like shadow edges or the page border, is ignored.
    private let box: (x0: Int, y0: Int, x1: Int, y1: Int)

    /// Distances beyond this count the same: "matches nothing".
    private let cap: Float = 6

    init?(reference: [Float], width: Int, height: Int) {
        guard reference.count == width * height else { return nil }
        self.width = width
        self.height = height
        let ink = Self.lineMask(reference, width, height)
        referenceInk = ink.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard referenceInk >= 60 else { return nil } // a blank page has nothing to lock onto
        distance = Self.distanceTransform(ink, width, height)
        var x0 = width, y0 = height, x1 = 0, y1 = 0
        for y in 0..<height {
            for x in 0..<width where ink[y * width + x] {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        box = (x0, y0, x1, y1)
    }

    /// Finds the map from current-image pixels to reference-image pixels.
    /// `prior` is the previous answer (in pixels); search starts from there.
    /// Returns nil when there isn't enough of the drawing in view to be sure.
    func align(current: [Float], prior: Affine2 = .identity, searchRadius: Int = 30) -> Affine2? {
        guard current.count == width * height else { return nil }
        // Only ink near where the drawing should be (after the prior correction).
        let margin = Double(searchRadius + 12)
        var points = Self.inkPoints(current, width, height).filter { p in
            let (x, y) = prior.apply(Double(p.x), Double(p.y))
            return x >= Double(box.x0) - margin && x <= Double(box.x1) + margin
                && y >= Double(box.y0) - margin && y <= Double(box.y1) + margin
        }
        guard points.count >= 60 else { return nil }
        if points.count > 2500 { // plenty for a stable fit, and keeps it fast
            let step = Double(points.count) / 2500
            points = (0..<2500).map { points[Int(Double($0) * step)] }
        }

        // Optimize in coordinates centered on the image, so rotating or scaling
        // doesn't also move everything sideways (keeps the parameters independent).
        let cx = Double(width) / 2, cy = Double(height) / 2
        // Centered form of the prior: x_c' = A x_c + t_c, where x_c = x - c.
        var best = Affine2(a: prior.a, b: prior.b, tx: prior.a * cx + prior.b * cy + prior.tx - cx,
                           c: prior.c, d: prior.d, ty: prior.c * cx + prior.d * cy + prior.ty - cy)
        points = points.map { (Int32($0.x) - Int32(cx), Int32($0.y) - Int32(cy)) }
        offset = (cx, cy)
        defer { offset = (0, 0) }

        // 1. Coarse translation search around the prior (the slide is mostly a shift).
        var bestScore = score(points, best)
        for stepSize in [4, 1] {
            let center = best
            let radius = stepSize == 4 ? searchRadius : 4
            var dy = -radius
            while dy <= radius {
                var dx = -radius
                while dx <= radius {
                    var t = center
                    t.tx += Double(dx)
                    t.ty += Double(dy)
                    let s = score(points, t)
                    if s < bestScore {
                        bestScore = s
                        best = t
                    }
                    dx += stepSize
                }
                dy += stepSize
            }
        }

        // 2. Refine all six parameters by coordinate descent with shrinking steps.
        var steps: [Double] = [0.02, 0.02, 1, 0.02, 0.02, 1] // a, b, tx, c, d, ty
        for _ in 0..<8 {
            for _ in 0..<4 {
                var improved = false
                for k in 0..<6 {
                    for sign in [1.0, -1.0] {
                        var t = best
                        t[k] += sign * steps[k]
                        let s = score(points, t)
                        if s < bestScore {
                            bestScore = s
                            best = t
                            improved = true
                        }
                    }
                }
                if !improved { break }
            }
            steps = steps.map { $0 / 2 }
        }

        // 3. Sanity: most of the visible drawing must now sit on the reference lines,
        //    and the map must be a plausible small correction (no flips or big zooms).
        let matched = points.filter { p in
            let (x, y) = best.apply(Double(p.x), Double(p.y))
            return sample(x, y) <= 2
        }.count
        let fraction = Double(matched) / Double(points.count)
        let det = best.a * best.d - best.b * best.c
        guard fraction >= 0.45, det > 0.8, det < 1.25, abs(best.b) < 0.15, abs(best.c) < 0.15 else { return nil }
        // Back from centered coordinates: x' = A(x - c) + t_c + c.
        return Affine2(a: best.a, b: best.b, tx: best.tx + cx - best.a * cx - best.b * cy,
                       c: best.c, d: best.d, ty: best.ty + cy - best.c * cx - best.d * cy)
    }

    /// Mean capped distance from the mapped current ink to the reference ink.
    private func score(_ points: [(x: Int32, y: Int32)], _ t: Affine2) -> Float {
        var sum: Float = 0
        for p in points {
            let (x, y) = t.apply(Double(p.x), Double(p.y))
            sum += sample(x, y)
        }
        return sum / Float(points.count)
    }

    /// Added to coordinates before looking up the distance (centered search).
    private var offset = (0.0, 0.0)

    private func sample(_ x: Double, _ y: Double) -> Float {
        let xi = Int((x + offset.0).rounded()), yi = Int((y + offset.1).rounded())
        guard xi >= 0, yi >= 0, xi < width, yi < height else { return cap }
        return min(cap, distance[yi * width + xi])
    }

    // MARK: image helpers

    /// Ink: clearly darker than the paper right around it. Judged locally (a
    /// 25×25 neighborhood), so a shadow across part of the page doesn't turn
    /// that whole part, drawing included, into "ink".
    static func inkMask(_ gray: [Float], _ w: Int, _ h: Int) -> [Bool] {
        let W = w + 1
        var sat = [Double](repeating: 0, count: W * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                row += Double(gray[y * w + x])
                sat[(y + 1) * W + x + 1] = sat[y * W + x + 1] + row
            }
        }
        let r = 12
        // Skip a thin border: page edges and the desk aren't part of the drawing.
        let border = max(2, w / 60)
        var ink = [Bool](repeating: false, count: w * h)
        for y in border..<max(border, h - border) {
            let y0 = max(0, y - r), y1 = min(h - 1, y + r)
            for x in border..<max(border, w - border) {
                let x0 = max(0, x - r), x1 = min(w - 1, x + r)
                let sum = sat[(y1 + 1) * W + x1 + 1] - sat[y0 * W + x1 + 1] - sat[(y1 + 1) * W + x0] + sat[y0 * W + x0]
                let local = Float(sum / Double((x1 - x0 + 1) * (y1 - y0 + 1)))
                let v = gray[y * w + x]
                if v < local * 0.86, local - v > 12 { ink[y * w + x] = true }
            }
        }
        return ink
    }

    /// Ink pixels that are part of pencil lines. Left out: pixels inside solid
    /// dark areas (a hand, the desk, a shadow, heavy shading) and pixels near
    /// them, because the edge of a dark area looks like a long line and would
    /// outweigh the drawing.
    static func lineMask(_ gray: [Float], _ w: Int, _ h: Int) -> [Bool] {
        let ink = inkMask(gray, w, h)
        let W = w + 1
        func sat(_ m: [Bool]) -> [Int32] {
            var t = [Int32](repeating: 0, count: W * (h + 1))
            for y in 0..<h {
                var row: Int32 = 0
                for x in 0..<w {
                    row += m[y * w + x] ? 1 : 0
                    t[(y + 1) * W + x + 1] = t[y * W + x + 1] + row
                }
            }
            return t
        }
        func count(_ t: [Int32], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int32 {
            let x0 = max(0, x0), y0 = max(0, y0), x1 = min(w - 1, x1), y1 = min(h - 1, y1)
            return t[(y1 + 1) * W + x1 + 1] - t[y0 * W + x1 + 1] - t[(y1 + 1) * W + x0] + t[y0 * W + x0]
        }
        let inkSAT = sat(ink)
        // Solid: a 7×7 window that's mostly ink (pencil lines are 1-3 px wide).
        var solid = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where ink[y * w + x] && count(inkSAT, x - 3, y - 3, x + 3, y + 3) >= 30 { solid[y * w + x] = true }
        }
        let solidSAT = sat(solid)
        var lines = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where ink[y * w + x] && count(solidSAT, x - 6, y - 6, x + 6, y + 6) == 0 { lines[y * w + x] = true }
        }
        return lines
    }

    static func inkPoints(_ gray: [Float], _ w: Int, _ h: Int) -> [(x: Int32, y: Int32)] {
        let lines = lineMask(gray, w, h)
        var points: [(x: Int32, y: Int32)] = []
        for y in 0..<h {
            for x in 0..<w where lines[y * w + x] { points.append((Int32(x), Int32(y))) }
        }
        return points
    }

    /// Two-pass chamfer distance transform (3-4 weights, in pixels).
    static func distanceTransform(_ ink: [Bool], _ w: Int, _ h: Int) -> [Float] {
        let far: Float = 1e6
        var d = ink.map { $0 ? 0 : far }
        let a: Float = 1, b: Float = 1.4142
        for y in 0..<h {
            for x in 0..<w {
                var v = d[y * w + x]
                if x > 0 { v = min(v, d[y * w + x - 1] + a) }
                if y > 0 {
                    v = min(v, d[(y - 1) * w + x] + a)
                    if x > 0 { v = min(v, d[(y - 1) * w + x - 1] + b) }
                    if x < w - 1 { v = min(v, d[(y - 1) * w + x + 1] + b) }
                }
                d[y * w + x] = v
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                var v = d[y * w + x]
                if x < w - 1 { v = min(v, d[y * w + x + 1] + a) }
                if y < h - 1 {
                    v = min(v, d[(y + 1) * w + x] + a)
                    if x < w - 1 { v = min(v, d[(y + 1) * w + x + 1] + b) }
                    if x > 0 { v = min(v, d[(y + 1) * w + x - 1] + b) }
                }
                d[y * w + x] = v
            }
        }
        return d
    }
}

private extension Affine2 {
    subscript(k: Int) -> Double {
        get { [a, b, tx, c, d, ty][k] }
        set {
            switch k {
            case 0: a = newValue
            case 1: b = newValue
            case 2: tx = newValue
            case 3: c = newValue
            case 4: d = newValue
            default: ty = newValue
            }
        }
    }
}
