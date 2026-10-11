import Foundation

/// Claude as the character's art director, called directly from the phone
/// (Messages API over HTTPS; there's no official Swift SDK).
///
/// Mirrors server/character/director.js for static characters: read the
/// drawing into a character sheet, then check the concept render against it.
struct ClaudeDirector {
    var apiKey: String
    var model = "claude-opus-5-5"
    var effort = "high"

    struct DirectorError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    struct Sheet: Codable, Sendable {
        var is_character: Bool
        var reject_reason: String
        var name: String
        var summary: String
        var body_plan: String
        var height_m: Double
        var figure_box: Box
        var colors: [Swatch]
        var design_details: [String]
        var concept_prompt: String
        var texture_prompt: String
        var personality: Personality
        var greeting: String
    }

    struct Review: Codable, Sendable {
        var faithful: Bool
        var issues: [String]
        var revised_prompt: String
        /// Which of the views (0-based) is the front view.
        var front_index: Int
    }

    // MARK: Calls

    func readDrawing(jpeg: Data, hint: String) async throws -> Sheet {
        let text = (hint.isEmpty ? "The user gave no description; read the drawing." : "The user says: \"\(hint)\"")
        var sheet: Sheet = try await call(
            system: Self.sheetSystem,
            content: [image("image/jpeg", jpeg), ["type": "text", "text": text]],
            schema: Self.sheetSchema)
        // Keep downstream APIs inside their limits whatever came back.
        sheet.name = String(sheet.name.trimmingCharacters(in: .whitespaces).prefix(40))
        if sheet.name.isEmpty { sheet.name = "Doodle" }
        sheet.greeting = String(sheet.greeting.prefix(80))
        sheet.height_m = min(3, max(0.2, sheet.height_m))
        sheet.concept_prompt = String(sheet.concept_prompt.prefix(800))
        sheet.texture_prompt = String(sheet.texture_prompt.prefix(800))
        sheet.colors = Array(sheet.colors.filter { $0.hex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }.prefix(8))
        sheet.personality.energy = min(1, max(0, sheet.personality.energy))
        sheet.personality.friendliness = min(1, max(0, sheet.personality.friendliness))
        return sheet
    }

    /// `views`: the concept render's views (front, side, back… in whatever order Meshy returned them).
    func reviewConcept(drawing: Data, views: [(data: Data, type: String)], sheet: Sheet) async throws -> Review {
        let text = """
        Character: \(sheet.name): \(sheet.summary)
        Must keep: \(sheet.design_details.joined(separator: "; "))
        Planned colors: \(sheet.colors.map { "\($0.part) \($0.hex)" }.joined(separator: ", "))
        Prompt used: \(sheet.concept_prompt)
        """
        return try await call(
            system: Self.reviewSystem,
            content: [image("image/jpeg", drawing)] + views.map { image($0.type, $0.data) } + [["type": "text", "text": text]],
            schema: Self.reviewSchema)
    }

    // MARK: HTTP

    private func image(_ mediaType: String, _ data: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
    }

