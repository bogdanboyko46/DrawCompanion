import ARKit
import RealityKit
import UIKit

/// The visible "making of" while the server works, anchored to the real paper:
///
/// 1. A light sweeps across the page (we're reading it).
/// 2. The drawn figure peels up off the paper and stands, facing you, with
///    sparkles rising around it.
/// 3. When the concept render arrives, the flat drawing cross-fades into the
///    painted 3D version of itself.
/// 4. When the model is ready, the card bursts and the character appears.
@MainActor
final class PaperPortal {
    let anchor: AnchorEntity
    private let page: CapturedPage
    private let pivot = Entity()        // turns to face the camera
    private let card: ModelEntity        // the drawing (cutout if available)
    private var concept: ModelEntity?
    private let glow: ModelEntity        // soft halo on the paper
    private let sparkles = Entity()
    private var sweep: ModelEntity?
    private var lifted = false
    private var liftStart: TimeInterval = 0
    private var time: TimeInterval = 0
    private var conceptFade: Float = -1
    private var dissolving: (start: TimeInterval, done: () -> Void)?
    private var dissolved = false
    private let cardHeight: Float

    init(page: CapturedPage) {
        self.page = page
        anchor = AnchorEntity(world: page.transform)

        // The cutout keeps the page's frame, so the flat card covers the paper
        // exactly and the figure sits right on top of the drawn one.
        let source = page.cutout ?? page.image
        cardHeight = max(0.08, page.size.y)
        card = PaperPortal.makeCard(image: source, width: page.size.x, height: page.size.y)

        // Halo: a soft rounded glow lying on the paper.
        glow = ModelEntity(
            mesh: .generatePlane(width: page.size.x * 1.08, depth: page.size.y * 1.08, cornerRadius: 0.01),
            materials: [PaperPortal.glowMaterial(alpha: 0.0)])
        glow.position.y = 0.001
        anchor.addChild(glow)

        anchor.addChild(pivot)
        pivot.addChild(card)
        // Start lying flat exactly where the figure is on the paper.
        card.transform = flatTransform()

        var emitter = ParticleEmitterComponent.Presets.magic
        emitter.emitterShape = .plane
        emitter.emitterShapeSize = [page.size.x, 0.001, page.size.y]
        emitter.mainEmitter.birthRate = 0
        PaperPortal.scaleToTabletop(&emitter)
        sparkles.components.set(emitter)
        anchor.addChild(sparkles)
    }

    // MARK: Stages

    func startScan() {
        let bar = ModelEntity(
            mesh: .generateBox(width: page.size.x * 1.04, height: 0.0015, depth: 0.006, cornerRadius: 0.0007),
            materials: [PaperPortal.glowMaterial(alpha: 0.95)])
        bar.position = [0, 0.003, -page.size.y / 2]
        anchor.addChild(bar)
        sweep = bar
        var end = bar.transform
        end.translation.z = page.size.y / 2
        bar.move(to: end, relativeTo: anchor, duration: 1.1, timingFunction: .easeInOut)
        setGlow(0.35)
    }

    func lift() {
        guard !lifted else { return }
        lifted = true
        liftStart = time
        sweep?.removeFromParent()
        sweep = nil
        setEmission(40)
        var t = Transform()
        t.translation = [0, cardHeight * 0.8 / 2 + 0.02, 0]
        t.scale = SIMD3(repeating: 0.8)
        card.move(to: t, relativeTo: pivot, duration: 1.4, timingFunction: .easeInOut)
    }

    /// `cg` should already be cut out (do that off the main thread).
    func showConcept(_ cg: CGImage) {
        concept?.removeFromParent() // a better view arrived: swap it in
        let aspect = Float(cg.width) / Float(max(1, cg.height))
        let entity = PaperPortal.makeCard(image: cg, width: cardHeight * aspect, height: cardHeight)
        entity.components.set(OpacityComponent(opacity: 0))
        entity.position.z = 0.002 // just in front of the drawing
        card.addChild(entity)
        concept = entity
        conceptFade = 0
        setEmission(90)
        burst()
    }

    /// Pops the card and calls `done` at the moment the character should appear.
    func dissolve(done: @escaping () -> Void) {
        dissolved = true
        dissolving = (time, done)
        setEmission(0)
        burst()
        var t = card.transform
        t.scale = [0.01, 0.01, 0.01]
        card.move(to: t, relativeTo: pivot, duration: 0.45, timingFunction: .easeIn)
    }

    func remove() {
        // Never strand a character waiting for this portal to burst.
        if let d = dissolving {
            dissolving = nil
            d.done()
        }
        anchor.removeFromParent()
    }

