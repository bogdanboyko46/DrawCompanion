// Runs the app's real PageScanner (Vision + Core Image) on synthetic phone
// photos with known paper corners, on macOS. CI: .github/workflows/ios.yml.
//
//   swiftc -O -o scanner ios/DrawCompanion3D/Capture/PageScanner.swift ios/ScannerTests/main.swift
//   ./scanner ios/ScannerTests/fixtures out/
//
// Checks: the page is found (and not found when absent), corners land on the
// paper and are ordered as seen on screen, the rectified page matches the
// original drawing, the lamp's tint is removed, and the figure cutout works.

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Fixture: Decodable {
    var file: String
    var page: Bool
    var corners: [[Double]]?
    var tint: [Double]
}
struct Cases: Decodable {
    var pageSize: [Double]
    var cases: [Fixture]
}

let args = CommandLine.arguments
let fixtures = URL(fileURLWithPath: args.count > 1 ? args[1] : "ios/ScannerTests/fixtures")
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "scanner-out")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let spec = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: fixtures.appendingPathComponent("cases.json")))
let ci = CIContext()
var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    print("  \(ok ? "✓" : "✗") \(what)")
    if !ok { failures.append(what) }
}

func load(_ url: URL) -> CGImage {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

func pixelBuffer(_ image: CGImage) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    ci.render(CIImage(cgImage: image), to: pb!)
    return pb!
}

func save(_ image: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// RGBA8 pixels of an image scaled to w×h.
func pixels(_ image: CIImage, _ w: Int, _ h: Int) -> [UInt8] {
    let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width, y: CGFloat(h) / image.extent.height))
        .transformed(by: CGAffineTransform(translationX: -image.extent.minX * CGFloat(w) / image.extent.width,
                                           y: -image.extent.minY * CGFloat(h) / image.extent.height))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    ci.render(scaled, toBitmap: &buf, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
              format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return buf
}

/// Mean absolute grayscale difference (0–255) between two images at 105×148-ish.
func difference(_ a: CIImage, _ b: CIImage) -> Double {
    let w = 70, h = 99
    let pa = pixels(a, w, h), pb = pixels(b, w, h)
    var sum = 0.0
    for i in stride(from: 0, to: pa.count, by: 4) {
        let ga = (Double(pa[i]) + Double(pa[i + 1]) + Double(pa[i + 2])) / 3
        let gb = (Double(pb[i]) + Double(pb[i + 1]) + Double(pb[i + 2])) / 3
        sum += abs(ga - gb)
    }
    return sum / Double(w * h)
}

/// Average color of a region given in fractions of the image (origin top-left).
func average(_ image: CIImage, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> [Double] {
    let e = image.extent
    let rect = CGRect(x: e.minX + x * e.width, y: e.minY + (1 - y - h) * e.height, width: w * e.width, height: h * e.height)
    let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: rect)])!
    var px = [UInt8](repeating: 0, count: 4)
    ci.render(f.outputImage!, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
              format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return px.prefix(3).map(Double.init)
}

/// A small JPEG, base64, so results can be looked at straight from the CI log.
func thumbnail(_ image: CGImage, maxSide: CGFloat = 240) -> String {
    var ciImage = CIImage(cgImage: image)
    let scale = maxSide / max(ciImage.extent.width, ciImage.extent.height)
    ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    // Show transparency over a dark backdrop.
    ciImage = ciImage.composited(over: CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.3)).cropped(to: ciImage.extent))
    let data = ci.jpegRepresentation(of: ciImage, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]) ?? Data()
    return data.base64EncodedString()
}

let original = CIImage(cgImage: load(fixtures.appendingPathComponent("drawing-original.png")))

