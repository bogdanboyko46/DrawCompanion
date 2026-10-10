import MetalKit
import SwiftUI

/// The camera with the outline on top, drawn by `Renderer`.
struct CameraView: UIViewRepresentable {
    @EnvironmentObject var model: AppModel

    final class Coordinator {
        var renderer: Renderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.backgroundColor = .black
        let model = self.model
        let renderer = Renderer(view: view, session: model.ar.session, controller: model.ar)
        renderer?.scene = { [weak model] in
            MainActor.assumeIsolated { model?.scene() } ?? Renderer.Scene(headset: false, strokes: [], style: .fallback, progress: nil, fade: 1)
        }
        view.delegate = renderer
        context.coordinator.renderer = renderer
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}
