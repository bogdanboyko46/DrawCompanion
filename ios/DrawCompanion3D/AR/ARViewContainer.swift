import RealityKit
import SwiftUI

struct ARViewContainer: UIViewRepresentable {
    let scene: SceneController

    func makeUIView(context: Context) -> ARView { scene.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