    /// The presets are tuned for room-sized effects; this is a sheet of paper.
    static func scaleToTabletop(_ e: inout ParticleEmitterComponent) {
        e.mainEmitter.size *= 0.15
        e.speed *= 0.2
    }

    // MARK: Per frame

    func update(deltaTime dt: TimeInterval, cameraPosition: SIMD3<Float>) {
        time += dt
        if lifted {
            // Face the viewer (yaw only), with a slow bob.
            let local = anchor.convert(position: cameraPosition, from: nil)
            let yaw = atan2(local.x, local.z)
            let current = pivot.orientation
            pivot.orientation = simd_slerp(current, simd_quatf(angle: yaw, axis: [0, 1, 0]), Float(min(1, dt * 3)))
            if time - liftStart > 1.4, !dissolved {
                let bob = Float(sin((time - liftStart) * 1.7)) * 0.006
                card.position.y = cardHeight * 0.8 / 2 + 0.02 + bob
            }
        }
        if conceptFade >= 0, conceptFade < 1, let concept {
            conceptFade = min(1, conceptFade + Float(dt) / 1.6)
            concept.components.set(OpacityComponent(opacity: smoothstep(conceptFade)))
            card.model?.materials = card.model?.materials.map { _ in
                PaperPortal.cardMaterial(texture: cardTexture, alpha: 1 - 0.85 * smoothstep(conceptFade))
            } ?? []
        }
        if let d = dissolving, time - d.start > 0.35 {
            dissolving = nil
            setGlow(0)
            d.done()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.remove() }
        }
    }

    // MARK: Building blocks

    private lazy var cardTexture: TextureResource? = {
        try? TextureResource.generate(from: page.cutout ?? page.image, options: .init(semantic: .color))
    }()

    /// Where the card sits when it's still "part of the paper": flat, over the figure.
    private func flatTransform() -> Transform {
        var t = Transform()
        // Rotate the standing card (XY plane, facing +Z) to lie flat (XZ plane, facing up).
        t.rotation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        t.translation = [0, 0.002, 0]
        return t
    }

    private func setGlow(_ alpha: Float) {
        glow.model?.materials = [PaperPortal.glowMaterial(alpha: alpha)]
    }

    private func setEmission(_ rate: Float) {
        guard var e = sparkles.components[ParticleEmitterComponent.self] else { return }
        e.mainEmitter.birthRate = rate
        e.isEmitting = rate > 0
        sparkles.components.set(e)
    }

    private func burst() {
        let pop = Entity()
        var e = ParticleEmitterComponent.Presets.impact
        e.emitterShape = .sphere
        e.emitterShapeSize = [cardHeight * 0.4, cardHeight * 0.4, cardHeight * 0.4]
        PaperPortal.scaleToTabletop(&e)
        pop.components.set(e)
        pop.position = [0, cardHeight * 0.8 / 2 + 0.02, 0]
        anchor.addChild(pop)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { pop.removeFromParent() }
    }

    /// A card in the XY plane facing +Z, bottom edge at y = -height/2.
    static func makeCard(image: CGImage, width: Float, height: Float) -> ModelEntity {
        let w = width / 2, h = height / 2
        var d = MeshDescriptor(name: "card")
        let positions: [SIMD3<Float>] = [[-w, h, 0], [w, h, 0], [w, -h, 0], [-w, -h, 0]]
        let normals: [SIMD3<Float>] = Array(repeating: [0, 0, 1], count: 4)
        let uvs: [SIMD2<Float>] = [[0, 1], [1, 1], [1, 0], [0, 0]]
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        // RealityKit samples with v up (USD convention): the image's top row is v = 1.
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        // Both windings, so the card reads from behind too.
        d.primitives = .triangles([0, 3, 2, 0, 2, 1, 0, 2, 3, 0, 1, 2])
        let mesh = (try? MeshResource.generate(from: [d])) ?? .generatePlane(width: width, height: height)
        let texture = try? TextureResource.generate(from: image, options: .init(semantic: .color))
        return ModelEntity(mesh: mesh, materials: [cardMaterial(texture: texture, alpha: 1)])
    }

    static func cardMaterial(texture: TextureResource?, alpha: Float) -> UnlitMaterial {
        var m = UnlitMaterial()
        if let texture {
            m.color = .init(tint: .white, texture: .init(texture))
        } else {
            m.color = .init(tint: .white)
        }
        m.blending = .transparent(opacity: .init(scale: alpha))
        return m
    }

    static func glowMaterial(alpha: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: UIColor(red: 1.0, green: 0.78, blue: 0.45, alpha: 1))
        m.blending = .transparent(opacity: .init(scale: alpha))
        return m
    }
}

func smoothstep(_ x: Float) -> Float {
    let t = min(1, max(0, x))
    return t * t * (3 - 2 * t)
}
