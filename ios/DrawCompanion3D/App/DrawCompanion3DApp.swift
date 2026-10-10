import SwiftUI

@main
struct DrawCompanion3DApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}
