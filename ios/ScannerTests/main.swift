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

/// Highest alpha in a region (fractions, origin top-left).
func alphaMax(_ image: CIImage, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> Double {
    let e = image.extent
    let rect = CGRect(x: e.minX + x * e.width, y: e.minY + (1 - y - h) * e.height, width: w * e.width, height: h * e.height)
    let f = CIFilter(name: "CIAreaMaximumAlpha", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: rect)])!
    var px = [UInt8](repeating: 0, count: 4)
    ci.render(f.outputImage!, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
              format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return Double(px[3]) / 255
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
        check(worst < 30, "\(label) keeps its color: \(got.map { Int($0) }) vs drawn \(want.map { Int($0) })")
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

    // One figure, isolated: the character is kept whole (thin limbs too), and
    // the sun doodle, the scribble and the written name are left out.
    // Page fractions (u right, v down) map to screen fractions for a turned page.
    let toScreen: (CGFloat, CGFloat) -> (CGFloat, CGFloat) = { u, v in portrait ? (u, v) : (1 - v, u) }
    let started2 = Date()
    if let iso = PageScanner.isolate(rectified) {
        let ms = Int(Date().timeIntervalSince(started2) * 1000)
        save(iso.cutout, "\(name)-cutout.png")
        save(iso.figure, "\(name)-figure.png")
        print("THUMB \(name)-cutout \(thumbnail(iso.cutout))")
        print("THUMB \(name)-figure \(thumbnail(iso.figure))")
        check(iso.cutout.width == rectified.width && iso.cutout.height == rectified.height,
              "cutout keeps the page frame (\(iso.cutout.width)×\(iso.cutout.height), \(ms) ms)")
        let cutImage = CIImage(cgImage: iso.cutout)
        for (label, u, v) in [("stick arm", 0.214, 0.471), ("stick leg", 0.39, 0.81), ("body", 0.31, 0.57)] as [(String, CGFloat, CGFloat)] {
            let (x, y) = toScreen(u, v)
            let a = alphaMax(cutImage, x: x - 0.015, y: y - 0.015, w: 0.03, h: 0.03)
            check(a > 0.6, "keeps the \(label) (alpha \(String(format: "%.2f", a)))")
        }
        for (label, u, v) in [("sun doodle", 0.886, 0.074), ("scribble", 0.87, 0.95), ("written name", 0.08, 0.935)] as [(String, CGFloat, CGFloat)] {
            let (x, y) = toScreen(u, v)
            let a = alphaMax(cutImage, x: x - 0.02, y: y - 0.02, w: 0.04, h: 0.04)
            check(a < 0.2, "leaves out the \(label) (alpha \(String(format: "%.2f", a)))")
            check(!iso.box.contains(CGPoint(x: x, y: y)), "figure crop excludes the \(label)")
        }
        // The crop covers the whole character: page box (0.15, 0.12)–(0.85, 0.89).
        let corners = [toScreen(0.15, 0.12), toScreen(0.85, 0.89)]
        let want = CGRect(x: min(corners[0].0, corners[1].0), y: min(corners[0].1, corners[1].1),
                          width: abs(corners[0].0 - corners[1].0), height: abs(corners[0].1 - corners[1].1))
        check(iso.box.contains(want), "figure crop covers the whole character (box \(String(format: "%.2f,%.2f %.2f×%.2f", iso.box.minX, iso.box.minY, iso.box.width, iso.box.height)))")
        check(iso.figureJPEG.count > 10_000, "figure image for generation: \(iso.figure.width)×\(iso.figure.height), \(iso.figureJPEG.count / 1024) KB")
    } else {
        check(false, "isolated a figure")
    }
}

print(failures.isEmpty ? "\nAll scanner checks passed." : "\n\(failures.count) check(s) failed:\n- " + failures.joined(separator: "\n- "))
exit(failures.isEmpty ? 0 : 1)
