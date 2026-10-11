import XCTest
@testable import DrawCore

final class HeadsetOpticsTests: XCTestCase {
    let optics = HeadsetOptics.cardboard

    func testDistortionModel() {
        XCTAssertEqual(optics.eyeTan(fromScreenTan: 0), 0)
        XCTAssertEqual(optics.eyeTan(fromScreenTan: 0.01), 0.01, accuracy: 1e-5) // no effect at the center
        XCTAssertEqual(optics.eyeTan(fromScreenTan: 0.5), 0.5 * (1 + 0.441 * 0.25 + 0.156 * 0.0625), accuracy: 1e-12)
        XCTAssertEqual(optics.eyeTan(fromScreenTan: -0.5), -optics.eyeTan(fromScreenTan: 0.5), accuracy: 1e-12)
    }

    func testInverseRoundTrips() {
        for e in stride(from: -1.2, through: 1.2, by: 0.05) {
            XCTAssertEqual(optics.eyeTan(fromScreenTan: optics.screenTan(fromEyeTan: e)), e, accuracy: 1e-9)
        }
        // Barrel pre-distortion pulls the picture toward the lens center.
        XCTAssertLessThan(optics.screenTan(fromEyeTan: 0.8), 0.8)
    }

    func testCorrectionOffIsIdentity() {
        var off = optics
        off.correctsDistortion = false
        XCTAssertEqual(off.eyeTan(fromScreenTan: 0.7), 0.7)
        XCTAssertEqual(off.screenTan(fromEyeTan: 0.7), 0.7)
    }

    /// A straight paper edge (a vertical line in what the eye sees) is drawn
    /// bowed on the screen, and comes back straight through the lens.
    func testStraightLinesComeOutStraight() {
        let layout = optics.layout(screenWidth: 2622, screenHeight: 1206)
        let eye = layout.eyes[0]
        let points = stride(from: -0.7, through: 0.7, by: 0.1).map {
            optics.screenPoint(eye: eye, layout: layout, eyeTanX: 0.5, eyeTanY: $0)
        }
        let xs = points.map(\.x)
        // Bowed on screen: farthest out in the middle (barrel).
        XCTAssertGreaterThan(xs[7], xs[0] + 5)
        XCTAssertEqual(xs[0], xs[14], accuracy: 1e-6)
        // Through the lens: straight again.
        for p in points {
            let tx = (p.x - eye.centerX) / layout.pixelsPerTan, ty = (p.y - eye.centerY) / layout.pixelsPerTan
            let r = (tx * tx + ty * ty).squareRoot()
            XCTAssertEqual(tx * optics.eyeTan(fromScreenTan: r) / r, 0.5, accuracy: 1e-9)
        }
    }

    func testLayoutOnIPhone17Pro() {
        // 2622 × 1206 pixels at 460 ppi, landscape.
        let layout = optics.layout(screenWidth: 2622, screenHeight: 1206)
        let mm = 460 / 25.4
        XCTAssertEqual(layout.eyes.count, 2)
        XCTAssertEqual(layout.eyes[0].centerX, 1311 - 30 * mm, accuracy: 1e-9)
        XCTAssertEqual(layout.eyes[1].centerX, 1311 + 30 * mm, accuracy: 1e-9)
        XCTAssertEqual(layout.eyes[0].centerY, 603)
        XCTAssertEqual(layout.eyes[1].x, 1311)
        XCTAssertEqual(layout.eyes[1].width, 1311)
        XCTAssertEqual(layout.pixelsPerTan, 42 * mm, accuracy: 1e-9)
        // ±40° at screen sharpness: about 1280 pixels square.
        XCTAssertEqual(layout.eyeTextureSize % 16, 0)
        XCTAssertEqual(Double(layout.eyeTextureSize), 2 * tan(40 * Double.pi / 180) * 42 * mm, accuracy: 16)
        // The lens center sees; the screen's far corner is outside the field.
        let left = layout.eyes[0]
        XCTAssertTrue(optics.isVisible(eye: left, layout: layout, screenX: left.centerX, screenY: left.centerY))
        XCTAssertFalse(optics.isVisible(eye: left, layout: layout, screenX: 0, screenY: 0))
    }

    func testVerticalOffsetMovesCentersUp() {
        var o = optics
        o.verticalOffsetMM = 2
        let layout = o.layout(screenWidth: 2622, screenHeight: 1206)
        XCTAssertEqual(layout.eyes[0].centerY, 603 - 2 * 460 / 25.4, accuracy: 1e-9)
    }

    func testCameraCrop() {
        var o = optics
        o.zoom = 1
        let crop = o.cameraCrop(imageAspect: 4.0 / 3)
        XCTAssertEqual(crop.height, 1)
        XCTAssertEqual(crop.width, 0.75, accuracy: 1e-12)
        XCTAssertEqual(crop.x, 0.125, accuracy: 1e-12)
        o.zoom = 2
        let closer = o.cameraCrop(imageAspect: 4.0 / 3)
        XCTAssertEqual(closer.height, 0.5)
        XCTAssertEqual(closer.y, 0.25)
    }

