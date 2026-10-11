import RealityKit
import UIKit

/// Characters in the same room notice each other: the newer one turns to the
/// other, they walk to a comfortable distance, face each other and have a short
/// conversation that Claude writes from both character sheets.
///
/// One scene at a time, and each pair talks at most once a minute so the room
/// doesn't turn into a chatter loop (or an API bill). Without Claude (no key,
/// offline, slow) they fall back to a canned exchange built from their greetings.
@MainActor
final class Encounters {
    /// Shows or hides a "…" bubble while the conversation is being written.
    /// Kept apart from onSpeak so a voice never tries to say "…".
    var onThinking: ((CharacterActor, Bool) -> Void)?

    /// Minimum time between two conversations of the same pair.
    var cooldown: TimeInterval = 60

    private var time: TimeInterval = 0
    private var lastCheck: TimeInterval = 0
    private var cameraRight = SIMD3<Float>(1, 0, 0)
    private var arrived: [ObjectIdentifier: TimeInterval] = [:]
    private var lastTalk: [String: TimeInterval] = [:]
    private var scene: Task<Void, Never>?
    private var cast: [CharacterActor] = []

    // MARK: Called by SceneController

    /// Every frame: notices newcomers and starts a scene when a pair is ready.
    func update(deltaTime dt: TimeInterval, actors: [CharacterActor], cameraRight right: SIMD3<Float>) {
        time += dt
        cameraRight = right
        for a in actors where arrived[ObjectIdentifier(a)] == nil { arrived[ObjectIdentifier(a)] = time }

        guard scene == nil, actors.count > 1, time - lastCheck > 0.5 else { return }
        lastCheck = time
        // Newest first: the one who just arrived is the one who goes over.
        for a in actors.reversed() where ready(a) {
            var best: (actor: CharacterActor, distance: Float)?
            for b in actors where b !== a && ready(b) && b.job.id != a.job.id {
                let d = flatDistance(a, b)
                if d > 2 { continue } // across the room: probably a different table
                if let last = lastTalk[pairKey(a, b)] {
                    // Met before: only now and then, and only if they've wandered close.
                    guard time - last > cooldown, d < comfortableDistance(a, b) * 2.2, Double.random(in: 0...1) < 0.015 else { continue }
                }
                if best == nil || d < best!.distance { best = (b, d) }
            }
            if let best {
                start(a, best.actor)
                return
            }
        }
    }

    /// A tap on `character`: if someone is nearby and they haven't just talked,
    /// it goes over and starts a conversation. Returns false to react as usual.
    func tapped(_ character: CharacterActor, among actors: [CharacterActor]) -> Bool {
        guard scene == nil, !character.isAppearing else { return false }
        let partner = actors
            .filter { $0 !== character && !$0.isAppearing && $0.job.id != character.job.id }
            .filter { flatDistance(character, $0) < max(0.8, comfortableDistance(character, $0) * 3) }
            .filter { time - (lastTalk[pairKey(character, $0)] ?? -.infinity) > cooldown }
            .min { flatDistance(character, $0) < flatDistance(character, $1) }
        guard let partner else { return false }
        start(character, partner)
        return true
    }

    /// Ends any scene at once (the room was cleared).
    func cancel() {
        scene?.cancel()
        finish()
        arrived.removeAll()
    }

    // MARK: The scene

    private func start(_ a: CharacterActor, _ b: CharacterActor) {
        let key = pairKey(a, b)
        let first = lastTalk[key] == nil
        lastTalk[key] = time // claimed now so nothing restarts it mid-scene
        cast = [a, b]
        for c in cast { c.isHeld = true }
        print("[encounter] \(a.name) meets \(b.name)\(first ? "" : " again")")
        scene = Task { [weak self] in
            await self?.play(a, b, firstMeeting: first)
            guard let self, !Task.isCancelled else { return }
            self.lastTalk[key] = self.time // the cooldown counts from the end
            self.finish()
        }
    }

    private func finish() {
        for c in cast {
            c.isHeld = false
            onThinking?(c, false)
        }
        cast = []
        scene = nil
    }