for c in spec.cases {
    print("\n\(c.file)")
    let image = load(fixtures.appendingPathComponent(c.file))
    let W = Double(image.width), H = Double(image.height)
    let buffer = pixelBuffer(image)
    // "Screen" = the photo itself, upright: Vision (bottom-left origin) → pixels (top-left).
    let toView: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * W, y: (1 - $0.y) * H) }

    let started = Date()
    let page = PageScanner.detect(in: buffer, viewTransform: toView)
    let ms = Int(Date().timeIntervalSince(started) * 1000)

    guard c.page, let truth = c.corners else {
        check(page == nil, "no page reported when there's no paper (\(ms) ms)")
        continue
    }
    guard let page else {
        check(false, "page detected")
        continue
    }
    check(true, "page detected, confidence \(String(format: "%.2f", page.confidence)) (\(ms) ms)")

    // Corners: each lands on a true corner, in screen order (TL, TR, BR, BL as seen).
    let found = page.imageCorners.map(toView)
    let truthPts = truth.map { CGPoint(x: $0[0], y: $0[1]) }
    let expected = PageScanner.orderedForScreen(truthPts.map { CGPoint(x: $0.x / W, y: 1 - $0.y / H) }, toView).map(toView)
    let errors = zip(found, expected).map { hypot($0.x - $1.x, $0.y - $1.y) / W * 100 }
    check(errors.allSatisfy { $0 < 2.5 }, "corners on the paper, in screen order (worst \(String(format: "%.1f", errors.max()!))% of width)")

    // Rectify to the paper's real proportions as seen on screen.
    let top = hypot(expected[1].x - expected[0].x, expected[1].y - expected[0].y)
    let side = hypot(expected[3].x - expected[0].x, expected[3].y - expected[0].y)
    let portrait = side > top
    let aspect = portrait ? spec.pageSize[0] / spec.pageSize[1] : spec.pageSize[1] / spec.pageSize[0]
    guard let result = PageScanner.rectify(buffer, page: page, aspect: aspect) else {
        check(false, "rectify produced an image")
        continue
    }
    let rectified = result.1
    let name = c.file.replacingOccurrences(of: ".jpg", with: "")
    save(rectified, "\(name)-rectified.png")
    let out = CIImage(cgImage: rectified)
    check(abs(Double(rectified.width) / Double(rectified.height) - aspect) < 0.01,
          "rectified to \(rectified.width)×\(rectified.height) (paper aspect \(String(format: "%.3f", aspect)))")

    // Compare with the original drawing, turned the way it lies on screen.
    let reference = portrait ? original : original.oriented(.right)
    let diff = difference(out, reference)
    let otherWay = portrait ? difference(out, original.oriented(.down)) : difference(out, original.oriented(.left))
    check(diff < 22 && diff < otherWay, "matches the original drawing, right way up for the screen (diff \(String(format: "%.1f", diff)) vs \(String(format: "%.1f", otherWay)) flipped)")

    // Colors: the drawing's own colors survive (not washed out or tinted).
    // Regions in page fractions (u right, v down) on the original drawing.
    let regions: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        ("orange body", 0.31, 0.55, 0.04, 0.04),
        ("cream belly", 0.47, 0.60, 0.06, 0.05),
        ("blue scarf", 0.40, 0.415, 0.08, 0.02),
    ]
    for (label, u, v, du, dv) in regions {
        let want = average(original, x: u, y: v, w: du, h: dv)
        // On screen a turned page is rotated 90° clockwise: page (u, v) → screen (1 - v, u).
        let got = portrait ? average(out, x: u, y: v, w: du, h: dv) : average(out, x: 1 - v - dv, y: u, w: dv, h: du)
        let worst = zip(want, got).map { abs($0 - $1) }.max()!
        check(worst < 40, "\(label) keeps its color: \(got.map { Int($0) }) vs drawn \(want.map { Int($0) })")
    }
    print("THUMB \(name)-rectified \(thumbnail(rectified))")

    // White balance: blank paper should come out neutral and bright.
    // Sample a blank margin of the page (the drawing's top-left area is empty).
    let rawCorner = average(CIImage(cgImage: image),
                            x: CGFloat(truthPts.map(\.x).min()! / W + 0.02), y: CGFloat(truthPts.map(\.y).min()! / H + 0.02),
                            w: 0.015, h: 0.015)
    let paper = portrait ? average(out, x: 0.04, y: 0.04, w: 0.12, h: 0.06) : average(out, x: 0.04, y: 0.80, w: 0.06, h: 0.12)
    let spread = paper.max()! - paper.min()!
    let rawSpread = rawCorner.max()! - rawCorner.min()!
    check(spread < 14 && paper.min()! > 200,
          "paper comes out white: RGB \(paper.map { Int($0) }) (photo had \(rawCorner.map { Int($0) }))")
    if rawSpread > 30 { check(spread < rawSpread / 3, "lamp tint removed (channel spread \(Int(rawSpread)) → \(Int(spread)))") }

    // Cutout for the portal: the figure lifted off the paper, aligned with the page.
    let started2 = Date()
    if let cut = PageScanner.cutout(rectified, cropped: false) {
        save(cut, "\(name)-cutout.png")
        print("THUMB \(name)-cutout \(thumbnail(cut))")
        let px = pixels(CIImage(cgImage: cut), 64, 90)
        let coverage = Double(stride(from: 3, to: px.count, by: 4).filter { px[$0] > 128 }.count) / Double(64 * 90)
        check(cut.width == rectified.width && cut.height == rectified.height, "cutout keeps the page frame (\(cut.width)×\(cut.height))")
        check(coverage > 0.08 && coverage < 0.6,
              "cutout isolates the figure: \(Int(coverage * 100))% of the page (\(Int(Date().timeIntervalSince(started2) * 1000)) ms)")
    } else {
        check(false, "foreground cutout found the figure")
    }
}

print(failures.isEmpty ? "\nAll scanner checks passed." : "\n\(failures.count) check(s) failed:\n- " + failures.joined(separator: "\n- "))
exit(failures.isEmpty ? 0 : 1)
