import XCTest
@testable import DrawCore

/// Answers every request from a queue and records what was sent.
/// Streaming (drawing) requests take from `streamReplies` when it has any,
/// so tests with the filter and drawing calls in parallel stay deterministic.
final class StubProtocol: URLProtocol {
    static var replies: [(status: Int, body: Data)] = []
    static var streamReplies: [(status: Int, body: Data)] = []
    static var requests: [URLRequest] = []
    static var bodies: [[String: Any]] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        Self.requests.append(request)
        if let body = request.httpBody {
            Self.bodies.append((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            Self.bodies.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }
        let streaming = Self.bodies.last?["stream"] as? Bool == true
        let reply: (Int, Data)
        if streaming, !Self.streamReplies.isEmpty {
            reply = Self.streamReplies.removeFirst()
        } else {
            reply = Self.replies.isEmpty ? (500, Data("no reply queued".utf8)) : Self.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ClaudeClientTests: XCTestCase {
    let paper = PaperSize(w: 1000, h: 1458)
    var client: ClaudeClient!

    override func setUp() {
        client = Self.stubbedClient()
    }

    static func stubbedClient() -> ClaudeClient {
        StubProtocol.replies = []
        StubProtocol.streamReplies = []
        StubProtocol.requests = []
        StubProtocol.bodies = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var settings = ClaudeClient.Config(apiKey: "test-key")
        settings.backoff = [0.01]
        return ClaudeClient(config: settings, session: URLSession(configuration: config))
    }

    func message(_ text: String, stop: String = "end_turn") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "message", "role": "assistant", "stop_reason": stop,
            "content": [["type": "text", "text": text]],
        ])
    }

    func sse(_ text: String, stop: String = "end_turn") -> Data { Self.sse(text, stop: stop) }

    static func sse(_ text: String, stop: String = "end_turn") -> Data {
        var out = #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"# + "\n\n"
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 9, limitedBy: text.endIndex) ?? text.endIndex
            let delta = try! JSONSerialization.data(withJSONObject: ["type": "content_block_delta", "index": 0,
                                                                    "delta": ["type": "text_delta", "text": String(text[i..<j])]])
            out += "data: " + String(data: delta, encoding: .utf8)! + "\n\n"
            i = j
        }
        out += #"data: {"type":"message_delta","delta":{"stop_reason":""# + stop + #""}}"# + "\n\n"
        return Data(out.utf8)
    }

    func testFilterIsATextOnlyHaikuCallWithStructuredOutput() async throws {
        StubProtocol.replies = [(200, message(#"{"action":"ignore","note":"chatter"}"#))]
        let decision = try await client.classify(utterances: ["hmm, nice roof"], current: nil)
        XCTAssertEqual(decision.action, .ignore)
        let req = StubProtocol.requests[0]
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = StubProtocol.bodies[0]
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertTrue(body["messages"].flatMap { ($0 as? [[String: Any]])?.first?["content"] as? String } != nil, "no image for the filter")
        XCTAssertNotNil((body["output_config"] as? [String: Any])?["format"])
        XCTAssertNil(body["fallbacks"])
    }

    func testReviseOrHideWithNothingShownIsCorrected() async throws {
        StubProtocol.replies = [(200, message(#"{"action":"revise","note":"x"}"#)), (200, message(#"{"action":"hide","note":"x"}"#))]
        let first = try await client.classify(utterances: ["make it a tree"], current: nil)
        let second = try await client.classify(utterances: ["clear it"], current: nil)
        XCTAssertEqual(first.action, .new)
        XCTAssertEqual(second.action, .ignore)
    }

    func testDrawingStreamsStrokesFromSonnetInOrder() async throws {
        let drawing = #"{"strokes":[{"role":"construction","weight":"light","d":"M 100 100 C 100 50 200 50 200 100 Z"},{"role":"contour","weight":"medium","d":"M 150 100 L 150 2000"}]}"#
        StubProtocol.replies = [(200, sse(drawing))]
        var strokes: [Stroke] = []
        let count = try await client.draw(page: PagePhotos(full: Data([0xFF, 0xD8])), paper: paper, utterances: ["add a flower"],
                                          current: nil, action: .new) { strokes.append($0) }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(strokes.map(\.role), [.construction, .contour])
        XCTAssertTrue(strokes[0].closed)
        XCTAssertEqual(strokes[1].points.last, PaperPoint(x: 150, y: 1458))
        let req = StubProtocol.requests[0]
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = StubProtocol.bodies[0]
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["fallbacks"] as? String, "default")
    }

    func testRevisionSendsTheCurrentOutlineAsPathData() async throws {
        StubProtocol.replies = [(200, sse(#"{"strokes":[{"role":"contour","weight":"medium","d":"M 1 1 L 9 9"}]}"#))]
        let current = Outline(strokes: [Stroke(role: .contour, weight: .medium, d: "M 1 1 L 9 9", closed: false, points: [])],
                              history: ["add a flower"])
        _ = try await client.draw(page: PagePhotos(full: Data([0xFF])), paper: paper, utterances: ["bigger"], current: current, action: .revise) { _ in }
        let content = (StubProtocol.bodies[0]["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        let text = content?.last?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Outline currently shown"))
        XCTAssertTrue(text.contains(#""d":"M 1 1 L 9 9""#))
    }

    func testRejectedKeyIsReportedClearly() async {
        StubProtocol.replies = [(401, Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))]
        do {
            _ = try await client.classify(utterances: ["draw a cat"], current: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ClaudeClient.Failure, .http(401, "invalid x-api-key"))
            XCTAssertTrue(error.localizedDescription.contains("Settings"))
        }
        XCTAssertEqual(StubProtocol.requests.count, 1, "a wrong key is not retried")
    }

    func testOverloadedFilterIsRetried() async throws {
        StubProtocol.replies = [
            (529, Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)),
            (200, message(#"{"action":"new","note":"request"}"#)),
        ]
        let decision = try await client.classify(utterances: ["draw a cat"], current: nil)
        XCTAssertEqual(decision.action, .new)
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testRetriesGiveUpWithAClearMessage() async {
        let busy = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#.utf8)
        StubProtocol.replies = [(429, busy), (429, busy), (429, busy), (429, busy)]
        do {
            _ = try await client.classify(utterances: ["draw a cat"], current: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(StubProtocol.requests.count, 3, "one try plus two retries")
            XCTAssertTrue(error.localizedDescription.contains("Try again"))
        }
    }

    func testDrawingRetriesAfterAnOverloadedStart() async throws {
        StubProtocol.replies = [
            (529, Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)),
            (200, sse(#"{"strokes":[{"role":"contour","weight":"medium","d":"M 10 10 L 90 90"}]}"#)),
        ]
        var strokes: [Stroke] = []
        let n = try await client.draw(page: PagePhotos(full: Data([0xFF])), paper: paper, utterances: ["add a stick"],
                                      current: nil, action: .new) { strokes.append($0) }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(strokes.count, 1)
    }

    func testEmptyDrawingIsRetriedThenReported() async {
        let dot = sse(#"{"strokes":[{"role":"contour","weight":"medium","d":"M 0 0"}]}"#)
        StubProtocol.replies = [(200, dot), (200, dot), (200, dot)]
        do {
            _ = try await client.draw(page: PagePhotos(full: Data([0xFF])), paper: paper, utterances: ["add a hat"],
                                      current: nil, action: .new) { _ in XCTFail("nothing to draw") }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ClaudeClient.Failure, .empty)
            XCTAssertEqual(StubProtocol.requests.count, 3)
        }
    }

    func testDeclinedDrawingIsReportedNotSilent() async {
        StubProtocol.replies = [(200, sse("", stop: "refusal"))]
        do {
            _ = try await client.draw(page: PagePhotos(full: Data([0xFF])), paper: paper, utterances: ["draw it"],
                                      current: nil, action: .new) { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ClaudeClient.Failure, .declined)
            XCTAssertEqual(StubProtocol.requests.count, 1, "a refusal is not retried")
        }
    }

    func testPartsAndPlaceAreNotDrawnAsStrokes() async throws {
        let answer = #"{"parts":[{"name":"head","box":{"x0":1,"y0":2,"x1":3,"y1":4}}],"place":{"reason":"r","box":{"x0":5,"y0":6,"x1":7,"y1":8}},"strokes":[{"role":"contour","weight":"medium","d":"M 10 10 L 90 90"}]}"#
        StubProtocol.replies = [(200, sse(answer))]
        var strokes: [Stroke] = []
        _ = try await client.draw(page: PagePhotos(full: Data([0xFF])), paper: paper, utterances: ["add a leg"],
                                  current: nil, action: .new) { strokes.append($0) }
        XCTAssertEqual(strokes.map(\.d), ["M 10 10 L 90 90"])
    }
}

final class MockBackendTests: XCTestCase {
    func testWordsDecideTheAction() {
        XCTAssertEqual(MockBackend.action(for: "hmm the roof came out nice", hasOutline: false), .ignore)
        XCTAssertEqual(MockBackend.action(for: "i'm stuck, maybe a flower?", hasOutline: false), .new)
        XCTAssertEqual(MockBackend.action(for: "make it bigger", hasOutline: true), .revise)
        XCTAssertEqual(MockBackend.action(for: "ok clear it", hasOutline: true), .hide)
        XCTAssertEqual(MockBackend.action(for: "clear it", hasOutline: false), .ignore)
    }

    func testMockStreamsAFlower() async throws {
        var events: [TurnEvent] = []
        try await MockBackend(delay: 0.01).run(utterances: ["draw a flower"], current: nil, page: PagePhotos(full: Data()),
                                              paper: PaperSize(w: 1000, h: 1458)) { events.append($0) }
        XCTAssertEqual(events.first, .action(.new))
        XCTAssertEqual(events.last, .done)
        XCTAssertEqual(events.filter { if case .stroke = $0 { return true } else { return false } }.count, 10)
    }

    func testSchemasAreValidJSON() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(Prompts.filterSchema))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(Prompts.drawSchema))
    }
}
