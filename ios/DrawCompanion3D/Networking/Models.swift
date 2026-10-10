import Foundation

/// A drawing-to-character job, as the companion server reports it
/// (`server/character/store.js` → `publicJob`).
struct CharacterJob: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var status: Status
    var stage: String
    var message: String
    var progress: Double
    var stageProgress: Double?
    var error: String?
    var createdAt: String
    var drawingUrl: String
    var conceptUrl: String?
    var thumbnailUrl: String?
    var character: CharacterInfo?
    var model: ModelInfo?

    enum Status: String, Codable, Sendable {
        case queued, running, ready, failed

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .running
        }
    }

    var displayName: String { character?.name ?? "New character" }
}

struct CharacterInfo: Codable, Equatable, Sendable {
    var name: String
    var summary: String
    var greeting: String
    var bodyPlan: String
    var heightMeters: Double
    var figureBox: Box
    var colors: [Swatch]
    var personality: Personality
}

struct Box: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

struct Swatch: Codable, Equatable, Sendable, Hashable {
    var hex: String
    var part: String
    var fromDrawing: Bool?

    enum CodingKeys: String, CodingKey {
        case hex, part
        case fromDrawing = "from_drawing"
    }
}

struct Personality: Codable, Equatable, Sendable {
    var traits: [String]
    /// 0 calm … 1 hyper.
    var energy: Double
    /// 0 shy … 1 outgoing.
    var friendliness: Double

    static let neutral = Personality(traits: [], energy: 0.5, friendliness: 0.6)
}

struct ModelInfo: Codable, Equatable, Sendable {
    var url: String
    var animated: Bool
    var clips: [Clip]
}

/// One animation clip inside the character's single USDZ timeline.
struct Clip: Codable, Equatable, Hashable, Sendable {
    var name: String
    var start: Double
    var end: Double
    var loop: Bool

    var duration: Double { max(0.05, end - start) }
}

/// The server's pipeline stages, in order, with what the app shows for each.
enum GenerationStage: String, CaseIterable, Identifiable {
    case read, concept, review, sculpt, rig, animate, package

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: "Studying your drawing"
        case .concept: "Painting a 3D concept"
        case .review: "Checking it matches"
        case .sculpt: "Sculpting in 3D"
        case .rig: "Building a skeleton"
        case .animate: "Teaching it to move"
        case .package: "Bringing it to life"
        }
    }

    var symbol: String {
        switch self {
        case .read: "eye"
        case .concept: "paintbrush.pointed"
        case .review: "checkmark.seal"
        case .sculpt: "cube.transparent"
        case .rig: "figure.stand"
        case .animate: "figure.walk"
        case .package: "sparkles"
        }
    }
}
