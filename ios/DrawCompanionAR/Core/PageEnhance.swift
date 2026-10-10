import Foundation

/// Cleans up the page photo before it goes to the AI: lamps and shadows turn
/// white paper grey or yellow and make pencil faint. The paper's own white
/// sets per-channel gains (white balance and brightness), then a gentle curve
/// darkens mid-tones so light pencil lines read clearly.
enum PageEnhance {
    static func enhanced(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        let n = width * height
        guard n > 0, rgba.count >= n * 4 else { return rgba }
        // Paper white per channel: a high percentile, since most of the page is paper.
        var gains = [Float](repeating: 1, count: 3)
        for c in 0..<3 {
            var histogram = [Int](repeating: 0, count: 256)
            for i in 0..<n { histogram[Int(rgba[i * 4 + c])] += 1 }
            let target = Int(Double(n) * 0.9)
            var seen = 0, white = 255
            for (v, count) in histogram.enumerated() {
                seen += count
                if seen >= target { white = v; break }
            }
            gains[c] = 245 / Float(max(white, 40))
        }
        // Lookup table per channel: gain, then a curve that keeps white and black.
        let tables: [[UInt8]] = gains.map { g in
            (0..<256).map { v in
                let x = min(1, Float(v) * g / 255)
                return UInt8(min(255, max(0, pow(x, 1.4) * 255)).rounded())
            }
        }
        var out = rgba
        for i in 0..<n {
            for c in 0..<3 { out[i * 4 + c] = tables[c][Int(rgba[i * 4 + c])] }
            out[i * 4 + 3] = 255
        }
        return out
    }
}
