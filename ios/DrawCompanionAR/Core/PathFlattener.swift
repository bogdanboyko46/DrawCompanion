import Foundation

// The drawing model writes each stroke as compact SVG-style path data
// ("M 120 340 C 150 300 200 300 230 340"): a curve costs a few numbers
// instead of dozens of points, which makes the model's output, and so its
// response time, several times shorter. This turns that path data into the
// polylines the app draws and tracks. Supported: absolute M, L, H, V, Q, C, Z.
// Each M starts a separate stroke.
enum PathFlattener {
    static let segmentsPerCurve = 12
    private static let argCount: [Character: Int] = ["M": 2, "L": 2, "H": 1, "V": 1, "Q": 4, "C": 6, "Z": 0]
    private static let tokenPattern = try! NSRegularExpression(pattern: "[A-Za-z]|-?\\d*\\.?\\d+(?:[eE]-?\\d+)?")

    /// Returns (d, closed, points) for each stroke in the path, or [] if unusable.
    static func flatten(_ d: String, paper: PaperSize) -> [(d: String, closed: Bool, points: [PaperPoint])] {
        let ns = d as NSString
        let tokens = tokenPattern.matches(in: d, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }

        var strokes: [(closed: Bool, points: [PaperPoint])] = []
        var pts: [PaperPoint]? = nil
        var start: PaperPoint? = nil
        var pen: PaperPoint? = nil
        var cmd: Character? = nil
        var i = 0
        func num() -> Double { defer { i += 1 }; return Double(tokens[i]) ?? .nan }
        func finish(_ closed: Bool) {
            if let p = pts, p.count >= 2 { strokes.append((closed, p)) }
            pts = nil
        }

        while i < tokens.count {
            if let c = tokens[i].first, c.isLetter {
                let upper = Character(c.uppercased())
                guard argCount[upper] != nil else { return [] } // unknown command: don't guess
                cmd = upper
                i += 1
                if upper == "Z" {
                    finish(true)
                    pen = start
                    continue
                }
            } else if cmd == nil || cmd == "Z" {
                return []
            }
            guard let c = cmd, let n = argCount[c] else { return [] }
            if i + n > tokens.count { break } // truncated: keep what's complete
            if c == "M" {
                finish(false)
                let p = PaperPoint(x: num(), y: num())
                pen = p
                start = p
                pts = [p]
                cmd = "L" // extra pairs after M are line-tos
                continue
            }
            guard let current = pen else { return [] }
            if pts == nil { pts = [current] }
            switch c {
            case "L": pen = PaperPoint(x: num(), y: num())
            case "H": pen = PaperPoint(x: num(), y: current.y)
            case "V": pen = PaperPoint(x: current.x, y: num())
            default:
                var ctrl = [current]
                for _ in 0..<(c == "Q" ? 1 : 2) { ctrl.append(PaperPoint(x: num(), y: num())) }
                let end = PaperPoint(x: num(), y: num())
                ctrl.append(end)
                for s in 1...segmentsPerCurve { pts!.append(bezier(ctrl, Double(s) / Double(segmentsPerCurve))) }
                pen = end
                continue
            }
            pts!.append(pen!)
        }
        finish(false)

        let cleaned = strokes
            .map { s in (s.closed, s.points.filter { $0.x.isFinite && $0.y.isFinite }.map { clamp($0, paper) }) }
            .filter { $0.1.count >= 2 }
        return cleaned.map { (closed, points) in
            (cleaned.count == 1 ? d.trimmingCharacters(in: .whitespacesAndNewlines) : lineData(points, closed), closed, points)
        }
    }

    /// One streamed stroke object (JSON) -> drawable strokes. Malformed ones yield [].
    static func strokes(fromJSON json: String, paper: PaperSize) -> [Stroke] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let role = (obj["role"] as? String).flatMap(StrokeRole.init) ?? .contour
        let weight = (obj["weight"] as? String).flatMap(StrokeWeight.init) ?? .medium
        return flatten(obj["d"] as? String ?? "", paper: paper).map {
            Stroke(role: role, weight: weight, d: $0.d, closed: $0.closed, points: $0.points)
        }
    }

    private static func lineData(_ points: [PaperPoint], _ closed: Bool) -> String {
        "M " + points.map { "\(Int($0.x.rounded())) \(Int($0.y.rounded()))" }.joined(separator: " L ") + (closed ? " Z" : "")
    }

    /// De Casteljau evaluation for quadratic or cubic Bézier control points.
    private static func bezier(_ ctrl: [PaperPoint], _ t: Double) -> PaperPoint {
        var p = ctrl
        while p.count > 1 {
            p = (0..<(p.count - 1)).map { k in
                PaperPoint(x: p[k].x + (p[k + 1].x - p[k].x) * t, y: p[k].y + (p[k + 1].y - p[k].y) * t)
            }
        }
        return p[0]
    }

    private static func clamp(_ p: PaperPoint, _ paper: PaperSize) -> PaperPoint {
        PaperPoint(x: min(paper.w, max(0, p.x)), y: min(paper.h, max(0, p.y)))
    }
}

/// Pulls complete stroke objects out of the model's JSON as it streams in.
/// The output is {"strokes":[{...},{...}]}; every time an object inside the
/// array closes, its text is returned so it can be drawn right away.
struct StrokeScanner {
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var buffer = ""
    private var capturing = false

    mutating func push(_ text: String) -> [String] {
        var done: [String] = []
        for ch in text {
            if capturing { buffer.append(ch) }
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"":
                inString = true
            case "{", "[":
                depth += 1
                if ch == "{" && depth == 3 {
                    capturing = true
                    buffer = "{"
                }
            case "}", "]":
                if ch == "}" && depth == 3 && capturing {
                    done.append(buffer)
                    capturing = false
                    buffer = ""
                }
                depth -= 1
            default:
                break
            }
        }
        return done
    }
}
