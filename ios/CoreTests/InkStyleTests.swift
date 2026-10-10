import XCTest
@testable import DrawCore

final class InkStyleTests: XCTestCase {
    /// A page of the given paper color with some lines of `ink` color.
    func page(paper: (UInt8, UInt8, UInt8), ink: (UInt8, UInt8, UInt8), thickness: Int, w: Int = 400, h: Int = 300) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        func set(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
            let i = (y * w + x) * 4
            px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2; px[i + 3] = 255
        }
        for y in 0..<h { for x in 0..<w { set(x, y, paper) } }
        for k in 0..<4 { // horizontal and vertical strokes
            for x in 50..<350 { for t in 0..<thickness { set(x, 40 + k * 60 + t, ink) } }
            for y in 20..<280 { for t in 0..<thickness { set(80 + k * 70 + t, y, ink) } }
        }
        return px
    }

    func testPencilGreyOnDimPaperIsMeasured() {
        let style = InkStyle.estimate(rgba: page(paper: (170, 165, 150), ink: (95, 95, 98), thickness: 2),
                                      width: 400, height: 300, paperWidth: 1000)
        XCTAssertEqual(style.red, 95 / 255, accuracy: 0.02)
        XCTAssertEqual(style.blue, 98 / 255, accuracy: 0.02)
        XCTAssertEqual(style.width, 5, accuracy: 0.1) // 2 px of 400 across a 1000-unit page
    }

    func testBluePenAndThickerLines() {
        let style = InkStyle.estimate(rgba: page(paper: (235, 235, 230), ink: (30, 60, 170), thickness: 4),
                                      width: 400, height: 300, paperWidth: 1000)
        XCTAssertGreaterThan(style.blue, style.red + 0.3)
        XCTAssertEqual(style.width, 10, accuracy: 0.1)
    }

    func testBlankPageFallsBack() {
        let blank = [UInt8](repeating: 220, count: 400 * 300 * 4)
        XCTAssertEqual(InkStyle.estimate(rgba: blank, width: 400, height: 300, paperWidth: 1000), .fallback)
    }
}
