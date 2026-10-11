import Foundation

/// How the user's drawing looks, measured from the top-down page photo, so
/// the outline can be drawn the same way: graphite grey for a pencil sketch,
/// blue for a blue pen, at the same line thickness.
struct InkStyle: Equatable {
    /// Ink color as it appears in the camera image (sRGB, 0–1). Using the
    /// observed color, lighting included, makes the outline sit in the scene.
    var red: Float
    var green: Float
    var blue: Float
    /// Line thickness in paper units (the page is 1000 wide).
    var width: Double

    /// Used when the page is blank: a soft pencil grey.
    static let fallback = InkStyle(red: 0.33, green: 0.33, blue: 0.35, width: 3)

    /// rgba: top-down page, row-major RGBA bytes, `width`×`height` pixels.
    static func estimate(rgba: [UInt8], width: Int, height: Int, paperWidth: Double) -> InkStyle {
        let n = width * height
        guard n > 0, rgba.count >= n * 4 else { return fallback }
        var lum = [Float](repeating: 0, count: n)
        for i in 0..<n {
            lum[i] = 0.299 * Float(rgba[i * 4]) + 0.587 * Float(rgba[i * 4 + 1]) + 0.114 * Float(rgba[i * 4 + 2])
        }
        // Pencil lines only: judged against the paper right around them, so a
        // shadow over part of the page isn't mistaken for ink (and edges of
        // dark areas like the desk are left out).
        let ink = DrawingAligner.lineMask(lum, width, height)
        var inkLum: [Float] = []
        for i in 0..<n where ink[i] { inkLum.append(lum[i]) }
        guard inkLum.count >= max(20, n / 2000) else { return fallback }

        // Color from the core of the lines (the darker half), not the blurred edges.
        let core = inkLum.sorted()[inkLum.count / 2]
        var sum = SIMD3<Float>(0, 0, 0)
        var count: Float = 0
        for i in 0..<n where ink[i] && lum[i] <= core {
            sum += SIMD3(Float(rgba[i * 4]), Float(rgba[i * 4 + 1]), Float(rgba[i * 4 + 2]))
            count += 1
        }
        let color = sum / max(1, count) / 255

        // Thickness: the shorter of the typical horizontal and vertical ink runs.
        let thicknessPx = Double(min(medianRun(ink, width, height, horizontal: true),
                                     medianRun(ink, width, height, horizontal: false)))
        let units = thicknessPx * paperWidth / Double(width)
        return InkStyle(red: color.x, green: color.y, blue: color.z, width: min(14, max(1.5, units)))
    }

    private static func percentile(_ histogram: [Int], _ total: Int, _ p: Double) -> Int {
        let target = Int(Double(total) * p)
        var seen = 0
        for (value, count) in histogram.enumerated() {
            seen += count
            if seen >= target { return value }
        }
        return 255
    }

    /// Median length of consecutive ink pixels along rows (or columns).
    private static func medianRun(_ ink: [Bool], _ w: Int, _ h: Int, horizontal: Bool) -> Int {
        var runs: [Int] = []
        let (outer, inner) = horizontal ? (h, w) : (w, h)
        for a in 0..<outer {
            var run = 0
            for b in 0..<inner {
                let i = horizontal ? a * w + b : b * w + a
                if ink[i] {
                    run += 1
                } else if run > 0 {
                    runs.append(run)
                    run = 0
                }
            }
            if run > 0 { runs.append(run) }
        }
        guard !runs.isEmpty else { return 1 }
        runs.sort()
        return runs[runs.count / 2]
    }
}
