import ARKit
import MetalKit

/// Draws the camera image and the outline with Metal: one full-screen view
/// on the phone, or two side-by-side views for a headset viewer (the camera
/// is a single lens, so both eyes get the same image).
final class Renderer: NSObject, MTKViewDelegate {
    /// What to draw this frame, supplied by the app.
    struct Scene {
        var headset: Bool
        var strokes: [Stroke]
        var style: InkStyle
        var progress: [CompletionTracker.StrokeState]?
        var fade: Float // 1 = fully visible, 0 = gone
    }

    /// Fraction of the camera image's height each eye shows in the headset.
    static let headsetZoom: CGFloat = 1.6

    var scene: () -> Scene = { Scene(headset: false, strokes: [], style: .fallback, progress: nil, fade: 1) }

    private let session: ARSession
    private let controller: ARController
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let cameraPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache!

    private struct LineUniforms {
        var viewport: SIMD4<Float>
        var crop: SIMD4<Float>
        var hasMask: Float
    }

    private lazy var emptyMask: MTLTexture? = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        return device.makeTexture(descriptor: d)
    }()

    private struct LineVertex {
        var position: SIMD2<Float>
        var pad = SIMD2<Float>(0, 0) // matches Metal's float2 + float4 layout
        var color: SIMD4<Float>
    }

    init?(view: MTKView, session: ARSession, controller: ARController) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.session = session
        self.controller = controller
        self.device = device
        self.queue = queue

        func pipeline(_ vertex: String, _ fragment: String, blend: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            if blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let camera = pipeline("cameraVertex", "cameraFragment", blend: false),
              let line = pipeline("lineVertex", "lineFragment", blend: true) else { return nil }
        cameraPipeline = camera
        linePipeline = line
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        view.device = device
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let frame = session.currentFrame,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer(),
              let y = texture(frame.capturedImage, plane: 0, format: .r8Unorm),
              let cbcr = texture(frame.capturedImage, plane: 1, format: .rg8Unorm),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let scene = scene()
        let image = frame.camera.imageResolution
        // Person (hand) mask for this frame, when the phone supports it.
        let mask = frame.segmentationBuffer.flatMap { texture($0, plane: 0, format: .r8Unorm) }
        // Outline points in camera-image pixels, computed once for both eyes.
        let projected: [[CGPoint?]] = scene.strokes.map { stroke in
            stroke.points.map { p in controller.world(p).flatMap { ARController.project($0, camera: frame.camera) } }
        }
        // Image pixels per paper unit near each stroke, so line widths are real
        // thicknesses on the paper and stay right as you move closer or farther.
        let scale: [Float] = scene.strokes.map { stroke in
            guard let p = stroke.points.first,
                  let a = controller.world(p).flatMap({ ARController.project($0, camera: frame.camera) }),
                  let b = controller.world(PaperPoint(x: p.x + 20, y: p.y)).flatMap({ ARController.project($0, camera: frame.camera) })
            else { return 1 }
            return Float(hypot(b.x - a.x, b.y - a.y)) / 20
        }

        for vp in viewports(drawable: view.drawableSize, image: image, headset: scene.headset) {
            encoder.setViewport(MTLViewport(originX: Double(vp.rect.minX), originY: Double(vp.rect.minY),
                                            width: Double(vp.rect.width), height: Double(vp.rect.height), znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: Int(vp.rect.minX), y: Int(vp.rect.minY),
                                                  width: Int(vp.rect.width), height: Int(vp.rect.height)))
            encoder.setRenderPipelineState(cameraPipeline)
            var crop = SIMD4<Float>(Float(vp.crop.minX), Float(vp.crop.minY), Float(vp.crop.maxX), Float(vp.crop.maxY))
            encoder.setVertexBytes(&crop, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(y), index: 0)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(cbcr), index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

            let vertices = outlineVertices(scene, projected, scale, image: image, viewport: vp)
            if !vertices.isEmpty, let buffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<LineVertex>.stride * vertices.count, options: []) {
                encoder.setRenderPipelineState(linePipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                var uniforms = LineUniforms(
                    viewport: SIMD4(Float(vp.rect.minX), Float(vp.rect.minY), Float(vp.rect.width), Float(vp.rect.height)),
                    crop: crop,
                    hasMask: mask == nil ? 0 : 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LineUniforms>.stride, index: 0)
                encoder.setFragmentTexture(mask.flatMap(CVMetalTextureGetTexture) ?? emptyMask, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            }
        }
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { _ in _ = (y, cbcr, mask) } // keep the camera textures alive until the GPU is done
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: layout

    struct Viewport {
        var rect: CGRect // drawable pixels
        var crop: CGRect // normalized camera-image coordinates shown in it
    }

    func viewports(drawable: CGSize, image: CGSize, headset: Bool) -> [Viewport] {
        let imageAspect = image.width / image.height
        if !headset {
            // Fill the screen, cropping whichever dimension overflows.
            let viewAspect = drawable.width / drawable.height
            let crop = viewAspect > imageAspect
                ? CGRect(x: 0, y: (1 - imageAspect / viewAspect) / 2, width: 1, height: imageAspect / viewAspect)
                : CGRect(x: (1 - viewAspect / imageAspect) / 2, y: 0, width: viewAspect / imageAspect, height: 1)
            return [Viewport(rect: CGRect(origin: .zero, size: drawable), crop: crop)]
        }
        let eye = CGSize(width: drawable.width / 2, height: drawable.height)
        var h = 1 / Self.headsetZoom
        var w = h * (eye.width / eye.height) / imageAspect
        if w > 1 { h /= w; w = 1 }
        let crop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
        return [0, 1].map { Viewport(rect: CGRect(x: CGFloat($0) * eye.width, y: 0, width: eye.width, height: eye.height), crop: crop) }
    }

    // MARK: outline geometry

    /// Per role: thickness relative to the drawing's own lines, opacity, and
    /// dash pattern (in multiples of the line width).
    private static let roleStyle: [StrokeRole: (width: Float, alpha: Float, dash: [Float])] = [
        .construction: (0.6, 0.35, [4, 3]),
        .contour: (1, 0.85, []),
        .detail: (0.75, 0.75, []),
        .shading: (0.5, 0.45, [1, 2]),
    ]
    private static let weightScale: [StrokeWeight: Float] = [.light: 0.8, .medium: 1, .bold: 1.3]

    private func outlineVertices(_ scene: Scene, _ projected: [[CGPoint?]], _ scale: [Float], image: CGSize,
                                 viewport vp: Viewport) -> [LineVertex] {
        guard scene.fade > 0 else { return [] }
        // Camera-image pixel -> viewport pixel.
        let zoom = Float(vp.rect.width / (vp.crop.width * image.width))
        func toView(_ p: CGPoint) -> SIMD2<Float> {
            SIMD2(Float((p.x / image.width - vp.crop.minX) / vp.crop.width * vp.rect.width),
                  Float((p.y / image.height - vp.crop.minY) / vp.crop.height * vp.rect.height))
        }
        // Viewport pixel -> clip space.
        func clip(_ p: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(p.x / Float(vp.rect.width) * 2 - 1, 1 - p.y / Float(vp.rect.height) * 2)
        }
        // The drawing's own ink color, as the camera sees it.
        let ink = SIMD3(scene.style.red, scene.style.green, scene.style.blue)

        var out: [LineVertex] = []
        for (i, stroke) in scene.strokes.enumerated() {
            let role = Self.roleStyle[stroke.role] ?? (1, 0.85, [])
            let progress = scene.progress.flatMap { i < $0.count ? $0[i] : nil }
            // Traced strokes step back so the untraced ones stand out.
            let traced: Float = progress.map { $0.done ? 0.3 : 1 - 0.5 * Float($0.progress) } ?? 1
            let alpha = role.alpha * traced * scene.fade
            let paperWidth = Float(scene.style.width) * role.width * (Self.weightScale[stroke.weight] ?? 1)
            let width = max(1.5, paperWidth * scale[i] * zoom) // at least a visible hairline
            var pts = projected[i].compactMap { $0.map(toView) }
            if stroke.closed, let first = pts.first { pts.append(first) }
            guard pts.count >= 2 else { continue }
            for piece in dashed(pts, pattern: role.dash.map { $0 * max(width, 3) }) {
                addPolyline(piece, width: width, color: SIMD4(ink, alpha), clip: clip, into: &out)
            }
        }
        return out
    }

    /// Splits a polyline into dashes (or returns it whole if there's no pattern).
    private func dashed(_ pts: [SIMD2<Float>], pattern: [Float]) -> [[SIMD2<Float>]] {
        guard pattern.count == 2, pattern[0] > 0, pattern[1] > 0 else { return [pts] }
        var pieces: [[SIMD2<Float>]] = []
        var current: [SIMD2<Float>] = [pts[0]]
        var on = true
        var left = pattern[0]
        for k in 1..<pts.count {
            var a = pts[k - 1]
            let b = pts[k]
            var seg = simd_distance(a, b)
            while seg > left {
                let p = a + (b - a) * (left / seg)
                if on { current.append(p); pieces.append(current) } else { current = [p] }
                seg -= left
                a = p
                on.toggle()
                left = on ? pattern[0] : pattern[1]
            }
            left -= seg
            if on { current.append(b) }
        }
        if on, current.count >= 2 { pieces.append(current) }
        return pieces
    }

    /// Thick line as triangles, with a small square at each joint to hide gaps.
    private func addPolyline(_ pts: [SIMD2<Float>], width: Float, color: SIMD4<Float>,
                             clip: (SIMD2<Float>) -> SIMD2<Float>, into out: inout [LineVertex]) {
        let half = width / 2
        func quad(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) {
            for p in [a, b, c, b, d, c] { out.append(LineVertex(position: clip(p), color: color)) }
        }
        for k in 1..<pts.count {
            let a = pts[k - 1], b = pts[k]
            let len = simd_distance(a, b)
            guard len > 0.01 else { continue }
            let dir = (b - a) / len
            let n = SIMD2(-dir.y, dir.x) * half
            quad(a + n, a - n, b + n, b - n)
        }
        for p in pts {
            let s = SIMD2<Float>(half, half) * 0.7
            quad(p + SIMD2(-s.x, -s.y), p + SIMD2(s.x, -s.y), p + SIMD2(-s.x, s.y), p + SIMD2(s.x, s.y))
        }
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format,
            CVPixelBufferIsPlanar(buffer) ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer),
            CVPixelBufferIsPlanar(buffer) ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer),
            plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }
}
