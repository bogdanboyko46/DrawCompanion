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

    /// Divide out the lamp's tint: treat the bright end of the page as paper white.
    static func whiteBalanced(_ image: CIImage) -> CIImage {
        let avg = CIFilter.areaAverage()
        avg.inputImage = image
        avg.extent = image.extent
        guard let pixel = avg.outputImage else { return image }
        var rgba = [UInt8](repeating: 0, count: 4)
        ciContext.render(pixel, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        // The average includes ink, so lift it toward the paper before using it as white,
        // then divide it out (Core Image filters work in linear light).
        let paper = rgba.prefix(3).map { CGFloat(min(1, max(0.35, Double($0) / 255 * 1.08))) }
        let gain = CIFilter.colorMatrix()
        gain.inputImage = image
        gain.rVector = CIVector(x: 1 / paper[0], y: 0, z: 0, w: 0)
        gain.gVector = CIVector(x: 0, y: 1 / paper[1], z: 0, w: 0)
        gain.bVector = CIVector(x: 0, y: 0, z: 1 / paper[2], w: 0)
        let controls = CIFilter.colorControls()
        controls.inputImage = gain.outputImage ?? image
        controls.contrast = 1.08
        controls.saturation = 1.12
        return controls.outputImage ?? image
    }

    /// Lifts the drawn figure off the paper so it can float as a cutout.
    /// `cropped: false` keeps the page's frame, so the cutout lines up with the paper.
    static func cutout(_ image: CGImage, cropped: Bool = true) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
            guard let obs = request.results?.first, !obs.allInstances.isEmpty else { return nil }
            let masked = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: cropped)
            let ci = CIImage(cvPixelBuffer: masked)
            return ciContext.createCGImage(ci, from: ci.extent)
        } catch {
            return nil
        }
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
