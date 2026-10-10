import XCTest
@testable import DrawCore

final class DrawingAlignerTests: XCTestCase {
    let W = 480, H = 240

    /// A sketch like the user's (head with spikes, ears, smile, legs), drawn
    /// through `t` (sketch coords -> image px), plus optional extras.
    func sketch(_ t: Affine2 = .identity, extraInk: [((Double, Double), (Double, Double))] = [],
                blob: (x: Int, y: Int, r: Int)? = nil) -> [Float] {
        var img = [Float](repeating: 225, count: W * H)
        func line(_ p: (Double, Double), _ q: (Double, Double)) {
            let (x0, y0) = t.apply(p.0, p.1), (x1, y1) = t.apply(q.0, q.1)
            let n = Int(max(abs(x1 - x0), abs(y1 - y0)) * 2) + 1
            for i in 0...n {
                let s = Double(i) / Double(n)
                let x = Int((x0 + (x1 - x0) * s).rounded()), y = Int((y0 + (y1 - y0) * s).rounded())
                for (dx, dy) in [(0, 0), (1, 0), (0, 1)] where x + dx >= 0 && x + dx < W && y + dy >= 0 && y + dy < H {
                    img[(y + dy) * W + x + dx] = 90
                }
            }
        }
        func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, from a0: Double = 0, to a1: Double = 2 * .pi) {
            let n = 60
            for i in 0..<n {
                let a = a0 + (a1 - a0) * Double(i) / Double(n), b = a0 + (a1 - a0) * Double(i + 1) / Double(n)
                line((cx + rx * cos(a), cy + ry * sin(a)), (cx + rx * cos(b), cy + ry * sin(b)))
            }
        }
        ellipse(240, 105, 70, 45)
        ellipse(160, 105, 30, 18)
        ellipse(320, 110, 28, 16)
        for i in 0..<9 { line((185 + Double(i) * 12, 66), (191 + Double(i) * 12, 50)); line((191 + Double(i) * 12, 50), (197 + Double(i) * 12, 66)) }
        line((222, 92), (223, 102)); line((256, 90), (256, 100))
        ellipse(240, 112, 16, 14, from: 0.2, to: 2.9)
        line((215, 148), (212, 200)); line((212, 200), (228, 204)); line((228, 204), (230, 150))
        line((262, 148), (262, 196)); line((262, 196), (278, 198)); line((278, 198), (276, 150))
        line((350, 60), (342, 140)); line((350, 60), (360, 100))
        for (p, q) in extraInk { line(p, q) }
        if let b = blob {
            for y in max(0, b.y - b.r)..<min(H, b.y + b.r) {
                for x in max(0, b.x - b.r)..<min(W, b.x + b.r) where (x - b.x) * (x - b.x) + (y - b.y) * (y - b.y) < b.r * b.r {
                    img[y * W + x] = 120
                }
            }
        }
        return img
    }

    /// The aligner returns current->reference. Check it sends where a sketch
    /// point appears now back to where it was in the reference.
    func assertRecovers(_ moved: Affine2, current: [Float], tolerance: Double = 1.0, file: StaticString = #filePath, line: UInt = #line) {
        let aligner = try! XCTUnwrap(DrawingAligner(reference: sketch(), width: W, height: H))
        guard let t = aligner.align(current: current) else { return XCTFail("no alignment", file: file, line: line) }
        for p in [(160.0, 105.0), (240.0, 60.0), (350.0, 60.0), (215.0, 200.0), (320.0, 110.0)] {
            let (cx, cy) = moved.apply(p.0, p.1) // where it is now
            let (rx, ry) = t.apply(cx, cy) // mapped back
            XCTAssertLessThan(hypot(rx - p.0, ry - p.1), tolerance, "point \(p) off by \(hypot(rx - p.0, ry - p.1))", file: file, line: line)
        }
    }

    func testIdentity() {
        assertRecovers(.identity, current: sketch())
    }

    func testShift() {
        let moved = Affine2(tx: 17, ty: -9)
        assertRecovers(moved, current: sketch(moved))
    }

    func testShiftRotateScale() {
        let a = 3.0 * .pi / 180, s = 1.05
        let moved = Affine2(a: s * cos(a), b: -s * sin(a), tx: 12, c: s * sin(a), d: s * cos(a), ty: -14)
        // About the image center, as perspective drift would be roughly.
        let centered = Affine2(a: moved.a, b: moved.b, tx: 240 - moved.a * 240 - moved.b * 120 + 12,
                               c: moved.c, d: moved.d, ty: 120 - moved.c * 240 - moved.d * 120 - 14)
        assertRecovers(centered, current: sketch(centered), tolerance: 1.5)
    }

    func testNewInkAndAHandDoNotPullItOff() {
        let moved = Affine2(tx: -11, ty: 6)
        // New tracing and a hand-sized smudge, in sketch coordinates.
        let current = sketch(moved, extraInk: [((100, 180), (180, 230)), ((380, 150), (440, 210)), ((300, 200), (380, 200))],
                             blob: (x: 420, y: 60, r: 35))
        assertRecovers(moved, current: current, tolerance: 1.5)
    }

    func testBlankPageOrDrawingOutOfViewGivesNoAnswer() {
        XCTAssertNil(DrawingAligner(reference: [Float](repeating: 225, count: W * H), width: W, height: H))
        let aligner = try! XCTUnwrap(DrawingAligner(reference: sketch(), width: W, height: H))
        XCTAssertNil(aligner.align(current: [Float](repeating: 225, count: W * H)))
    }

    func testAffineInverse() {
        let t = Affine2(a: 1.1, b: 0.05, tx: 4, c: -0.03, d: 0.95, ty: -7)
        let back = t.inverse!.apply(PaperPoint(x: 120, y: 80))
        let p = t.apply(back)
        XCTAssertEqual(p.x, 120, accuracy: 1e-9)
        XCTAssertEqual(p.y, 80, accuracy: 1e-9)
    }

    func testFastEnough() {
        let aligner = try! XCTUnwrap(DrawingAligner(reference: sketch(), width: W, height: H))
        let current = sketch(Affine2(tx: 20, ty: 10))
        measure { _ = aligner.align(current: current) }
    }
}