    private func play(_ a: CharacterActor, _ b: CharacterActor, firstMeeting: Bool) async {
        // Start writing right away; they walk over while Claude thinks.
        let (infoA, infoB) = Self.distinctInfos(a, b)
        let script = Script()
        let key = Keys.value(Keys.anthropic)
        Task { script.lines = await Self.write(infoA, infoB, firstMeeting: firstMeeting, apiKey: key) }

        // Notice: the newcomer turns first, then the other one looks back.
        a.face(world: b.worldPosition)
        guard await pause(0.7) else { return }
        b.face(world: a.worldPosition)

        // Close the gap (or make some room), giving up after a while.
        approach(a, b)
        let walkStart = time
        while a.isWalking || b.isWalking, time - walkStart < 8 {
            guard await pause(0.1) else { return }
        }
        a.face(world: b.worldPosition)
        b.face(world: a.worldPosition)
        guard await pause(0.4) else { return }

        if script.lines == nil {
            onThinking?(a, true)
            while script.lines == nil { guard await pause(0.1) else { return } }
            onThinking?(a, false)
            guard await pause(0.2) else { return }
        }

        var previous: CharacterActor = b
        for line in script.lines ?? [] {
            let speaker = line.speaker == infoA.name ? a : (line.speaker == infoB.name ? b : (previous === a ? b : a))
            let listener = speaker === a ? b : a
            previous = speaker
            speaker.face(world: listener.worldPosition)
            listener.face(world: speaker.worldPosition)
            if let gesture = Self.gesture(for: line.mood) { speaker.express(gesture) }
            speaker.onSpeak?(speaker, line.line)
            guard await pause(Self.readingTime(line.line)) else { return }
        }
    }

    /// Walks them to a comfortable distance apart, meeting in the middle, or
    /// only the newcomer walks if the middle isn't on the table.
    private func approach(_ a: CharacterActor, _ b: CharacterActor) {
        let pa = a.worldPosition, pb = b.worldPosition
        let want = comfortableDistance(a, b)
        var dir = SIMD3<Float>(pb.x - pa.x, 0, pb.z - pa.z)
        let d = simd_length(dir)
        guard abs(d - want) > want * 0.2 else { return }
        // Standing on top of each other (placed at the same spot): step apart sideways.
        let side = SIMD3<Float>(cameraRight.x, 0, cameraRight.z)
        dir = d > 0.005 ? dir / d : (simd_length(side) > 0.01 ? simd_normalize(side) : [1, 0, 0])

        let mid = (pa + pb) / 2
        var ta = mid - dir * (want / 2), tb = mid + dir * (want / 2)
        ta.y = pa.y
        tb.y = pb.y
        if canStand(a, ta), canStand(b, tb) {
            a.walk(toWorld: ta)
            b.walk(toWorld: tb)
            return
        }
        var t = pb - dir * want
        t.y = pa.y
        if canStand(a, t) { a.walk(toWorld: t) }
    }

    // MARK: Helpers

    private func ready(_ c: CharacterActor) -> Bool {
        // After it has popped in and said hello.
        c.isSettled && time - (arrived[ObjectIdentifier(c)] ?? time) > 4
    }

    private func canStand(_ c: CharacterActor, _ p: SIMD3<Float>) -> Bool { c.isWalkable?(p) ?? true }

    private func flatDistance(_ a: CharacterActor, _ b: CharacterActor) -> Float {
        let pa = a.worldPosition, pb = b.worldPosition
        return simd_distance(SIMD2(pa.x, pa.z), SIMD2(pb.x, pb.z))
    }

    /// About an arm's length for characters of their size.
    private func comfortableDistance(_ a: CharacterActor, _ b: CharacterActor) -> Float {
        0.55 * (a.scaledHeight + b.scaledHeight) + 0.02
    }

    private func pairKey(_ a: CharacterActor, _ b: CharacterActor) -> String {
        [a.job.id, b.job.id].sorted().joined(separator: "|")
    }

