import Foundation

/// Runs one spoken turn: decides the action, then (for new/revise) delivers
/// strokes one at a time. Events arrive in order: .action, .stroke…, .done.
protocol TurnBackend {
    func run(utterances: [String], current: Outline?, pageJPEG: Data, paper: PaperSize,
             emit: @escaping (TurnEvent) async -> Void) async throws
}

/// The real thing: Haiku filter, then streamed Sonnet drawing.
struct ClaudeBackend: TurnBackend {
    let client: ClaudeClient

    func run(utterances: [String], current: Outline?, pageJPEG: Data, paper: PaperSize,
             emit: @escaping (TurnEvent) async -> Void) async throws {
        let (action, _) = try await client.classify(utterances: utterances, current: current)
        await emit(.action(action))
        if action == .new || action == .revise {
            _ = try await client.draw(pageJPEG: pageJPEG, paper: paper, utterances: utterances,
                                      current: current, action: action) { await emit(.stroke($0)) }
        }
        await emit(.done)
    }
}

/// No API key yet: words decide the action and anything that sounds like a
/// request draws a simple flower, one stroke at a time like the real model.
struct MockBackend: TurnBackend {
    var delay: Double = 1.5 // seconds, split between "thinking" and strokes

    func run(utterances: [String], current: Outline?, pageJPEG: Data, paper: PaperSize,
             emit: @escaping (TurnEvent) async -> Void) async throws {
        let said = utterances.joined(separator: " ").lowercased()
        try await Task.sleep(nanoseconds: UInt64(delay * 0.3 * 1e9))
        let action = Self.action(for: said, hasOutline: current != nil)
        await emit(.action(action))
        if action == .new || action == .revise {
            let scale = said.contains("bigger") ? 1.3 : said.contains("smaller") ? 0.7 : 1
            let base = (action == .revise ? current.flatMap(Self.bounds) : nil)
                ?? (x: paper.w * 0.35, y: paper.h * 0.35, w: paper.w * 0.3, h: paper.h * 0.35)
            let box = (x: base.x + base.w * (1 - scale) / 2, y: base.y + base.h * (1 - scale) / 2,
                       w: base.w * scale, h: base.h * scale)
            let paths = Self.flowerPaths(box)
            for path in paths {
                try await Task.sleep(nanoseconds: UInt64(delay * 0.7 / Double(paths.count) * 1e9))
                for s in PathFlattener.flatten(path.d, paper: paper) {
                    await emit(.stroke(Stroke(role: path.role, weight: path.weight, d: s.d, closed: s.closed, points: s.points)))
                }
            }
        }
        await emit(.done)
    }

    static func action(for said: String, hasOutline: Bool) -> TurnAction {
        let words = Set(said.components(separatedBy: CharacterSet.letters.inverted))
        if !words.isDisjoint(with: ["clear", "hide"]) || said.contains("never mind") || said.contains("got it") {
            return hasOutline ? .hide : .ignore
        }
        guard !words.isDisjoint(with: ["add", "draw", "put", "make", "give", "show", "stuck", "what"]) else { return .ignore }
        let revising = hasOutline && (!words.isDisjoint(with: ["bigger", "smaller", "move", "instead"]) || said.contains("make it"))
        return revising ? .revise : .new
    }

    private static func bounds(_ outline: Outline) -> (x: Double, y: Double, w: Double, h: Double)? {
        let pts = outline.strokes.flatMap(\.points)
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return nil }
        return (minX, minY, maxX - minX, maxY - minY)
    }

    /// The flower as the model would write it: a few curves per stroke.
    static func flowerPaths(_ box: (x: Double, y: Double, w: Double, h: Double)) -> [(role: StrokeRole, weight: StrokeWeight, d: String)] {
        func r(_ v: Double) -> Int { Int(v.rounded()) }
        let cx = box.x + box.w / 2
        let s = min(box.w, box.h)
        let cy = box.y + s * 0.3
        func circle(_ rad: Double) -> String {
            "M \(r(cx - rad)) \(r(cy)) C \(r(cx - rad)) \(r(cy - rad * 1.33)) \(r(cx + rad)) \(r(cy - rad * 1.33)) \(r(cx + rad)) \(r(cy)) "
                + "C \(r(cx + rad)) \(r(cy + rad * 1.33)) \(r(cx - rad)) \(r(cy + rad * 1.33)) \(r(cx - rad)) \(r(cy)) Z"
        }
        func petal(_ a: Double) -> String {
            func at(_ along: Double, _ side: Double) -> String {
                "\(r(cx + cos(a) * along - sin(a) * side)) \(r(cy + sin(a) * along + cos(a) * side))"
            }
            let p0 = at(s * 0.08, 0), p1 = at(s * 0.26, 0)
            return "M \(p0) Q \(at(s * 0.17, s * 0.12)) \(p1) Q \(at(s * 0.17, -s * 0.12)) \(p0) Z"
        }
        var paths: [(StrokeRole, StrokeWeight, String)] = [
            (.construction, .light, circle(s * 0.27)),
            (.construction, .light, "M \(r(cx)) \(r(cy)) L \(r(cx)) \(r(box.y + box.h))"),
            (.contour, .medium, circle(s * 0.08)),
        ]
        paths += (0..<6).map { (StrokeRole.contour, StrokeWeight.medium, petal(Double($0) / 6 * 2 * .pi)) }
        paths.append((.contour, .medium, "M \(r(cx)) \(r(cy + s * 0.27)) Q \(r(cx + s * 0.06)) \(r((cy + box.y + box.h) / 2)) \(r(cx)) \(r(box.y + box.h))"))
        return paths.map { (role: $0.0, weight: $0.1, d: $0.2) }
    }
}