    func testSettingsFromUserDefaults() {
        let suite = "HeadsetOpticsTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(HeadsetOptics(defaults: defaults), HeadsetOptics.cardboard)

        defaults.set(0.3, forKey: HeadsetOptics.Key.k1)
        defaults.set(64.0, forKey: HeadsetOptics.Key.lensSeparationMM)
        defaults.set(1.4, forKey: HeadsetOptics.Key.zoom)
        defaults.set(false, forKey: HeadsetOptics.Key.correctsDistortion)
        defaults.set(5000.0, forKey: HeadsetOptics.Key.screenToLensMM) // nonsense gets clamped
        let o = HeadsetOptics(defaults: defaults)
        XCTAssertEqual(o.k1, 0.3)
        XCTAssertEqual(o.k2, 0.156)
        XCTAssertEqual(o.lensSeparationMM, 64)
        XCTAssertEqual(o.zoom, 1.4)
        XCTAssertFalse(o.correctsDistortion)
        XCTAssertEqual(o.screenToLensMM, 80)
        defaults.removePersistentDomain(forName: suite)
    }
}

final class HeadsetStrokesTests: XCTestCase {
    func pieces(_ points: [SIMD2<Float>], dash: (on: Float, off: Float)? = nil, reveal: Float = 1) -> [[Float]] {
        var out: [[Float]] = []
        HeadsetStrokes.forEachPiece(points, dash: dash, reveal: reveal) { a, b in out.append([a.x, a.y, b.x, b.y]) }
        return out
    }

    func assertPieces(_ got: [[Float]], _ want: [[Float]], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, "\(got)", file: file, line: line)
        for (g, w) in zip(got, want) {
            for (x, y) in zip(g, w) { XCTAssertEqual(x, y, accuracy: 1e-4, "\(got)", file: file, line: line) }
        }
    }

    func testSolidLineIsItsSegments() {
        assertPieces(pieces([[0, 0], [10, 0], [10, 5]]), [[0, 0, 10, 0], [10, 0, 10, 5]])
    }

    func testDashes() {
        assertPieces(pieces([[0, 0], [20, 0]], dash: (4, 3)), [[0, 0, 4, 0], [7, 0, 11, 0], [14, 0, 18, 0]])
    }

    func testDashesContinueAroundCorners() {
        // 4 on, 3 off: the second dash starts at 7 = 5 along the first leg + 2 along the second.
        assertPieces(pieces([[0, 0], [5, 0], [5, 10]], dash: (4, 3)),
                     [[0, 0, 4, 0], [5, 2, 5, 6], [5, 9, 5, 10]])
    }

    func testRevealDrawsTheStartOfTheLine() {
        assertPieces(pieces([[0, 0], [10, 0], [10, 10]], reveal: 0.25), [[0, 0, 5, 0]])
        assertPieces(pieces([[0, 0], [10, 0], [10, 10]], reveal: 0.75), [[0, 0, 10, 0], [10, 0, 10, 5]])
        XCTAssertTrue(pieces([[0, 0], [10, 0]], reveal: 0).isEmpty)
    }

    func testRepeatedPointsAreSkipped() {
        assertPieces(pieces([[0, 0], [0, 0], [3, 4]]), [[0, 0, 3, 4]])
        XCTAssertTrue(pieces([[1, 1]]).isEmpty)
    }

    func stroke(_ d: String) -> Stroke { Stroke(role: .contour, weight: .medium, d: d, closed: false, points: []) }

    func testNewStrokesAnimateAndOldOnesDoNot() {
        var arrivals = HeadsetStrokes.Arrivals()
        arrivals.update([stroke("M 0 0 L 1 1")], now: 10)
        XCTAssertEqual(arrivals.progress(0, now: 10), 0)
        XCTAssertEqual(arrivals.progress(0, now: 10 + HeadsetStrokes.Arrivals.duration / 2), 0.5, accuracy: 1e-9)

        // A second stroke streams in; the first keeps its time.
        arrivals.update([stroke("M 0 0 L 1 1"), stroke("M 5 5 L 6 6")], now: 11)
        XCTAssertEqual(arrivals.progress(0, now: 11), 1)
        XCTAssertEqual(arrivals.progress(1, now: 11), 0)

        // A new outline replaces the first stroke: it animates again.
        arrivals.update([stroke("M 9 9 L 1 1")], now: 12)
        XCTAssertEqual(arrivals.progress(0, now: 12), 0)
        XCTAssertEqual(arrivals.progress(1, now: 12), 1) // gone: nothing to animate

        XCTAssertEqual(HeadsetStrokes.Arrivals.reveal(0), 0)
        XCTAssertEqual(HeadsetStrokes.Arrivals.reveal(1), 1)
        XCTAssertEqual(HeadsetStrokes.Arrivals.opacity(1), 1)
        XCTAssertGreaterThan(HeadsetStrokes.Arrivals.opacity(0), 0)
    }
}
