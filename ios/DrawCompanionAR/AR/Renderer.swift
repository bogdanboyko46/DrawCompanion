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
        var progress: [CompletionTracker.StrokeState]?
        var fade: Float // 1 = fully visible, 0 = gone
    }

    /// Fraction of the camera image's height each eye shows in the headset.
    static let headsetZoom: CGFloat = 1.6

    var scene: () -> Scene = { Scene(headset: false, strokes: [], progress: nil, fade: 1) }

    private let session: ARSession
    private let controller: ARController
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let cameraPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache!

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
        // Outline points in camera-image pixels, computed once for both eyes.
        let projected: [[CGPoint?]] = scene.strokes.map { stroke in
            stroke.points.map { p in controller.world(p).flatMap { ARController.project($0, camera: frame.camera) } }
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

            let vertices = outlineVertices(scene, projected, image: image, viewport: vp)
            if !vertices.isEmpty, let buffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<LineVertex>.stride * vertices.count, options: []) {
                encoder.setRenderPipelineState(linePipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            }
        }
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { _ in _ = (y, cbcr) } // keep the camera textures alive until the GPU is done
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

    private static let roleStyle: [StrokeRole: (width: Float, dash: [Float], alpha: Float)] = [
        .construction: (1.5, [6, 5], 0.6),
        .contour: (3, [], 1),
        .detail: (2, [], 0.9),
        .shading: (1.5, [2, 4], 0.7),
    ]
    private static let weightScale: [StrokeWeight: Float] = [.light: 0.75, .medium: 1, .bold: 1.4]
    private static let ink = SIMD3<Float>(0.1, 0.76, 1) // bright cyan reads on paper and on pencil

    private func outlineVertices(_ scene: Scene, _ projected: [[CGPoint?]], image: CGSize, viewport vp: Viewport) -> [LineVertex] {
        guard scene.fade > 0 else { return [] }
        let unit = Float(vp.rect.height) / 360 // line widths scale with the view
        // Camera-image pixel -> viewport pixel.
        func toView(_ p: CGPoint) -> SIMD2<Float> {
            SIMD2(Float((p.x / image.width - vp.crop.minX) / vp.crop.width * vp.rect.width),
                  Float((p.y / image.height - vp.crop.minY) / vp.crop.height * vp.rect.height))
        }
        // Viewport pixel -> clip space.
        func clip(_ p: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(p.x / Float(vp.rect.width) * 2 - 1, 1 - p.y / Float(vp.rect.height) * 2)
        }

        var out: [LineVertex] = []
        for (i, stroke) in scene.strokes.enumerated() {
            let style = Self.roleStyle[stroke.role] ?? (3, [], 1)
            let progress = scene.progress.flatMap { i < $0.count ? $0[i] : nil }
            // Traced strokes step back so the untraced ones stand out.
            let traced: Float = progress.map { $0.done ? 0.3 : 1 - 0.5 * Float($0.progress) } ?? 1
            let alpha = style.alpha * traced * scene.fade
            let width = style.width * (Self.weightScale[stroke.weight] ?? 1) * unit
            var pts = projected[i].compactMap { $0.map(toView) }
            if stroke.closed, let first = pts.first { pts.append(first) }
            guard pts.count >= 2 else { continue }
            let pieces = dashed(pts, pattern: style.dash.map { $0 * unit })
            // Dark halo first so the line reads on both light paper and dark ink.
            for piece in pieces { addPolyline(piece, width: width + 2.5 * unit, color: SIMD4(0, 0, 0, alpha * 0.55), clip: clip, into: &out) }
            for piece in pieces { addPolyline(piece, width: width, color: SIMD4(Self.ink, alpha), clip: clip, into: &out) }
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
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }
}