    private func call<T: Decodable>(system: String, content: [[String: Any]], schema: [String: Any]) async throws -> T {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "fallbacks": "default",
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
            "system": system,
            "messages": [["role": "user", "content": content]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300 // high effort on an image can take a minute or more
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error?
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(2 << attempt))) }
            let data: Data, response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                lastError = error
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500 {
                lastError = DirectorError(message: "Claude is busy (\(status)). Retrying…")
                continue
            }
            guard status == 200 else {
                let message = (try? JSONDecoder().decode(APIError.self, from: data))?.error.message ?? "HTTP \(status)"
                if status == 401 { throw DirectorError(message: "The Anthropic API key was rejected. Check it in Settings.") }
                throw DirectorError(message: "Claude request failed: \(message)")
            }
            let message = try JSONDecoder().decode(Message.self, from: data)
            if message.stop_reason == "refusal" {
                throw DirectorError(message: "This drawing can't be turned into a character.")
            }
            guard let json = message.content.first(where: { $0.type == "text" })?.text?.data(using: .utf8) else {
                throw DirectorError(message: "Claude returned no answer (\(message.stop_reason ?? "unknown")).")
            }
            do {
                return try JSONDecoder().decode(T.self, from: json)
            } catch {
                throw DirectorError(message: "The character sheet came back malformed. Please try again.")
            }
        }
        throw lastError ?? DirectorError(message: "Couldn't reach Claude.")
    }

    private struct APIError: Decodable {
        struct E: Decodable { var message: String }
        var error: E
    }

    private struct Message: Decodable {
        struct Block: Decodable { var type: String; var text: String? }
        var content: [Block]
        var stop_reason: String?
    }

    // MARK: Prompts and schemas

    static let sheetSystem = """
    You are the art director of DrawCompanion, an AR app that turns a figure drawn on paper into a 3D character standing on the user's desk.
    You see a perspective-corrected photo of the page. Your sheet drives an image model and a 3D generator, so be precise.

    The concept_prompt is the most important field. An image model receives it together with the drawing and must produce a single, clean, full-color render of THIS character that a 3D generator can lift:
    - Preserve the design exactly: silhouette, proportions (big head stays big), facial features, number and shape of limbs, every item in design_details, and the colors. Do not "improve" or realistify the design; keep its charm and style. A child's drawing becomes a polished toy-like version of that same drawing, not a different creature.
    - Render as a high-quality stylized 3D character (soft studio lighting, clean materials, subtle subsurface), full body, entire figure in frame, facing the viewer, centered, on a plain white background, no ground shadow, no text, no props unless the character holds them.
    - The character will be a static figure: a natural, appealing standing pose that shows its personality, with the limbs clearly separated from the body (not a T-pose).
    - Mention the medium of the drawing only to say what to keep (e.g. "keep the bold marker outlines as dark seams").

    If the page has no character (a landscape, text, abstract shapes), set is_character false, explain kindly in reject_reason, and fill the other fields minimally.
    """

    static let reviewSystem = """
    You check concept renders for DrawCompanion. Image 1 is the user's drawing. The images after it are views (front, side, back, in no particular order) of a render meant to be the same character as a clean 3D figure; front_index is the 0-based index, among those views, of the front view. Judge the design across all the views together: a side view showing one ear is fine if the front view shows both.
    Judge fidelity to the DESIGN, not drawing skill: same species/type, same proportions, same features and accessories, same colors (or the planned palette if the drawing was uncolored), full body visible, plain background, usable pose for 3D.
    Minor stylization is expected and fine. Flag only differences the user would notice and mind ("it lost the scarf", "it has two eyes instead of three", "cropped feet").
    If it is not faithful, write revised_prompt: a corrected image prompt (max 700 characters). Otherwise leave it empty.
    """

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": Array(properties.keys).sorted(), "additionalProperties": false]
    }
    private static let string: [String: Any] = ["type": "string"]
    private static let number: [String: Any] = ["type": "number"]
    private static let bool: [String: Any] = ["type": "boolean"]
    private static func array(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
    private static func described(_ base: [String: Any], _ text: String) -> [String: Any] {
        var b = base
        b["description"] = text
        return b
    }

    static let sheetSchema: [String: Any] = object([
        "is_character": described(bool, "True if the page shows a figure that can stand in AR: a person, animal, creature, robot, or anthropomorphic object."),
        "reject_reason": described(string, "If not a character, one friendly sentence on why; otherwise empty."),
        "name": described(string, "The name written on the page, or a short, charming invented one."),
        "summary": described(string, "One sentence describing the character as drawn."),
        "body_plan": ["type": "string", "enum": ["humanoid", "biped_creature", "quadruped", "blob", "winged", "object", "other"]],
        "height_m": described(number, "Plausible real height in meters for this character in its own world, 0.2–3."),
        "figure_box": described(object(["x": number, "y": number, "w": number, "h": number]),
                                "Bounding box of the main figure as fractions 0–1 of width/height, origin top-left."),
        "colors": described(array(object(["hex": string, "part": string, "from_drawing": bool])),
                            "3–8 colors by body part, as #rrggbb. Use the drawing's colors; if uncolored, invent a fitting palette and mark from_drawing false."),
        "design_details": described(array(string), "Every distinctive feature that must survive into 3D: accessories, markings, number of eyes, tail shape, clothing, held items."),
        "concept_prompt": described(string, "Image prompt (max 700 characters) that turns the drawing into a faithful 3D character render. See the system prompt."),
        "texture_prompt": described(string, "Max 500 characters: surface materials and colors for the 3D texturing pass."),
        "personality": object([
            "traits": described(array(string), "2–4 adjectives"),
            "energy": described(number, "0 calm … 1 hyper"),
            "friendliness": described(number, "0 shy … 1 outgoing"),
        ]),
        "greeting": described(string, "A first line the character says when it appears, max 60 characters, in its voice."),
    ])

    static let reviewSchema: [String: Any] = object([
        "faithful": described(bool, "True if the render is recognizably the same character design."),
        "issues": described(array(string), "Concrete differences that matter, most important first."),
        "revised_prompt": described(string, "If not faithful, a corrected image prompt; else empty."),
        "front_index": described(["type": "integer"], "0-based index of the front-facing view among the render's views."),
    ])
}
