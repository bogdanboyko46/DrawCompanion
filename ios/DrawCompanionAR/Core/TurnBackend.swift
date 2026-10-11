import Foundation

/// Runs one spoken turn: decides the action, then (for new/revise) delivers
/// strokes one at a time. Events arrive in order: .action, .stroke…, .done.
protocol TurnBackend {
    func run(utterances: [String], current: Outline?, page: PagePhotos, paper: PaperSize,
             emit: @escaping (TurnEvent) async -> Void) async throws
}

/// The real thing: Haiku filter, then streamed Sonnet drawing.
///
/// Speed: when the words sound like a drawing request, the drawing call starts
/// at the same time as the filter instead of after it, which saves the
/// filter's whole round trip (~1 s) before the first line. Its strokes are
/// held back until the filter agrees; if the filter says ignore or hide (or
/// picks the other of new/revise), the speculative call is cancelled, which
/// stops billing for it. Chatter that doesn't sound like a request never
/// starts one, so an always-on mic doesn't pay for it.
struct ClaudeBackend: TurnBackend {
    let client: ClaudeClient
    var speculate = true

    func run(utterances: [String], current: Outline?, page: PagePhotos, paper: PaperSize,
             emit: @escaping (TurnEvent) async -> Void) async throws {
        let guess = speculate ? Speculation.guess(utterances: utterances, hasOutline: current != nil) : nil
        let gate = StrokeGate()
        let early: Task<Int, Error>? = guess.map { action in
            Task {
                try await client.draw(page: page, paper: paper, utterances: utterances, current: current, action: action) {
                    await gate.push($0)
                }
            }
        }
        try await withTaskCancellationHandler {
            let decision: (action: TurnAction, note: String)
            do {
                decision = try await client.classify(utterances: utterances, current: current)
            } catch {
                early?.cancel()
                throw error
            }
            let (action, note) = decision
            print("[DC] filter: \(action.rawValue) (\(note)) for \(utterances)\(guess.map { ", speculated \($0.rawValue)" } ?? "")")
            await emit(.action(action))
            if action == .new || action == .revise {
                let n: Int
                if let early, action == guess {
                    await gate.open { await emit(.stroke($0)) }
                    n = try await early.value
                } else {
                    early?.cancel()
                    n = try await client.draw(page: page, paper: paper, utterances: utterances,
                                              current: current, action: action) { await emit(.stroke($0)) }
                }
                print("[DC] draw: \(n) strokes")
            } else {
                early?.cancel()
            }
            await emit(.done)
        } onCancel: {
            early?.cancel() // the user kept talking: stop paying for this one too
        }
    }
}

/// Holds strokes from a speculative drawing call until the filter agrees,
/// then passes them on in order (buffered ones first).
actor StrokeGate {
    private var buffer: [Stroke] = []
    private var sink: ((Stroke) async -> Void)?

    func push(_ stroke: Stroke) async {
        if let sink { await sink(stroke) } else { buffer.append(stroke) }
    }

    func open(_ sink: @escaping (Stroke) async -> Void) async {
        // Strokes pushed while this drains land in the buffer and are drained too.
        while !buffer.isEmpty { await sink(buffer.removeFirst()) }
        self.sink = sink
    }
}

/// Decides, from the words alone and before the filter answers, whether to
/// start drawing right away and as which action.
enum Speculation {
    private static let requestWords: Set<String> = [
        "add", "draw", "put", "make", "give", "show", "sketch", "stuck", "suggest", "need", "want",
        "bigger", "smaller", "larger", "move", "instead", "turn", "change", "another", "more",
    ]
    private static let reviseWords: Set<String> = [
        "bigger", "smaller", "larger", "move", "instead", "turn", "rounder", "thinner", "thicker", "wider",
        "taller", "shorter", "left", "right", "up", "down", "higher", "lower", "rotate", "flip", "it",
    ]
    private static let stopWords: Set<String> = ["clear", "hide", "remove", "erase"]

    static func guess(utterances: [String], hasOutline: Bool) -> TurnAction? {
        let said = utterances.joined(separator: " ").lowercased()
        let words = Set(said.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        guard !words.isDisjoint(with: requestWords), words.isDisjoint(with: stopWords),
              !said.contains("never mind"), !said.contains("got it") else { return nil }
        guard hasOutline else { return .new }
        // "add a hat" with an outline shown is usually something new; "make it bigger" a revision.
        let adding = !words.isDisjoint(with: ["add", "draw", "put", "give", "another"])
        return adding || words.isDisjoint(with: reviseWords) ? .new : .revise
    }
}

/// No API key yet: words decide the action and anything that sounds like a
/// request draws a simple flower, one stroke at a time like the real model.
struct MockBackend: TurnBackend {
    var delay: Double = 1.5 // seconds, split between "thinking" and strokes

    func run(utterances: [String], current: Outline?, page: PagePhotos, paper: PaperSize,
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
