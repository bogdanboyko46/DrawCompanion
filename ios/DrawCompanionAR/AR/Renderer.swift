import ARKit
import MetalKit

/// Draws the camera image and the outline with Metal: one full-screen view
/// on the phone, or two eyes for a headset viewer.
///
/// Headset: the scene (camera + outline) is rendered once into a square eye
/// texture covering each eye's field of view, then drawn into both halves of
/// the screen with barrel pre-distortion for the viewer's lenses (the camera
/// is a single lens, so both eyes get the same image). Lens, eye layout and
/// zoom come from `HeadsetOptics` (saved settings, else Cardboard defaults).
///
/// The scene is rendered with 4x MSAA; strokes are round-capped capsules with
/// exact per-sample coverage and a per-stroke stencil, so translucent lines
/// stay smooth and even. Buffers are reused; frames are drawn only when the
/// camera has a new image or something is animating.
final class Renderer: NSObject, MTKViewDelegate {
    /// What to draw this frame, supplied by the app.
    struct Scene {
        var headset: Bool
        var strokes: [Stroke]
        var style: InkStyle
        var progress: [CompletionTracker.StrokeState]?
        var fade: Float // 1 = fully visible, 0 = gone
    }

    var scene: () -> Scene = { Scene(headset: false, strokes: [], style: .fallback, progress: nil, fade: 1) }

    private static let sampleCount = 4
    private static let framesInFlight = 3

    private let session: ARSession
    private let controller: ARController
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let colorFormat: MTLPixelFormat
    private let cameraPipeline: MTLRenderPipelineState
    private let strokePipeline: MTLRenderPipelineState
    private let distortPipeline: MTLRenderPipelineState
    private let strokeStencil: MTLDepthStencilState
    private let noStencil: MTLDepthStencilState
    private var textureCache: CVMetalTextureCache!
    private let samplePositions: (SIMD4<Float>, SIMD4<Float>)

    // Reused every frame.
    private let inFlight = DispatchSemaphore(value: Renderer.framesInFlight)
    private var capsuleBuffers: [MTLBuffer?] = Array(repeating: nil, count: Renderer.framesInFlight)
    private var bufferIndex = 0
    private var capsules: [Capsule] = []
    private var batches: [(offset: Int, count: Int)] = []
    private var points: [SIMD2<Float>] = []
    private let scenePass = MTLRenderPassDescriptor()
    private let screenPass = MTLRenderPassDescriptor()

    // Render targets, recreated only when the size changes.
    private var msaaColor: MTLTexture?
    private var msaaStencil: MTLTexture?
    private var eyeTexture: MTLTexture?

    // Headset settings, re-read from UserDefaults now and then.
    private var optics = HeadsetOptics.cardboard
    private var opticsReadAt: CFTimeInterval = -.infinity
    private var layout: HeadsetOptics.Layout?
    private var layoutFor: (optics: HeadsetOptics, size: CGSize)?

    private var arrivals = HeadsetStrokes.Arrivals()
    private var lastFrameTimestamp: TimeInterval = -1
    private var animating = false
    private var stats = (since: CACurrentMediaTime(), frames: 0, cpu: 0.0)

    /// One piece of a stroke; matches `Capsule` in Shaders.metal.
    private struct Capsule {
        var ends: SIMD4<Float>   // a.xy, b.xy in render-target pixels
        var color: SIMD4<Float>
        var params: SIMD4<Float> // x = radius in pixels
    }

    private struct StrokeUniforms {
        var target: SIMD4<Float> // width, height, hasMask, 0
        var crop: SIMD4<Float>
        var samples0: SIMD4<Float>
        var samples1: SIMD4<Float>
    }

    private struct DistortUniforms {
        var lens: SIMD4<Float> // center x, y, pixels per tan, field tan
        var k: SIMD4<Float>    // k1, k2, edge softness, 0
    }

