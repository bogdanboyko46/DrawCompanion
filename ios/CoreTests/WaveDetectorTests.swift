import XCTest
@testable import DrawCore

final class WaveDetectorTests: XCTestCase {
    /// Feeds positions 0.1 s apart; returns the times a wave was seen.
    private func run(_ xs: [Double?], _ d: inout WaveDetector, start: Double = 0) -> [Double] {
        var hits: [Double] = []
        for (i, x) in xs.enumerated() {
            let t = start + Double(i) * 0.1
            if d.update(x: x, at: t) { hits.append(t) }
        }
        return hits
    }

    func testWaveIsSeenOnce() {
        var d = WaveDetector()
        let wave: [Double?] = [0.5, 0.6, 0.7, 0.6, 0.5, 0.4, 0.5, 0.6, 0.7, 0.6, 0.5, 0.4]
        XCTAssertEqual(run(wave, &d).count, 1)
    }

    func testSmallDrawingMovesAreNotAWave() {
        var d = WaveDetector()
        // Hatching: quick but narrow back-and-forth.
        let hatching: [Double?] = (0..<30).map { 0.5 + ($0 % 2 == 0 ? 0.02 : -0.02) }
        XCTAssertTrue(run(hatching, &d).isEmpty)
    }

    func testSlowSingleSweepIsNotAWave() {
        var d = WaveDetector()
        let sweep: [Double?] = stride(from: 0.2, through: 0.8, by: 0.05).map { $0 }
        XCTAssertTrue(run(sweep, &d).isEmpty)
    }

    func testHandLeavingViewResets() {
        var d = WaveDetector()
        let broken: [Double?] = [0.5, 0.7, 0.5, nil, 0.7, 0.5]
        XCTAssertTrue(run(broken, &d).isEmpty)
    }

    func testCooldownThenSecondWave() {
        var d = WaveDetector()
        let wave: [Double?] = [0.5, 0.65, 0.5, 0.35, 0.5, 0.65, 0.5, 0.35]
        let hits = run(wave + wave + Array(repeating: nil, count: 15) + wave, &d)
        XCTAssertEqual(hits.count, 2)
    }
}
