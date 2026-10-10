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

final class PageEnhanceTests: XCTestCase {
    func testDimYellowPaperBecomesWhiteAndPencilDarker() {
        let w = 100, h = 100
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let pencil = i % w < 5 // 5% of the page is pencil
            let c: (UInt8, UInt8, UInt8) = pencil ? (110, 105, 90) : (180, 170, 140)
            px[i * 4] = c.0; px[i * 4 + 1] = c.1; px[i * 4 + 2] = c.2; px[i * 4 + 3] = 255
        }
        let out = PageEnhance.enhanced(rgba: px, width: w, height: h)
        let paper = Array(out[(50 * 4)..<(50 * 4 + 3)])
        XCTAssertTrue(paper.allSatisfy { $0 > 230 }, "paper \(paper)")
        XCTAssertLessThan(abs(Int(paper[0]) - Int(paper[2])), 6, "tint removed")
        let pencil = Int(out[0]), paperR = Int(paper[0])
        XCTAssertGreaterThan(paperR - pencil, 180 - 110, "pencil stands out more than before")
    }
}

final class PageRegionTests: XCTestCase {
    func page(w: Int, h: Int, ink: [(Int, Int)]) -> [UInt8] {
        var px = [UInt8](repeating: 230, count: w * h * 4)
        for (x, y) in ink {
            let i = (y * w + x) * 4
            px[i] = 70; px[i + 1] = 70; px[i + 2] = 70
        }
        return px
    }

    func testFindsASmallDrawingWithMargin() {
        // 1000 x 500 units at 2 units per pixel; ink square at units 400-500, 100-200.
        var ink: [(Int, Int)] = []
        for x in 200...250 { ink.append((x, 50)); ink.append((x, 100)) }
        for y in 50...100 { ink.append((200, y)); ink.append((250, y)) }
        let r = PageRegion.focus(rgba: page(w: 500, h: 250, ink: ink), width: 500, height: 250, paper: PaperSize(w: 1000, h: 500))
        let box = try! XCTUnwrap(r)
        XCTAssertLessThan(box.x, 400); XCTAssertGreaterThan(box.x + box.w, 500)
        XCTAssertLessThan(box.y, 100); XCTAssertGreaterThan(box.y + box.h, 200)
        XCTAssertGreaterThanOrEqual(box.w, 300)
        XCTAssertGreaterThanOrEqual(box.x, 0); XCTAssertLessThanOrEqual(box.x + box.w, 1000)
    }

    func testBlankPageAndFullPageDrawingNeedNoCloseUp() {
        XCTAssertNil(PageRegion.focus(rgba: page(w: 200, h: 100, ink: []), width: 200, height: 100, paper: PaperSize(w: 1000, h: 500)))
        var ink: [(Int, Int)] = []
        for x in 10..<190 { ink.append((x, 10)); ink.append((x, 89)) }
        XCTAssertNil(PageRegion.focus(rgba: page(w: 200, h: 100, ink: ink), width: 200, height: 100, paper: PaperSize(w: 1000, h: 500)))
    }
}