    /// Sleeps; false if the scene was cancelled.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    private static func readingTime(_ line: String) -> Double {
        min(4, max(2.5, 1.2 + 0.04 * Double(line.count)))
    }

    private static func gesture(for mood: String) -> String? {
        switch mood {
        case "excited": "happy"
        case "happy": "greet"
        case "surprised": "hop"
        case "shy": "shy"
        default: nil
        }
    }

    /// Their character sheets, with names that tell them apart (two "Pip"s
    /// become "Pip" and "Pip Two") so lines can be matched to a speaker.
    private static func distinctInfos(_ a: CharacterActor, _ b: CharacterActor) -> (CharacterInfo, CharacterInfo) {
        func info(_ c: CharacterActor) -> CharacterInfo {
            c.job.character ?? CharacterInfo(name: c.name, summary: "", greeting: "", bodyPlan: "other", heightMeters: 1,
                                             figureBox: Box(x: 0, y: 0, w: 1, h: 1), colors: [], personality: c.personality)
        }
        let ia = info(a)
        var ib = info(b)
        if ib.name.caseInsensitiveCompare(ia.name) == .orderedSame { ib.name += " Two" }
        return (ia, ib)
    }

    // MARK: Writing the dialogue

    /// Filled in when the writing finishes, so the scene can poll it.
    @MainActor private final class Script {
        var lines: [ClaudeDirector.DialogueLine]?
    }

    /// Claude's dialogue, or the canned one if Claude can't answer in time.
    private nonisolated static func write(_ a: CharacterInfo, _ b: CharacterInfo, firstMeeting: Bool,
                                          apiKey: String?) async -> [ClaudeDirector.DialogueLine] {
        guard let apiKey else { return canned(a, b, firstMeeting: firstMeeting) }
        let fetch = Task { try await ClaudeDirector(apiKey: apiKey).dialogue(between: a, and: b, firstMeeting: firstMeeting) }
        // Nobody waits 30 s for small talk.
        let timer = Task {
            try await Task.sleep(for: .seconds(15))
            fetch.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await fetch.value
        } catch {
            print("[encounter] dialogue failed, using canned lines: \(error.localizedDescription)")
            return canned(a, b, firstMeeting: firstMeeting)
        }
    }

    /// Offline exchange from their greetings.
    nonisolated static func canned(_ a: CharacterInfo, _ b: CharacterInfo, firstMeeting: Bool) -> [ClaudeDirector.DialogueLine] {
        typealias L = ClaudeDirector.DialogueLine
        let bShy = b.personality.friendliness < 0.4
        guard firstMeeting else {
            return [
                L(speaker: a.name, line: "\(b.name)! Fancy meeting you here!", mood: "excited"),
                L(speaker: b.name, line: bShy ? "Oh… hi again, \(a.name)." : "\(a.name)! Hi again!", mood: bShy ? "shy" : "happy"),
                L(speaker: a.name, line: "Wanna explore together?", mood: "happy"),
                L(speaker: b.name, line: bShy ? "…okay. Just a little." : "Race you!", mood: bShy ? "shy" : "excited"),
            ]
        }
        let helloA = a.greeting.isEmpty ? "Hi! I'm \(a.name)!" : a.greeting
        let helloB = b.greeting.isEmpty ? "Oh! Hello, I'm \(b.name)." : b.greeting
        return [
            L(speaker: a.name, line: helloA, mood: "excited"),
            L(speaker: b.name, line: helloB, mood: bShy ? "shy" : "surprised"),
            L(speaker: a.name, line: "Nice to meet you, \(b.name)!", mood: "happy"),
            L(speaker: b.name, line: bShy ? "…nice to meet you too." : "Let's be friends!", mood: bShy ? "shy" : "happy"),
        ].map { L(speaker: $0.speaker, line: String($0.line.prefix(80)), mood: $0.mood) }
    }
}

/// Picks a side for each speech bubble so two characters standing next to
/// each other don't cover each other: the one on the left talks out to the
/// left, the one on the right to the right.
enum BubbleLayout {
    static let bubbleWidth: CGFloat = 220

    /// `faces`: each character's id and its face's left and right side points on screen.
    static func spots(_ faces: [(id: String, left: CGPoint?, right: CGPoint?)], screenWidth: CGFloat) -> [String: BubbleSpot] {
        func center(_ f: (id: String, left: CGPoint?, right: CGPoint?)) -> CGPoint? {
            switch (f.left, f.right) {
            case let (l?, r?): CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
            case let (l?, nil): l
            case let (nil, r?): r
            default: nil
            }
        }
        let centers = faces.map(center)
        var spots: [String: BubbleSpot] = [:]
        for (i, face) in faces.enumerated() {
            guard let c = centers[i] else { continue }
            // The closest neighbor whose bubble could reach this one.
            let neighbor = centers.enumerated()
                .compactMap { j, p in j != i ? p : nil }
                .filter { abs($0.x - c.x) < bubbleWidth + 40 && abs($0.y - c.y) < 140 }
                .min { abs($0.x - c.x) < abs($1.x - c.x) }
            let wantRight = neighbor.map { $0.x <= c.x } ?? true
            let fitsRight = face.right.map { $0.x + bubbleWidth < screenWidth } ?? false
            let fitsLeft = face.left.map { $0.x - bubbleWidth > 0 } ?? false
            var onRight = wantRight ? (fitsRight || !fitsLeft) : (!fitsLeft && fitsRight)
            if onRight, face.right == nil { onRight = false }
            if !onRight, face.left == nil { onRight = true }
            if let p = onRight ? face.right : face.left { spots[face.id] = BubbleSpot(point: p, onRight: onRight) }
        }
        return spots
    }
}