    private lazy var emptyMask: MTLTexture? = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        return device.makeTexture(descriptor: d)
    }()

    init?(view: MTKView, session: ARSession, controller: ARController) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.session = session
        self.controller = controller
        self.device = device
        self.queue = queue
        colorFormat = view.colorPixelFormat

        func pipeline(_ vertex: String, _ fragment: String, blend: Bool, scenePass: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            if scenePass {
                d.rasterSampleCount = Self.sampleCount
                d.stencilAttachmentPixelFormat = .stencil8
            }
            if blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                print("[DC] renderer: pipeline \(vertex)/\(fragment) failed: \(error)")
                return nil
            }
        }
        guard let camera = pipeline("cameraVertex", "cameraFragment", blend: false, scenePass: true),
              let stroke = pipeline("capsuleVertex", "capsuleFragment", blend: true, scenePass: true),
              let distort = pipeline("distortVertex", "distortFragment", blend: false, scenePass: false)
        else { return nil }
        cameraPipeline = camera
        strokePipeline = stroke
        distortPipeline = distort

        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .notEqual
        stencil.depthStencilPassOperation = .replace
        let strokeState = MTLDepthStencilDescriptor()
        strokeState.frontFaceStencil = stencil
        strokeState.backFaceStencil = stencil
        guard let strokeStencil = device.makeDepthStencilState(descriptor: strokeState),
              let noStencil = device.makeDepthStencilState(descriptor: MTLDepthStencilDescriptor()) else { return nil }
        self.strokeStencil = strokeStencil
        self.noStencil = noStencil

        var positions = [MTLSamplePosition](repeating: MTLSamplePosition(x: 0.5, y: 0.5), count: Self.sampleCount)
        device.getDefaultSamplePositions(&positions, count: Self.sampleCount)
        samplePositions = (SIMD4(positions[0].x, positions[0].y, positions[1].x, positions[1].y),
                           SIMD4(positions[2].x, positions[2].y, positions[3].x, positions[3].y))

        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        view.device = device

        let color = scenePass.colorAttachments[0]!
        color.loadAction = .clear
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        color.storeAction = .multisampleResolve
        scenePass.stencilAttachment.loadAction = .clear
        scenePass.stencilAttachment.clearStencil = 0
        scenePass.stencilAttachment.storeAction = .dontCare
        let screen = screenPass.colorAttachments[0]!
        screen.loadAction = .clear
        screen.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        screen.storeAction = .store
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // ARKit delivers 60 images a second; the screen may refresh at 120.
        // Draw when there's a new image (shown at the next refresh, not up to
        // a frame later) or something is moving.
        guard let frame = session.currentFrame,
              frame.timestamp != lastFrameTimestamp || animating else { return }
        let start = CACurrentMediaTime()
        inFlight.wait()
        guard let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer(),
              let y = texture(frame.capturedImage, plane: 0, format: .r8Unorm),
              let cbcr = texture(frame.capturedImage, plane: 1, format: .rg8Unorm) else {
            inFlight.signal()
            return
        }
        lastFrameTimestamp = frame.timestamp
        let scene = scene()
        let image = frame.camera.imageResolution
        // Person (hand) mask for this frame, when the phone supports it.
        let mask = frame.segmentationBuffer.flatMap { texture($0, plane: 0, format: .r8Unorm) }

        // Where the scene is rendered: the eye texture (headset) or the screen.
        let drawableSize = view.drawableSize
        let targetSize: CGSize
        let crop: CGRect
        let resolve: MTLTexture
        var headset: HeadsetOptics.Layout?
        if scene.headset, let layout = headsetLayout(drawable: drawableSize), let eye = eyeTexture(size: layout.eyeTextureSize) {
            headset = layout
            resolve = eye
            targetSize = CGSize(width: eye.width, height: eye.height)
            let c = optics.cameraCrop(imageAspect: Double(image.width / image.height))
            crop = CGRect(x: c.x, y: c.y, width: c.width, height: c.height)
        } else {
            resolve = drawable.texture
            targetSize = drawableSize
            crop = Self.fillCrop(view: drawableSize, image: image)
        }

        animating = scene.fade > 0 && scene.fade < 1
        buildCapsules(scene, frame: frame, image: image, crop: crop, target: targetSize)
        let buffer = upload()

        guard ensureTargets(width: Int(targetSize.width), height: Int(targetSize.height)) else {
            inFlight.signal()
            return
        }
        scenePass.colorAttachments[0].texture = msaaColor
        scenePass.colorAttachments[0].resolveTexture = resolve
        scenePass.stencilAttachment.texture = msaaStencil
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else {
            inFlight.signal()
            return
        }
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(targetSize.width),
                                        height: Double(targetSize.height), znear: 0, zfar: 1))
        var cropVector = SIMD4<Float>(Float(crop.minX), Float(crop.minY), Float(crop.maxX), Float(crop.maxY))
        encoder.setRenderPipelineState(cameraPipeline)
        encoder.setDepthStencilState(noStencil)
        encoder.setVertexBytes(&cropVector, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(y), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(cbcr), index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        if let buffer, !batches.isEmpty {
            var uniforms = StrokeUniforms(
                target: SIMD4(Float(targetSize.width), Float(targetSize.height), mask == nil ? 0 : 1, 0),
                crop: cropVector, samples0: samplePositions.0, samples1: samplePositions.1)
            encoder.setRenderPipelineState(strokePipeline)
            encoder.setDepthStencilState(strokeStencil)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<StrokeUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<StrokeUniforms>.stride, index: 0)
            encoder.setFragmentTexture(mask.flatMap(CVMetalTextureGetTexture) ?? emptyMask, index: 0)
            for (k, batch) in batches.enumerated() {
                encoder.setVertexBufferOffset(batch.offset * MemoryLayout<Capsule>.stride, index: 0)
                encoder.setStencilReferenceValue(UInt32(k % 255 + 1))
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: batch.count)
            }
        }
        encoder.endEncoding()

        if let layout = headset {
            if resolve.mipmapLevelCount > 1, let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: resolve)
                blit.endEncoding()
            }
            screenPass.colorAttachments[0].texture = drawable.texture
            if let screen = commandBuffer.makeRenderCommandEncoder(descriptor: screenPass) {
                screen.setRenderPipelineState(distortPipeline)
                screen.setFragmentTexture(resolve, index: 0)
                for eye in layout.eyes {
                    screen.setViewport(MTLViewport(originX: eye.x, originY: eye.y, width: eye.width, height: eye.height,
                                                   znear: 0, zfar: 1))
                    var uniforms = DistortUniforms(
                        lens: SIMD4(Float(eye.centerX), Float(eye.centerY), Float(layout.pixelsPerTan), Float(optics.fieldTan)),
                        k: SIMD4(Float(optics.appliedK1), Float(optics.appliedK2), 0.03, 0))
                    screen.setFragmentBytes(&uniforms, length: MemoryLayout<DistortUniforms>.stride, index: 0)
                    screen.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                screen.endEncoding()
            }
        }

        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in
            _ = (y, cbcr, mask) // keep the camera textures alive until the GPU is done
            semaphore.signal()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        logStats(cpu: CACurrentMediaTime() - start)
    }

    // MARK: layout

    /// Phone view: fill the screen with the camera image, cropping whichever
    /// dimension overflows. Normalized image coordinates.
    static func fillCrop(view: CGSize, image: CGSize) -> CGRect {
        let imageAspect = image.width / image.height
        let viewAspect = view.width / view.height
        return viewAspect > imageAspect
            ? CGRect(x: 0, y: (1 - imageAspect / viewAspect) / 2, width: 1, height: imageAspect / viewAspect)
            : CGRect(x: (1 - viewAspect / imageAspect) / 2, y: 0, width: viewAspect / imageAspect, height: 1)
    }

    private func headsetLayout(drawable: CGSize) -> HeadsetOptics.Layout? {
        let now = CACurrentMediaTime()
        if now - opticsReadAt > 0.5 { // cheap, and lets Settings changes show up live
            optics = HeadsetOptics(defaults: .standard)
            opticsReadAt = now
        }
        guard drawable.width > 0, drawable.height > 0 else { return nil }
        if layout == nil || layoutFor?.optics != optics || layoutFor?.size != drawable {
            let l = optics.layout(screenWidth: Double(drawable.width), screenHeight: Double(drawable.height))
            layout = l
            layoutFor = (optics, drawable)
            print("[DC] headset: screen \(Int(drawable.width))x\(Int(drawable.height)), eye texture \(l.eyeTextureSize)px, "
                + "lens centers x \(Int(l.eyes[0].centerX)) / \(Int(l.eyes[1].centerX)), y \(Int(l.eyes[0].centerY)), "
                + "k1 \(optics.appliedK1) k2 \(optics.appliedK2), zoom \(optics.zoom), fov ±\(optics.fieldOfViewDegrees)°")
        }
        return layout
    }

    private func eyeTexture(size: Int) -> MTLTexture? {
        if let t = eyeTexture, t.width == size { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: size, height: size, mipmapped: true)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        eyeTexture = device.makeTexture(descriptor: d)
        return eyeTexture
    }

    /// The 4x multisample color and stencil the scene is drawn into. They
    /// live only in tile memory (memoryless) and resolve into the target.
    private func ensureTargets(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        if let c = msaaColor, c.width == width, c.height == height, msaaStencil != nil { return true }
        func make(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = .type2DMultisample
            d.sampleCount = Self.sampleCount
            d.usage = .renderTarget
            d.storageMode = .memoryless
            return device.makeTexture(descriptor: d)
        }
        msaaColor = make(colorFormat)
        msaaStencil = make(.stencil8)
        return msaaColor != nil && msaaStencil != nil
    }

    // MARK: outline geometry

    /// Per role: thickness relative to the drawing's own lines, opacity, and
    /// dash pattern (on, off in multiples of the line width; 0 = solid).
    private static func roleStyle(_ role: StrokeRole) -> (width: Float, alpha: Float, dashOn: Float, dashOff: Float) {
        switch role {
        case .construction: return (0.6, 0.35, 4, 3)
        case .contour: return (1, 0.85, 0, 0)
        case .detail: return (0.75, 0.75, 0, 0)
        case .shading: return (0.5, 0.45, 1, 2)
        }
    }

    private static func weightScale(_ weight: StrokeWeight) -> Float {
        switch weight {
        case .light: return 0.8
        case .medium: return 1
        case .bold: return 1.3
        }
    }

    /// Fills `capsules` and `batches` (one batch per stroke) in render-target pixels.
    private func buildCapsules(_ scene: Scene, frame: ARFrame, image: CGSize, crop: CGRect, target: CGSize) {
        capsules.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
        let now = CACurrentMediaTime()
        arrivals.update(scene.strokes, now: now)
        guard scene.fade > 0, !scene.strokes.isEmpty else { return }

        let camera = frame.camera
        let viewMatrix = camera.transform.inverse
        func project(_ p: PaperPoint) -> CGPoint? {
            guard let world = controller.world(p) else { return nil }
            guard (viewMatrix * SIMD4(world, 1)).z < -0.01 else { return nil } // behind the camera
            return camera.projectPoint(world, orientation: .landscapeRight, viewportSize: image)
        }
        // Camera-image pixel -> render-target pixel.
        let sx = Float(target.width / (crop.width * image.width)), sy = Float(target.height / (crop.height * image.height))
        let ox = Float(crop.minX * image.width), oy = Float(crop.minY * image.height)
        func toTarget(_ p: CGPoint) -> SIMD2<Float> { SIMD2((Float(p.x) - ox) * sx, (Float(p.y) - oy) * sy) }
        // The drawing's own ink color, as the camera sees it.
        let ink = SIMD3(scene.style.red, scene.style.green, scene.style.blue)

        for (i, stroke) in scene.strokes.enumerated() {
            let role = Self.roleStyle(stroke.role)
            let progress = scene.progress.flatMap { i < $0.count ? $0[i] : nil }
            // Traced strokes step back so the untraced ones stand out.
            let traced: Float = progress.map { $0.done ? 0.3 : 1 - 0.5 * Float($0.progress) } ?? 1
            let arrival = arrivals.progress(i, now: now)
            if arrival < 1 { animating = true }
            let alpha = role.alpha * traced * scene.fade * HeadsetStrokes.Arrivals.opacity(arrival)
            guard alpha > 0.002, let first = stroke.points.first else { continue }

            // Image pixels per paper unit near the stroke, so line widths are
            // real thicknesses on the paper as you move closer or farther.
            var scale: Float = 1
            if let a = project(first), let b = project(PaperPoint(x: first.x + 20, y: first.y)) {
                scale = Float(hypot(b.x - a.x, b.y - a.y)) / 20
            }
            let paperWidth = Float(scene.style.width) * role.width * Self.weightScale(stroke.weight)
            let width = max(1.5, paperWidth * scale * sx) // at least a visible hairline

            points.removeAll(keepingCapacity: true)
            for p in stroke.points {
                if let q = project(p) { points.append(toTarget(q)) }
            }
            if stroke.closed, points.count > 2, let start = points.first { points.append(start) }
            let unit = max(width, 3)
            let dash: (on: Float, off: Float)? = role.dashOn > 0 ? (role.dashOn * unit, role.dashOff * unit) : nil
            let color = SIMD4(ink, alpha)
            let params = SIMD4<Float>(width / 2, 0, 0, 0)
            let begin = capsules.count
            HeadsetStrokes.forEachPiece(points, dash: dash, reveal: HeadsetStrokes.Arrivals.reveal(arrival)) { a, b in
                capsules.append(Capsule(ends: SIMD4(a.x, a.y, b.x, b.y), color: color, params: params))
            }
            if capsules.count > begin { batches.append((begin, capsules.count - begin)) }
        }
    }

    /// Copies `capsules` into this frame's buffer of the ring, growing it if needed.
    private func upload() -> MTLBuffer? {
        guard !capsules.isEmpty else { return nil }
        bufferIndex = (bufferIndex + 1) % Self.framesInFlight
        let bytes = capsules.count * MemoryLayout<Capsule>.stride
        if (capsuleBuffers[bufferIndex]?.length ?? 0) < bytes {
            var size = 64 * 1024
            while size < bytes { size *= 2 }
            capsuleBuffers[bufferIndex] = device.makeBuffer(length: size, options: .storageModeShared)
        }
        guard let buffer = capsuleBuffers[bufferIndex] else { return nil }
        capsules.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        return buffer
    }

    // MARK: helpers

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format,
            CVPixelBufferIsPlanar(buffer) ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer),
            CVPixelBufferIsPlanar(buffer) ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer),
            plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    /// Every 10 s: frames drawn per second and CPU time per frame.
    private func logStats(cpu: Double) {
        stats.frames += 1
        stats.cpu += cpu
        let now = CACurrentMediaTime()
        guard now - stats.since >= 10 else { return }
        let fps = Double(stats.frames) / (now - stats.since)
        print(String(format: "[DC] render: %.0f fps drawn, %.2f ms CPU per frame, %ld capsules",
                     fps, stats.cpu / Double(stats.frames) * 1000, capsules.count))
        stats = (now, 0, 0)
    }
}
