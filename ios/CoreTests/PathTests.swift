import XCTest
@testable import DrawCore

final class PathTests: XCTestCase {
    let paper = PaperSize(w: 1000, h: 1458)

    func testStraightLinesKeepTheirCorners() {
        let s = PathFlattener.flatten("M 100 100 L 200 100 L 200 200", paper: paper)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].points, [PaperPoint(x: 100, y: 100), PaperPoint(x: 200, y: 100), PaperPoint(x: 200, y: 200)])
        XCTAssertFalse(s[0].closed)
    }

    func testCurvesPassThroughTheirMidpointAndEnd() {
        let s = PathFlattener.flatten("M 0 0 C 0 100 100 100 100 0 Q 150 -50 200 0", paper: paper)[0]
        XCTAssertGreaterThan(s.points.count, 20)
        XCTAssertEqual(s.points.last, PaperPoint(x: 200, y: 0))
        XCTAssertEqual(s.points[6].x, 50, accuracy: 1e-9) // t = 0.5 on the cubic
        XCTAssertEqual(s.points[6].y, 75, accuracy: 1e-9)
    }

    func testCloseHorizontalVerticalAndMultipleSubpaths() {
        let s = PathFlattener.flatten("M 10 10 H 50 V 50 Z M 300 300 L 400 400", paper: paper)
        XCTAssertEqual(s.count, 2)
        XCTAssertTrue(s[0].closed)
        XCTAssertEqual(s[0].points, [PaperPoint(x: 10, y: 10), PaperPoint(x: 50, y: 10), PaperPoint(x: 50, y: 50)])
        XCTAssertEqual(s[1].d, "M 300 300 L 400 400")
    }

    func testClampingAndBadInput() {
        let s = PathFlattener.flatten("M -20 50 L 2000 1600", paper: paper)[0]
        XCTAssertEqual(s.points, [PaperPoint(x: 0, y: 50), PaperPoint(x: 1000, y: 1458)])
        XCTAssertTrue(PathFlattener.flatten("M 1 1 A 5 5 0 0 1 9 9", paper: paper).isEmpty)
        XCTAssertTrue(PathFlattener.flatten("hello", paper: paper).isEmpty)
        XCTAssertTrue(PathFlattener.flatten("M 5 5", paper: paper).isEmpty)
    }

    func testTruncatedPathKeepsCompleteSegments() {
        let s = PathFlattener.flatten("M 0 0 L 10 10 C 1 2 3", paper: paper)[0]
        XCTAssertEqual(s.points, [PaperPoint(x: 0, y: 0), PaperPoint(x: 10, y: 10)])
    }

    func testScannerYieldsStrokesAsTheyCompleteAcrossChunkSplits() throws {
        let json = #"{"strokes":[{"role":"contour","weight":"medium","d":"M 1 2 L 3 4"},{"role":"detail","weight":"light","d":"M 5 6 L 7 8 \"}{"}]}"#
        var scanner = StrokeScanner()
        var out: [String] = []
        var i = json.startIndex
        while i < json.endIndex {
            let j = json.index(i, offsetBy: 7, limitedBy: json.endIndex) ?? json.endIndex
            out += scanner.push(String(json[i..<j]))
            i = j
        }
        XCTAssertEqual(out.count, 2)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out[1].utf8)) as? [String: String])
        XCTAssertEqual(second["d"], #"M 5 6 L 7 8 "}{"#)

        var early = StrokeScanner()
        XCTAssertEqual(early.push(String(json[..<json.range(of: "detail")!.lowerBound])).count, 1)
    }

    func testStrokesFromJSON() {
        let strokes = PathFlattener.strokes(fromJSON: #"{"role":"construction","weight":"light","d":"M 0 0 L 10 0"}"#, paper: paper)
        XCTAssertEqual(strokes.first?.role, .construction)
        XCTAssertEqual(strokes.first?.weight, .light)
        XCTAssertTrue(PathFlattener.strokes(fromJSON: "{not json", paper: paper).isEmpty)
    }
}
