import ARKit
import RealityKit
import UIKit

/// Collision on the root lets taps find the character and lets pinch scale it.
final class CharacterRoot: Entity, HasCollision {}

/// A living character in the room: its model, its clips, and a small brain.
///
/// Hierarchy: anchor (where it was born, on the paper)
///              └ root      position = where it walked to; scale = pinch
///                 └ yawNode  which way it faces
///                    └ body   model normalized to `height`, feet at y = 0
///
/// Rigged characters play their trimmed USDZ clips. Static models (anything
/// the auto-rigger couldn't take) get procedural motion instead: they breathe,
/// hop when they walk, and jump-spin when happy, so every character feels alive.
@MainActor
final class CharacterActor {
    let job: CharacterJob
    let anchor: AnchorEntity
    let root = CharacterRoot()
    let height: Float
    let personality: Personality

    private let yawNode = Entity()
    private let body = Entity()
    private let model: Entity
    private var animator: Entity?
    private var clips: [String: (resource: AnimationResource, clip: Clip)] = [:]
    private var playing: String?

    private enum State { case appearing, idle, walking, performing(String) }
    private var state: State = .appearing
    private var target: SIMD3<Float>?
    private var time: TimeInterval = 0
    private var nextDecision: TimeInterval = 3
    private var performUntil: TimeInterval = 0
    private var performStart: TimeInterval = 0
    private var lastGreet: TimeInterval = -100
    private var yaw: Float = 0
    private var desiredYaw: Float = 0
    private var reactions = 0

    /// Says something in a speech bubble.
    var onSpeak: ((CharacterActor, String) -> Void)?
    /// Whether a world point is on the same surface (keeps it from walking off the desk).
    var isWalkable: ((SIMD3<Float>) -> Bool)?

    var animated: Bool { !clips.isEmpty }
    var name: String { job.displayName }

    private init(job: CharacterJob, model: Entity, anchor: AnchorEntity, height: Float) {
        self.job = job
        self.model = model
        self.anchor = anchor
        self.height = height
        personality = job.character?.personality ?? .neutral
    }

    // MARK: Loading

    static func load(job: CharacterJob, modelURL: URL, transform: simd_float4x4, height: Float) async throws -> CharacterActor {
        let loaded = try await Entity(contentsOf: modelURL)
        let actor = CharacterActor(job: job, model: loaded, anchor: AnchorEntity(world: transform), height: height)
        actor.assemble()
        return actor
    }

    private func assemble() {
        // Normalize: feet on the ground, centered, `height` tall.
        let bounds = model.visualBounds(relativeTo: nil)
        let extents = bounds.extents
        let s = extents.y > 0.0001 ? height / extents.y : 1
        model.scale = SIMD3(repeating: s)
        // A couple of millimeters up so the soles rest on the table, not in it.
        model.position = [-bounds.center.x * s, -bounds.min.y * s + 0.002, -bounds.center.z * s]

        body.addChild(model)
        yawNode.addChild(body)
        root.addChild(yawNode)
        anchor.addChild(root)

        let size = extents * s
        root.collision = CollisionComponent(shapes: [
            ShapeResource.generateBox(size: [max(size.x, 0.05), size.y, max(size.z, 0.05)])
                .offsetBy(translation: [0, size.y / 2, 0]),
        ])
        addShadows(model)
        prepareClips()
    }

    private func addShadows(_ entity: Entity) {
        if entity.components.has(ModelComponent.self) {
            entity.components.set(GroundingShadowComponent(castsShadow: true))
        }
        for child in entity.children { addShadows(child) }
    }

    /// The packer put every clip on one timeline; cut it back into clips.
    private func prepareClips() {
        guard let clipList = job.model?.clips, !clipList.isEmpty,
              let holder = CharacterActor.firstAnimated(model),
              let source = holder.availableAnimations.first
        else { return }
        animator = holder
        for clip in clipList {
            let view = AnimationView(
                source: source.definition,
                name: clip.name,
                repeatMode: clip.loop ? .repeat : .none,
                trimStart: clip.start,
                trimEnd: clip.end)
            if let resource = try? AnimationResource.generate(with: view) {
                clips[clip.name] = (resource, clip)
            }
        }
        // Fill gaps so the brain can always ask for the basics.
        if clips["idle"] == nil {
            let calm = clips.first { $0.value.clip.loop && !["walk", "run"].contains($0.key) }?.value
            if let loop = calm ?? clips.values.first(where: { $0.clip.loop }) { clips["idle"] = loop }
        }
        if clips["walk"] == nil, let run = clips["run"] { clips["walk"] = run }
        if clips["greet"] == nil, let happy = clips["happy"] { clips["greet"] = happy }
    }

