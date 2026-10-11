import XCTest
@testable import DrawCore

final class UpgradeClientTests: XCTestCase {
    let paper = PaperSize(w: 1000, h: 750)

    func testReadsStrokes() {
        let json = #"{"ok":true,"strokes":[{"role":"contour","weight":"medium","d":"M 100 100 C 150 50 200 50 250 100"},{"role":"detail","d":"M 120 130 L 140 130"}],"ms":{"total":15000}}"#
        let strokes = UpgradeClient.strokes(from: Data(json.utf8), paper: paper)
        XCTAssertEqual(strokes?.count, 2)
        XCTAssertEqual(strokes?.last?.role, .detail)
        XCTAssertEqual(strokes?.first?.points.first, PaperPoint(x: 100, y: 100))
    }

    func testDeclinedOrBrokenMeansKeepClaudes() {
        XCTAssertNil(UpgradeClient.strokes(from: Data(#"{"ok":false,"reason":"warped"}"#.utf8), paper: paper))
        XCTAssertNil(UpgradeClient.strokes(from: Data("<html>".utf8), paper: paper))
        XCTAssertNil(UpgradeClient.strokes(from: Data(#"{"ok":true,"strokes":[]}"#.utf8), paper: paper))
    }

    func testBounds() {
        let s = Stroke(role: .contour, weight: .medium, d: "", closed: false,
                       points: [PaperPoint(x: 10, y: 40), PaperPoint(x: 90, y: 20)])
        XCTAssertEqual(UpgradeClient.bounds(of: [s]), PaperRect(x: 10, y: 20, w: 80, h: 20))
    }
}

final class UpgradeTokenTests: XCTestCase {
    // Must match eval/imagegen/server.py: sha256("drawcompanion-upgrade:" + key).
    func testTokenMatchesServer() {
        XCTAssertEqual(UpgradeClient.token(apiKey: "sk-test"),
                       "d0317412277eeeb9d4dec80770260de0fdabf9fe97bfc91986685300187a8ab5")
    }
}
