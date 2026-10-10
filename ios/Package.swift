// swift-tools-version:5.9
// Builds the app's platform-independent logic (DrawCompanionAR/Core) on its
// own so it can be unit-tested on a Mac: `swift test --package-path ios`.
import PackageDescription

let package = Package(
    name: "DrawCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    targets: [
        .target(name: "DrawCore", path: "DrawCompanionAR/Core"),
        .testTarget(name: "DrawCoreTests", dependencies: ["DrawCore"], path: "CoreTests"),
    ]
)
