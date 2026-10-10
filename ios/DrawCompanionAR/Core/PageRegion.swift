import Foundation

/// A rectangle on the page, in paper units.
struct PaperRect: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// The photos sent to the drawing model: the whole page, plus (when the
/// drawing is small) an enlarged close-up of `region` with a finer grid.
struct PagePhotos {
    var full: Data
    var closeUp: Data? = nil
    var region: PaperRect? = nil
}

/// Where the drawing is on the page. The AI places things much more
/// accurately when it also gets an enlarged close-up of this area: a sketch
/// that fills a fifth of the page is only ~150 pixels wide in the full photo.
enum PageRegion {
    /// The drawing's bounding box with generous margins, or nil when the page
    /// is blank or the drawing already fills most of it (no close-up needed).
    static func focus(rgba: [UInt8], width: Int, height: Int, paper: PaperSize) -> PaperRect? {
        let n = width * height
        guard n > 0, rgba.count >= n * 4 else { return nil }
        var lum = [Float](repeating: 0, count: n)
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<n {
            let l = 0.299 * Float(rgba[i * 4]) + 0.587 * Float(rgba[i * 4 + 1]) + 0.114 * Float(rgba[i * 4 + 2])
            lum[i] = l
            histogram[min(255, Int(l))] += 1
        }
        var seen = 0, paperLevel: Float = 255
        for (v, c) in histogram.enumerated() {
            seen += c
            if seen >= n * 3 / 4 { paperLevel = Float(v); break }
        }
        let cutoff = min(paperLevel * 0.78, paperLevel - 22)

        // Ink bounding box, ignoring a thin border (page edges and shadows).
        let border = max(2, width / 50)
        var minX = width, minY = height, maxX = -1, maxY = -1, count = 0
        for y in border..<(height - border) {
            for x in border..<(width - border) where lum[y * width + x] < cutoff {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                count += 1
            }
        }
        guard count >= max(20, n / 3000), maxX > minX, maxY > minY else { return nil }

        let k = paper.w / Double(width) // paper units per pixel
        var box = PaperRect(x: Double(minX) * k, y: Double(minY) * k,
                            w: Double(maxX - minX) * k, h: Double(maxY - minY) * k)
        // Room around the drawing for additions, at least 300 units across.
        let margin = max(box.w, box.h) * 0.4 + 30
        box = PaperRect(x: box.x - margin, y: box.y - margin, w: box.w + 2 * margin, h: box.h + 2 * margin)
        if box.w < 300 { box.x -= (300 - box.w) / 2; box.w = 300 }
        if box.h < 300 { box.y -= (300 - box.h) / 2; box.h = 300 }
        // Clamp to the page.
        box.x = max(0, box.x); box.y = max(0, box.y)
        box.w = min(paper.w - box.x, box.w); box.h = min(paper.h - box.y, box.h)
        guard box.w * box.h < paper.w * paper.h * 0.6 else { return nil }
        return box
    }
}
