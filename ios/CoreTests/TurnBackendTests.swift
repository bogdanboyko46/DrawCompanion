import XCTest
@testable import DrawCore

final class TurnBackendTests: XCTestCase {
    let paper = PaperSize(w: 1000, h: 450)
    let drawing = #"{"strokes":[{"role":"construction","weight":"light","d":"M 100 100 L 200 100"},{"role":"contour","weight":"medium","d":"M 100 120 L 200 120"}]}"#

    func filterReply(_ action: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "message", "role": "assistant", "stop_reason": "end_turn",
            "content": [["type": "text", "text": #"{"action":""# + action + #"","note":"t"}"#]],
        ])
    }

    func run(_ said: String, current: Outline? = nil) async throws -> [TurnEvent] {
        var events: [TurnEvent] = []
        let backend = ClaudeBackend(client: client)
        try await backend.run(utterances: [said], current: current, page: PagePhotos(full: Data([0xFF])), paper: paper) {
            events.append($0)
        }
        return events
    }

    var client: ClaudeClient!

    override func setUp() {
        client = ClaudeClientTests.stubbedClient()
    }

    func testARequestStartsDrawingAlongsideTheFilter() async throws {
        StubProtocol.replies = [(200, filterReply("new"))]
        StubProtocol.streamReplies = [(200, ClaudeClientTests.sse(drawing))]
        let events = try await run("can you add a third leg")
        XCTAssertEqual(events.first, .action(.new))
        XCTAssertEqual(events.last, .done)
        XCTAssertEqual(events.filter { if case .stroke = $0 { return true } else { return false } }.count, 2)
        XCTAssertEqual(StubProtocol.requests.count, 2, "one filter call, one drawing call")
    }

    func testSpeculativeStrokesAreDroppedWhenTheFilterSaysIgnore() async throws {
        StubProtocol.replies = [(200, filterReply("ignore"))]
        StubProtocol.streamReplies = [(200, ClaudeClientTests.sse(drawing))]
        let events = try await run("I want to make dinner later")
        XCTAssertEqual(events, [.action(.ignore), .done])
        // Let the cancelled request settle so it can't reach the next test's stub.
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    func testChatterNeverStartsADrawingCall() async throws {
        StubProtocol.replies = [(200, filterReply("ignore"))]
        let events = try await run("hmm, the roof came out nice")
        XCTAssertEqual(events, [.action(.ignore), .done])
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    func testWrongGuessDrawsAgainWithTheFiltersAction() async throws {
        let current = Outline(strokes: [Stroke(role: .contour, weight: .medium, d: "M 1 1 L 9 9", closed: false, points: [])],
                              history: ["add an arm"])
        StubProtocol.replies = [(200, filterReply("new"))]
        // A spare reply: the cancelled speculative call may or may not reach the stub.
        StubProtocol.streamReplies = Array(repeating: (200, ClaudeClientTests.sse(drawing)), count: 3)
        let events = try await run("make it bigger", current: current) // guessed revise; the filter says new
        XCTAssertEqual(events.first, .action(.new))
        XCTAssertEqual(events.filter { if case .stroke = $0 { return true } else { return false } }.count, 2)
        let texts = StubProtocol.bodies.compactMap { body -> String? in
            guard body["stream"] as? Bool == true else { return nil }
            let content = (body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
            return content?.last?["text"] as? String
        }
        XCTAssertTrue(texts.contains { $0.contains("Draw a new suggestion") })
    }

    func testSpeculationGuesses() {
        XCTAssertNil(Speculation.guess(utterances: ["hmm nice roof"], hasOutline: false))
        XCTAssertNil(Speculation.guess(utterances: ["ok clear it"], hasOutline: true))
        XCTAssertEqual(Speculation.guess(utterances: ["can you add teeth to the smile?"], hasOutline: false), .new)
        XCTAssertEqual(Speculation.guess(utterances: ["can you add teeth to the smile?"], hasOutline: true), .new)
        XCTAssertEqual(Speculation.guess(utterances: ["make it bigger"], hasOutline: true), .revise)
        XCTAssertEqual(Speculation.guess(utterances: ["move it left"], hasOutline: true), .revise)
        XCTAssertEqual(Speculation.guess(utterances: ["I'm stuck", "maybe a cat on the windowsill"], hasOutline: false), .new)
    }

    func testInvisibleStrokesAreDropped() {
        XCTAssertFalse(ClaudeClient.isVisible(Stroke(role: .contour, weight: .medium, d: "M 0 0 L 0 0", closed: false,
                                                     points: [PaperPoint(x: 0, y: 0), PaperPoint(x: 0, y: 0)])))
        XCTAssertTrue(ClaudeClient.isVisible(Stroke(role: .contour, weight: .medium, d: "M 0 0 L 9 0", closed: false,
                                                    points: [PaperPoint(x: 0, y: 0), PaperPoint(x: 9, y: 0)])))
    }
}