    private static func firstAnimated(_ entity: Entity) -> Entity? {
        if !entity.availableAnimations.isEmpty { return entity }
        for child in entity.children {
            if let found = firstAnimated(child) { return found }
        }
        return nil
    }

    // MARK: Appearing

    /// Pops in with a little overshoot, then greets.
    func appear() {
        root.scale = SIMD3(repeating: 0.01)
        _ = play("idle", transition: 0)
        var big = root.transform
        big.scale = SIMD3(repeating: 1.12)
        root.move(to: big, relativeTo: anchor, duration: 0.32, timingFunction: .easeOut)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self else { return }
            var settle = self.root.transform
            settle.scale = SIMD3(repeating: 1)
            self.root.move(to: settle, relativeTo: self.anchor, duration: 0.22, timingFunction: .easeInOut)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.state = .idle
            self.greet()
            if let line = self.job.character?.greeting, !line.isEmpty { self.onSpeak?(self, line) }
        }
    }

    // MARK: Commands

    func greet() {
        lastGreet = time
        perform("greet")
    }

    /// Tapped: react, a little differently each time.
    func react() {
        reactions += 1
        perform(reactions % 3 == 0 ? "greet" : "happy")
        let shy = personality.friendliness < 0.4
        let lines = shy ? ["Oh!", "…hi.", "Eep!"] : ["Hehe!", "That tickles!", "Again!", "Hi hi!", "♪"]
        if reactions % 2 == 1 { onSpeak?(self, lines[reactions / 2 % lines.count]) }
    }

    /// Walk to a world point on the surface.
    func walk(toWorld point: SIMD3<Float>) {
        var p = anchor.convert(position: point, from: nil)
        p.y = 0
        target = p
        state = .walking
        _ = play("walk")
    }

    // MARK: Brain

    func update(deltaTime dt: TimeInterval, cameraPosition: SIMD3<Float>) {
        time += dt
        let pos = root.position
        let cam = anchor.convert(position: cameraPosition, from: nil)
        let toCam = SIMD2<Float>(cam.x - pos.x, cam.z - pos.z)
        let camDistance = simd_length(toCam)

        switch state {
        case .appearing:
            desiredYaw = atan2(toCam.x, toCam.y)

        case .performing:
            if time >= performUntil { enterIdle() }

        case .idle:
            // Keep half an eye on you.
            if camDistance < 1.6 { desiredYaw = atan2(toCam.x, toCam.y) }
            let approached = camDistance < 0.45 * Float(root.scale.x) + 0.15
            if approached, personality.friendliness > 0.4, time - lastGreet > 25 {
                greet()
            } else if time > nextDecision {
                decide()
            }

        case .walking:
            guard let target else { enterIdle(); break }
            let d = SIMD2<Float>(target.x - pos.x, target.z - pos.z)
            let distance = simd_length(d)
            if distance < 0.008 {
                self.target = nil
                enterIdle()
            } else {
                desiredYaw = atan2(d.x, d.y)
                // Turn first, then walk: no moonwalking.
                if abs(angleDifference(yaw, desiredYaw)) < 0.7 {
                    let step = min(distance, walkSpeed * Float(dt))
                    root.position += SIMD3(d.x / distance * step, 0, d.y / distance * step)
                }
            }
        }

        let turnRate: Float = 3.5 + 3 * Float(personality.energy)
        yaw = approachAngle(yaw, desiredYaw, maxStep: turnRate * Float(dt))
        yawNode.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])

        if !animated { proceduralMotion() }
    }

    /// World position just above the head, for the speech bubble.
    /// Points level with the face just past each side of the character, as
    /// seen from the camera, so a speech bubble can sit beside it.
    func faceSidePoints(cameraRight: SIMD3<Float>) -> (left: SIMD3<Float>, right: SIMD3<Float>) {
        let s = root.scale.x
        let face = anchor.convert(position: root.position + [0, height * s * 0.75, 0], to: nil)
        let offset = cameraRight * (height * s * 0.45 + 0.015)
        return (face - offset, face + offset)
    }

    var headWorldPosition: SIMD3<Float> {
        anchor.convert(position: root.position + [0, height * root.scale.y * 1.08, 0], to: nil)
    }

    private var walkSpeed: Float {
        // Body lengths per second, faster for energetic characters.
        height * root.scale.x * (0.45 + 0.55 * Float(personality.energy))
    }

    private func decide() {
        let energy = personality.energy
        nextDecision = time + Double.random(in: 2.5...7) * (1.3 - 0.6 * energy)
        let roll = Double.random(in: 0...1)
        if roll < 0.35 + 0.4 * energy, let spot = wanderSpot() {
            target = spot
            state = .walking
            _ = play("walk")
        } else if roll > 0.92 - 0.1 * energy {
            perform(clips["dance"] != nil ? "dance" : "happy")
        } else {
            // Look around.
            desiredYaw += Float.random(in: -1.2...1.2)
        }
    }

    /// A random spot near where it was born, on the same surface.
    private func wanderSpot() -> SIMD3<Float>? {
        let radius = max(0.12, height * 1.6)
        for _ in 0..<6 {
            let a = Float.random(in: 0..<(2 * .pi))
            let r = Float.random(in: 0.3...1) * radius
            let local = SIMD3<Float>(cos(a) * r, 0, sin(a) * r)
            let world = anchor.convert(position: local, to: nil)
            if isWalkable?(world) ?? true { return local }
        }
        return nil
    }

    private func perform(_ role: String) {
        let duration = play(role) ?? 1.1 // procedural fallback length
        state = .performing(role)
        performStart = time
        performUntil = time + max(0.4, duration - 0.15)
    }

    private func enterIdle() {
        state = .idle
        _ = play("idle")
        if nextDecision < time + 1.5 { nextDecision = time + 1.5 }
    }

    /// Returns the clip length, or nil if this character has no such clip.
    @discardableResult
    private func play(_ role: String, transition: TimeInterval = 0.25) -> TimeInterval? {
        guard let entry = clips[role], let animator else { return nil }
        if playing == role, entry.clip.loop { return entry.clip.duration }
        animator.playAnimation(entry.resource, transitionDuration: transition, startsPaused: false)
        playing = role
        return entry.clip.duration
    }

    // MARK: Procedural life for static models

    private func proceduralMotion() {
        let t = Float(time)
        var position = SIMD3<Float>.zero
        var scale = SIMD3<Float>(repeating: 1)
        var tilt = simd_quatf(angle: 0, axis: [0, 0, 1])

        switch state {
        case .walking:
            let phase = t * (8 + 5 * Float(personality.energy))
            let hop = abs(sin(phase))
            position.y = hop * height * 0.07
            let squash = 1 - 0.08 * (1 - hop) * (1 - hop)
            scale = [1 / squash.squareRoot(), squash, 1 / squash.squareRoot()]
            tilt = simd_quatf(angle: 0.08 * sin(phase), axis: [0, 0, 1])
        case .performing(let role):
            let p = Float(min(1, (time - performStart) / 1.1))
            if role == "greet" {
                tilt = simd_quatf(angle: 0.22 * sin(p * .pi * 6) * (1 - p), axis: [0, 0, 1])
            } else {
                position.y = sin(p * .pi) * height * 0.45
                tilt = simd_quatf(angle: p * 2 * .pi, axis: [0, 1, 0])
                let squash = p < 0.1 ? 1 - p * 1.5 : (p > 0.9 ? 1 - (1 - p) * 1.5 : 1)
                scale = [1, squash, 1]
            }
        default:
            let breath = sin(t * 2.2)
            scale = [1 - 0.01 * breath, 1 + 0.022 * breath, 1 - 0.01 * breath]
        }
        body.position = position
        body.scale = scale
        body.orientation = tilt
    }
}

private func angleDifference(_ a: Float, _ b: Float) -> Float {
    var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
    if d > .pi { d -= 2 * .pi }
    if d < -.pi { d += 2 * .pi }
    return d
}

private func approachAngle(_ current: Float, _ target: Float, maxStep: Float) -> Float {
    let d = angleDifference(current, target)
    return current + max(-maxStep, min(maxStep, d))
}
