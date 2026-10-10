// No ARKit or UIKit here: this file also builds on macOS for the scanner tests
// (ios/ScannerTests). The ARFrame helper lives in ARFrame+ViewMapping.swift.
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import simd
import Vision

/// A sheet of paper found in a camera frame.
struct DetectedPage: Sendable {
    /// Corners in Vision's normalized image space (origin bottom-left), ordered
    /// top-left, top-right, bottom-right, bottom-left *as seen on screen*.
    var imageCorners: [CGPoint]
    var confidence: Float
}

/// The page as captured for generation: an upright, perspective-corrected,
/// white-balanced photo, plus where the paper sits in the world.
struct CapturedPage {
    var jpeg: Data
    var image: CGImage
    /// Just the drawn figure on a transparent background, when Vision can find it.
    var cutout: CGImage?
    /// World-space corners (TL, TR, BR, BL as seen on screen). Nil if the
    /// paper couldn't be raycast; a stand-in rectangle is used instead.
    var worldCorners: [SIMD3<Float>]
    /// Paper frame: x along the top edge, y up from the desk, z toward the bottom edge.
    var transform: simd_float4x4
    var size: SIMD2<Float>
    var measured: Bool
}

enum PageScanner {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Finds the most prominent document in a camera image. Runs off the main thread.
    static func detect(in pixelBuffer: CVPixelBuffer, viewTransform: (CGPoint) -> CGPoint) -> DetectedPage? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let obs = request.results?.first, obs.confidence > 0.6 else { return nil }
        let corners = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft]
        return DetectedPage(imageCorners: orderedForScreen(corners, viewTransform), confidence: obs.confidence)
    }

    /// The camera image is in sensor orientation (landscape). Order the corners
    /// by where they land on screen so the rectified page comes out upright for
    /// the person holding the phone, however the paper is turned.
    static func orderedForScreen(_ corners: [CGPoint], _ toView: (CGPoint) -> CGPoint) -> [CGPoint] {
        let pairs = corners.map { ($0, toView($0)) }
        let tl = pairs.min { $0.1.x + $0.1.y < $1.1.x + $1.1.y }!
        let br = pairs.max { $0.1.x + $0.1.y < $1.1.x + $1.1.y }!
        let tr = pairs.max { $0.1.x - $0.1.y < $1.1.x - $1.1.y }!
        let bl = pairs.min { $0.1.x - $0.1.y < $1.1.x - $1.1.y }!
        let ordered = [tl.0, tr.0, br.0, bl.0]
        // Degenerate (very rotated) quads can map two roles to one corner; fall back to angle order.
        if Set(ordered.map { "\($0.x),\($0.y)" }).count == 4 { return ordered }
        let c = pairs.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.1.x / 4, y: $0.y + $1.1.y / 4) }
        let sorted = pairs.sorted { atan2($0.1.y - c.y, $0.1.x - c.x) < atan2($1.1.y - c.y, $1.1.x - c.x) }
        // atan2 with y down sorts clockwise starting near the left; rotate so the top-left comes first.
        let start = sorted.firstIndex { $0.0 == tl.0 } ?? 0
        return (0..<4).map { sorted[(start + $0) % 4].0 }
    }

    /// Perspective-corrects the page to `aspect` (width / height), balances it
    /// against the paper's own white, and returns JPEG + image.
    static func rectify(_ pixelBuffer: CVPixelBuffer, page: DetectedPage, aspect: CGFloat, longSide: CGFloat = 1536) -> (Data, CGImage)? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let w = image.extent.width, h = image.extent.height
        let p = page.imageCorners.map { CGPoint(x: $0.x * w, y: $0.y * h) }

        let correct = CIFilter.perspectiveCorrection()
        correct.inputImage = image
        correct.topLeft = p[0]
        correct.topRight = p[1]
        correct.bottomRight = p[2]
        correct.bottomLeft = p[3]
        guard var out = correct.outputImage else { return nil }

        // Resample to the paper's real proportions.
        let targetW = aspect >= 1 ? longSide : longSide * aspect
        let targetH = aspect >= 1 ? longSide / aspect : longSide
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        out = out.transformed(by: CGAffineTransform(scaleX: targetW / out.extent.width, y: targetH / out.extent.height))

        out = whiteBalanced(out)
        let rect = CGRect(x: 0, y: 0, width: targetW.rounded(), height: targetH.rounded())
        guard let cg = ciContext.createCGImage(out, from: rect),
              let jpeg = ciContext.jpegRepresentation(
                  of: CIImage(cgImage: cg),
                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                  options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.88])
        else { return nil }
        return (jpeg, cg)
    }

    /// Stand-in when no paper is found: the middle of the frame, upright.
    static func centerCrop(_ pixelBuffer: CVPixelBuffer, toView: (CGPoint) -> CGPoint) -> (Data, CGImage)? {
        let inset: CGFloat = 0.2
        let corners = [CGPoint(x: inset, y: 1 - inset), CGPoint(x: 1 - inset, y: 1 - inset),
                       CGPoint(x: 1 - inset, y: inset), CGPoint(x: inset, y: inset)]
        let page = DetectedPage(imageCorners: orderedForScreen(corners, toView), confidence: 0)
        return rectify(pixelBuffer, page: page, aspect: 0.75)
    }

    /// Divide out the lamp's tint, using the page's blank margins as paper white.
    /// Nothing else is touched: the scan should be faithful, styling happens later.
    static func whiteBalanced(_ image: CIImage) -> CIImage {
        let e = image.extent
        let inset: CGFloat = 0.015, depth: CGFloat = 0.03
        let strips = [
            CGRect(x: e.minX, y: e.maxY - e.height * (inset + depth), width: e.width, height: e.height * depth), // top
            CGRect(x: e.minX, y: e.minY + e.height * inset, width: e.width, height: e.height * depth),           // bottom
            CGRect(x: e.minX + e.width * inset, y: e.minY, width: e.width * depth, height: e.height),            // left
            CGRect(x: e.maxX - e.width * (inset + depth), y: e.minY, width: e.width * depth, height: e.height),  // right
        ]
        // A margin can hold a doodle or a shadow: take the median strip by brightness.
        let samples = strips.compactMap { averageLinear(image, in: $0) }.sorted { $0.reduce(0, +) < $1.reduce(0, +) }
        guard samples.count == 4 else { return image }
        let paper = (0..<3).map { max(0.3, (samples[1][$0] + samples[2][$0]) / 2) }
        let gain = CIFilter.colorMatrix()
        gain.inputImage = image
        gain.rVector = CIVector(x: 1 / paper[0], y: 0, z: 0, w: 0)
        gain.gVector = CIVector(x: 0, y: 1 / paper[1], z: 0, w: 0)
        gain.bVector = CIVector(x: 0, y: 0, z: 1 / paper[2], w: 0)
        return gain.outputImage ?? image
    }

    /// Average color of a region in linear light (Core Image's working space).
    static func averageLinear(_ image: CIImage, in rect: CGRect) -> [CGFloat]? {
        let avg = CIFilter.areaAverage()
        avg.inputImage = image
        avg.extent = rect
        guard let pixel = avg.outputImage else { return nil }
        var rgba = [Float](repeating: 0, count: 4)
        ciContext.render(pixel, toBitmap: &rgba, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        return rgba.prefix(3).map { CGFloat($0) }
    }

    /// Lifts the drawing off the paper so it can float as a cutout, keeping the
    /// page's frame so it lines up with the paper.
    ///
    /// Everything that's ink stays (subject-lift alone drops thin lines like
    /// stick arms); Vision's subject mask is added on top so solid white parts
    /// of the character don't turn see-through.
    static func cutout(_ image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        var mask = inkMask(source)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        if (try? handler.perform([request])) != nil,
           let obs = request.results?.first, !obs.allInstances.isEmpty,
           let subject = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
            let union = CIFilter.maximumCompositing()
            union.inputImage = CIImage(cvPixelBuffer: subject)
            union.backgroundImage = mask
            mask = union.outputImage ?? mask
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = source
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask
        guard let out = blend.outputImage else { return nil }
        return ciContext.createCGImage(out.cropped(to: source.extent), from: source.extent)
    }

    /// 1 where something is drawn, 0 on blank paper, soft at the edges.
    static func inkMask(_ image: CIImage) -> CIImage {
        // How far the darkest channel falls below paper white catches both dark
        // lines and light colors (a pale yellow still has a low blue channel).
        let darkest = CIFilter.minimumComponent()
        darkest.inputImage = image
        let k: CGFloat = 6, paperTolerance: CGFloat = 0.15 // uneven light on blank paper stays clear
        let ramp = CIFilter.colorMatrix()
        ramp.inputImage = darkest.outputImage
        ramp.rVector = CIVector(x: -k, y: 0, z: 0, w: 0)
        ramp.gVector = CIVector(x: 0, y: -k, z: 0, w: 0)
        ramp.bVector = CIVector(x: 0, y: 0, z: -k, w: 0)
        ramp.biasVector = CIVector(x: k * (1 - paperTolerance), y: k * (1 - paperTolerance), z: k * (1 - paperTolerance), w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = ramp.outputImage
        return (clamp.outputImage ?? image).cropped(to: image.extent)
    }

    /// Paper frame from its world corners (TL, TR, BR, BL).
    static func frame(from c: [SIMD3<Float>]) -> (simd_float4x4, SIMD2<Float>) {
        let center = (c[0] + c[1] + c[2] + c[3]) / 4
        let top = ((c[1] - c[0]) + (c[2] - c[3])) / 2
        let side = ((c[3] - c[0]) + (c[2] - c[1])) / 2
        var x = simd_normalize(top)
        var y = simd_normalize(simd_cross(side, top)) // up, out of the paper
        if y.y < 0 { y = -y }
        let z = simd_normalize(simd_cross(x, y))
        x = simd_normalize(simd_cross(y, z))
        let m = simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(center, 1))
        return (m, SIMD2(simd_length(top), simd_length(side)))
    }
}
