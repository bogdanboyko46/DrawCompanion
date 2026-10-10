import XCTest
@testable import DrawCore

final class CompletionTests: XCTestCase {
    let W = 200, H = 200
    let paper = PaperSize(w: 1000, h: 1000)
    let line = Stroke(role: .contour, weight: .medium, d: "", closed: false,
                      points: [PaperPoint(x: 200, y: 500), PaperPoint(x: 800, y: 500)])

    func blank() -> [Float] { Array(repeating: 230, count: W * H) }

    func ink(_ img: [Float], _ x0: Int, _ x1: Int, _ y: Int) -> [Float] {
        var img = img
        for x in x0...x1 { img[y * W + x] = 80 }
        return img
    }

    func tracker(_ baseline: [Float]? = nil, _ strokes: [Stroke]? = nil) -> CompletionTracker {
        CompletionTracker(baseline: baseline ?? blank(), width: W, height: H, paper: paper, strokes: strokes ?? [line], now: 0)
    }

    @discardableResult
    func feed(_ t: CompletionTracker, _ img: [Float], _ times: [Double]) -> CompletionTracker.State {
        times.map { t.update(img, now: $0) }.last!
    }

    func testClearsThreeSecondsAfterTracingStops() {
        let t = tracker()
        let traced = ink(blank(), 40, 160, 101)
        let s = feed(t, traced, [0, 0.4, 0.8])
        XCTAssertTrue(s.started)
        XCTAssertFalse(s.done)
        XCTAssertFalse(feed(t, traced, [2.0, 3.7]).done)
        XCTAssertTrue(t.update(traced, now: 3.9).done)
    }

    func testWaitsUntilTracingStarts() {
        XCTAssertFalse(feed(tracker(), blank(), [0, 5, 20]).done)
    }

    func testInkFarFromTheOutlineDoesNotCount() {
        let s = feed(tracker(), ink(blank(), 40, 160, 30), [0, 0.4, 0.8, 1.2, 5])
        XCTAssertEqual(s.strokes[0].progress, 0)
        XCTAssertFalse(s.started)
    }

    func testHandOnTheOutlineIsNotInkButHoldsTheOutline() {
        let t = tracker()
        let traced = ink(blank(), 40, 100, 100)
        feed(t, traced, [0, 0.4, 0.8])
        var hand = traced
        for y in 80..<125 { for x in 110..<170 { hand[y * W + x] = 150 } }
        let s = feed(t, hand, [2, 3, 4, 5])
        XCTAssertFalse(s.done)
        XCTAssertLessThan(s.strokes[0].progress, 0.6)
        XCTAssertFalse(t.update(traced, now: 7.9).done)
        XCTAssertTrue(t.update(traced, now: 8.1).done)
    }

    func testDensePackedInkStillCountsAndClears() {
        let strokes = (0..<8).map { k in
            Stroke(role: .contour, weight: .medium, d: "", closed: false,
                   points: [PaperPoint(x: 300, y: 480 + Double(k) * 15), PaperPoint(x: 700, y: 480 + Double(k) * 15)])
        }
        let t = tracker(nil, strokes)
        var img = blank()
        for k in 0..<8 { img = ink(img, 60, 140, 96 + k * 3) }
        let s = feed(t, img, [0, 0.3, 0.6, 0.9])
        XCTAssertTrue(s.started)
        XCTAssertTrue(s.strokes.allSatisfy { $0.progress > 0.9 })
        XCTAssertTrue(t.update(img, now: 4).done)
    }

    func testExistingLinesShiftedByJitterAreNotNewInk() {
        let t = tracker(ink(blank(), 40, 160, 100))
        let s = feed(t, ink(blank(), 41, 161, 102), [0, 0.4, 0.8, 1.2])
        XCTAssertEqual(s.strokes[0].progress, 0)
    }

    func testUniformLightingChangeIsIgnored() {
        let s = feed(tracker(), Array(repeating: 170, count: W * H), [0, 0.4, 0.8, 1.2])
        XCTAssertFalse(s.occluded)
        XCTAssertEqual(s.strokes[0].progress, 0)
    }
}
