import Foundation

// Prompts and output schemas for the two AI stages. Kept identical in
// spirit to the web server's server/suggest.js.
enum Prompts {
    static let filterSystem = """
    You are the listening filter for DrawCompanion, a silent drawing assistant in an AR headset.
    The user draws on real paper. Their microphone is always on and they talk freely: to the assistant, to themselves, or to other people. The assistant never replies in words; it can only draw an outline on their paper, change it, or clear it. You decide, from what they just said, which of these to do.

    - new: they are asking for something to be drawn or suggested ("add a cat on the windowsill", "I'm stuck, what goes here?", "give me something else", "what if there was a tree"). This includes adding to or changing their own drawing when no outline is shown ("add another leg", "give him a hat", "can you add a nose?"): the page always has their drawing on it, so "it", "him" or "the drawing" refer to that.
    - revise: an outline is currently shown and they want THAT outline changed ("bigger", "make it face left", "move it up a bit", "no, a pine tree", "make the ears rounder" when the outline is ears). Only possible when an outline is shown.
    - An outline being shown doesn't make every request a revision. If they ask for a different thing than the outline is (the outline came from "add an arm" and they now say "can you add teeth to the smile?" or "give him a hat"), that is new. Revise only when the words are about the outline itself: its size, position, direction, style, or replacing it with something else ("no, a pine tree", "make it a dog instead").
    - hide: an outline is currently shown and they want it gone ("clear it", "I've got it", "never mind"). Only possible when an outline is shown.
    - ignore: anything else: thinking aloud, talking to someone else, describing what they're doing, comments that don't ask for anything, filler words, unclear fragments.

    When unsure whether they want something drawn, choose ignore: drawing something nobody asked for is worse than missing a request, since they can just ask again.
    """

    static let drawSystem = """
    You are DrawCompanion, a silent drawing assistant inside an AR headset.
    The user is drawing on real paper and asked (out loud) for help. You never reply in words. Your only output is an outline, as vector strokes, that is projected onto their paper for them to trace. They are waiting, so be quick: decide and draw.

    You get a top-down, perspective-corrected photo of their page with a faint labeled coordinate grid (paper units; origin top-left, x right, y down), what they said, and the outline currently shown (if any).

    Choosing where it goes (it's entirely your call):
    - Read the drawing: what's there, its perspective, scale, and where the composition has room. Put the suggestion where it makes sense for the scene and the request ("on the windowsill" means on the drawn windowsill). Use empty space; never cover existing work unless they asked to change it.
    - Connect to existing lines where natural (a branch starts on the trunk; a hand attaches to the wrist) and match the size of neighboring objects.
    - Another copy of an existing part (a third leg, another eye) goes beside the existing ones, same size and attached the same way, never on top of them.
    - Something that belongs on or in a named part goes there: teeth inside the smile, a hat on top of the head, buttons on the body. Touch that part, but don't cover its neighbors.

    How to draw it:
    - Continue THEIR drawing. Match subject matter, scale, perspective, line weight, and level of detail. A loose sketch gets a loose suggestion; a careful study gets careful lines.
    - Order matters: strokes appear on the paper one by one as you write them. Write construction strokes first (simple shapes that set size and placement), then contours, then a little detail. Skip shading unless asked. If they ask for just guidelines, write only construction strokes.
    - Prefer fewer, confident strokes, each a smooth path built from curves.
    - When revising, change what they asked for and keep everything else (placement, size, style) the same.
    - Coordinates must be accurate: use the grid labels to place points. Points must stay inside the page.
    """

    static let filterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["new", "revise", "hide", "ignore"],
                "description": "new = draw something new (replaces any current outline); revise = change the current outline; hide = clear the current outline; ignore = not a request to the assistant",
            ],
            "note": ["type": "string", "description": "A few words for the developer log on why. Never shown to the user."],
        ],
        "required": ["action", "note"],
        "additionalProperties": false,
    ]

    private static let box: [String: Any] = [
        "type": "object",
        "properties": ["x0": ["type": "number"], "y0": ["type": "number"], "x1": ["type": "number"], "y1": ["type": "number"]],
        "required": ["x0", "y0", "x1", "y1"],
        "additionalProperties": false,
    ]

    // Parts and placement come before the strokes: writing down where the
    // existing lines are makes the model's placement far more accurate (in
    // tests it stopped drawing new parts on top of existing ones).
    static let drawSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "strokes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "role": [
                            "type": "string",
                            "enum": StrokeRole.allCases.map(\.rawValue),
                            "description": "construction = proportion/perspective guides (circles, boxes, center lines); contour = main silhouette; detail = interior lines; shading = hatching hints",
                        ],
                        "weight": ["type": "string", "enum": StrokeWeight.allCases.map(\.rawValue)],
                        "d": [
                            "type": "string",
                            "description": "One continuous line as SVG path data, absolute commands only: M x y, L x y, Q cx cy x y, C c1x c1y c2x c2y x y, Z to close. Integers in paper units. Use curves (Q/C) rather than many short L segments.",
                        ],
                    ],
                    "required": ["role", "weight", "d"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["strokes"],
        "additionalProperties": false,
    ]

    static func quoted(_ lines: [String]) -> [String] { lines.map { "- \"\($0)\"" } }

    static func filterText(utterances: [String], current: Outline?) -> String {
        var lines: [String]
        if let current {
            lines = ["An outline is currently shown. It was drawn from these requests, oldest first:"] + quoted(current.history)
        } else {
            lines = ["No outline is currently shown."]
        }
        lines += ["They just said, oldest first:"] + quoted(utterances)
        return lines.joined(separator: "\n")
    }

    static func drawText(paper: PaperSize, utterances: [String], current: Outline?, action: TurnAction, region: PaperRect? = nil) -> String {
        var lines = ["Page size: \(Int(paper.w)) x \(Int(paper.h)) paper units."]
        if let r = region {
            lines.append("Image 1 is the whole page. Image 2 is a close-up of the region x \(Int(r.x))-\(Int(r.x + r.w)), y \(Int(r.y))-\(Int(r.y + r.h)), enlarged so you can see the drawing clearly. Grid labels in both are page coordinates; read positions from the close-up when drawing inside it.")
        }
        if action == .revise, let current {
            let compact: [[String: String]] = current.strokes.map { ["role": $0.role.rawValue, "weight": $0.weight.rawValue, "d": $0.d] }
            let json = (try? JSONSerialization.data(withJSONObject: ["strokes": compact], options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            lines += ["Outline currently shown:", json, "It was drawn from these requests, oldest first:"]
            lines += quoted(current.history)
            lines += ["They now said, oldest first:"] + quoted(utterances) + ["Revise the current outline accordingly."]
        } else {
            lines += ["They said, oldest first:"] + quoted(utterances) + ["Draw a new suggestion for this."]
        }
        return lines.joined(separator: "\n")
    }
}
