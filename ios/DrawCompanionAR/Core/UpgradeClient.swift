import Foundation

/// Asks the drawing server on the Mac (eval/imagegen/server.py) for a nicer
/// version of a new outline. Claude's outline shows up in a few seconds; the
/// server has an image model draw the same thing on a photo of the page,
/// maps that picture back onto the page and traces its lines into strokes
/// (~15 s). The app swaps them in if nothing else happened meanwhile.
///
/// The server says no (nil) whenever it isn't sure the result is right; the
/// app then simply keeps Claude's outline.
struct UpgradeClient {
    var baseURL: URL
    var session: URLSession = .shared

    struct Response: Decodable {
        struct Path: Decodable {
            var role: String?
            var weight: String?
            var d: String
        }
        var ok: Bool
        var strokes: [Path]?
        var reason: String?
    }

    /// Strokes in paper units for the page in `page` (the same photo the AI
    /// drew on), or nil when the server declined.
    func upgrade(page: Data, paper: PaperSize, said: [String], box: PaperRect, id: String) async throws -> [Stroke]? {
        var req = URLRequest(url: baseURL.appendingPathComponent("upgrade"))
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "page_jpeg": page.base64EncodedString(),
            "paper": ["w": paper.w, "h": paper.h],
            "said": said,
            "box": ["x0": box.x, "y0": box.y, "x1": box.x + box.w, "y1": box.y + box.h],
            "id": id,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: req)
        return Self.strokes(from: data, paper: paper)
    }

    static func strokes(from data: Data, paper: PaperSize) -> [Stroke]? {
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        guard r.ok, let paths = r.strokes else {
            print("[DC] upgrade declined: \(r.reason ?? "no reason")")
            return nil
        }
        let strokes = paths.flatMap { p in
            PathFlattener.flatten(p.d, paper: paper).map {
                Stroke(role: p.role.flatMap(StrokeRole.init) ?? .contour,
                       weight: p.weight.flatMap(StrokeWeight.init) ?? .medium,
                       d: $0.d, closed: $0.closed, points: $0.points)
            }
        }
        return strokes.isEmpty ? nil : strokes
    }

    /// Bounding box of an outline's strokes, in paper units.
    static func bounds(of strokes: [Stroke]) -> PaperRect? {
        let pts = strokes.flatMap(\.points)
        guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(),
              let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return nil }
        return PaperRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }
}
