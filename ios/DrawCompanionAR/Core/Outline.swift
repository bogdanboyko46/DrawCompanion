import Foundation

// Shared types. Everything in Core/ is plain Swift + Foundation so it also
// builds as a Swift package (ios/Package.swift) for unit tests on a Mac.

/// A point on the page in paper units: the page is 1000 wide, origin at the
/// top-left corner, x right, y down (toward the person drawing).
struct PaperPoint: Equatable, Codable {
    var x: Double
    var y: Double
}

struct PaperSize: Equatable {
    var w: Double
    var h: Double

    static let width: Double = 1000
    /// A page of the given real-world proportions (height / width).
    init(aspect: Double) {
        w = Self.width
        h = (Self.width * aspect).rounded()
    }

    init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }
}

enum StrokeRole: String, Codable, CaseIterable {
    case construction, contour, detail, shading
}

enum StrokeWeight: String, Codable, CaseIterable {
    case light, medium, bold
}

/// One line of an outline. `d` is the compact path data the model wrote
/// (sent back to it for revisions); `points` is that path flattened for
/// drawing and tracking.
struct Stroke: Equatable {
    var role: StrokeRole
    var weight: StrokeWeight
    var d: String
    var closed: Bool
    var points: [PaperPoint]
}

/// The outline on the page and the requests that produced it.
struct Outline: Equatable {
    var strokes: [Stroke]
    var history: [String]
    /// The look of the user's drawing, so the outline can match it.
    var style: InkStyle = .fallback
}

/// What the AI decided to do with what the user said.
enum TurnAction: String, Codable {
    case new, revise, hide, ignore
}

enum TurnEvent: Equatable {
    case action(TurnAction)
    case stroke(Stroke)
    case done
}
