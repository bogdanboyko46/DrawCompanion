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
    /// Just the drawn figure on a transparent background, page-framed.
    var cutout: CGImage?
    /// Just the figure, cropped onto white: what gets sent for generation.
    var figureJPEG: Data?
    /// World-space corners (TL, TR, BR, BL as seen on screen). Nil if the
    /// paper couldn't be raycast; a stand-in rectangle is used instead.
    var worldCorners: [SIMD3<Float>]
    /// Paper frame: x along the top edge, y up from the desk, z toward the bottom edge.
    var transform: simd_float4x4
    var size: SIMD2<Float>
    var measured: Bool
    /// Where the drawn figure is in the frame (fractions, top-left origin), if found.
    var figureBox: CGRect? = nil

    /// The figure's real height on the surface, in meters (its padding removed).
    var figureHeight: Float? {
        guard measured, let b = figureBox else { return nil }
        return Float(max(0.01, b.height - 0.06)) * size.y
    }

    /// The world transform of the point between the figure's feet, on the surface,
    /// so the character stands exactly where it was drawn.
    var feetTransform: simd_float4x4? {
        guard measured, let b = figureBox else { return nil }
        let x = Float(b.midX - 0.5) * size.x
        let z = Float(b.maxY - 0.03 - 0.5) * size.y
        var t = transform
        t.columns.3 = transform * SIMD4<Float>(x, 0, z, 1)
        return t
    }
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
        // An edge can show the table, a doodle or a shadow; the brightest one is
        // most likely bare paper. If even that is dark, there's no paper to
        // calibrate against (a dark table all round): leave the colors alone.
        let samples = strips.compactMap { averageLinear(image, in: $0) }.sorted { $0.reduce(0, +) < $1.reduce(0, +) }
        guard let brightest = samples.last, (brightest.max() ?? 0) > 0.25 else { return image }
        let paper = (0..<3).map { max(0.2, brightest[$0]) }
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

    /// The one figure on the page, separated from everything else on the paper.
    struct Isolated {
        /// Page-sized, transparent except the figure (lines up with the paper for the reveal).
        var cutout: CGImage
        /// Just the figure, cropped, on pure white: what gets sent to generation.
        var figure: CGImage
        var figureJPEG: Data
        /// Where the figure is on the page, as fractions with a top-left origin.
        var box: CGRect
    }

    /// Finds the single main figure and drops everything else: paper edges and
    /// shadows, specks, writing, and other doodles. Strokes that are close
    /// together (a stick arm next to a body) count as one figure.
    /// Prints the figure finder's internals (for tuning on real captures).
    nonisolated(unsafe) static var debug = false

    static func isolate(_ image: CGImage) -> Isolated? {
        let source = flattened(CIImage(cgImage: image))
        let e = source.extent
        let drawn = drawnMask(source, image)

        // Work on a coarse grid to find connected shapes. Bitmap row 0 is the top.
        let gw = 160, gh = max(8, Int((CGFloat(gw) * e.height / e.width).rounded()))
        // Paper grain is scattered specks; strokes are continuous. A slight blur
        // fades the specks and barely touches a line, so the shrink below (which
        // keeps the strongest value in each cell) isn't filled with grain.
        let despeckled = drawn.clampedToExtent().applyingGaussianBlur(sigma: Double(max(1.5, e.width / 700)))
        // Spread each line over its grid cell first, so thin pencil survives the shrink.
        let pool = CIFilter.morphologyMaximum()
        pool.inputImage = despeckled
        pool.radius = Float(e.width / CGFloat(gw) / 2 + 1)
        let pooled = (pool.outputImage ?? drawn).cropped(to: e)
        let small = pooled.transformed(by: CGAffineTransform(scaleX: CGFloat(gw) / e.width, y: CGFloat(gh) / e.height))
        var px = [UInt8](repeating: 0, count: gw * gh * 4)
        ciContext.render(small, toBitmap: &px, rowBytes: gw * 4, bounds: CGRect(x: 0, y: 0, width: gw, height: gh),
                         format: .RGBA8, colorSpace: nil)
        // Ignore a thin band at the page edge: that's where paper edges, table and shadow show up.
        let border = max(3, gw * 45 / 1000)
        // What counts as ink is relative to this drawing's own strongest strokes:
        // writing showing through from the back of the page, smudges and paper
        // texture are much fainter than the lines someone actually drew.
        var levels: [UInt8] = []
        for y in border..<(gh - border) {
            for x in border..<(gw - border) where px[(y * gw + x) * 4] > 40 { levels.append(px[(y * gw + x) * 4]) }
        }
        levels.sort()
        let strong = levels.isEmpty ? 255 : Int(levels[min(levels.count - 1, levels.count * 99 / 100)])
        // Line work covers at most ~8% of the frame. On grainy paper the grain
        // reaches the usual cutoff too, so raise it until only the strongest 8%
        // of cells remain (the strokes themselves are at full strength).
        let cells = (gw - 2 * border) * (gh - 2 * border)
        let base = max(90, strong * 55 / 100)
        let aboveBase = levels.count - (levels.firstIndex { Int($0) > base } ?? levels.count)
        let grainy = aboveBase > cells * 12 / 100
        let topEight = grainy && levels.count > cells * 8 / 100 ? Int(levels[levels.count - cells * 8 / 100]) : 0
        let threshold = UInt8(min(235, max(base, topEight)))
        var ink = [Bool](repeating: false, count: gw * gh)
        for y in border..<(gh - border) {
            for x in border..<(gw - border) where px[(y * gw + x) * 4] > threshold { ink[y * gw + x] = true }
        }
        // Bridge small gaps so a figure drawn with separate strokes stays one shape.
        let reach = 2
        var grown = [Bool](repeating: false, count: gw * gh)
        for y in 0..<gh {
            for x in 0..<gw where ink[y * gw + x] {
                for dy in -reach...reach {
                    for dx in -reach...reach {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, ny >= 0, nx < gw, ny < gh { grown[ny * gw + nx] = true }
                    }
                }
            }
        }
        // Connected shapes; keep the one with the most ink near the middle of the
        // frame. Shapes running into the frame's edge are usually something cut
        // off (a paper edge, the table), so they count for much less.
        var label = [Int](repeating: -1, count: gw * gh)
        var best = (score: 0.0, id: -1)
        var count = 0
        for start in 0..<(gw * gh) where grown[start] && label[start] < 0 {
            var stack = [start]
            label[start] = count
            var inkCount = 0, sx = 0, sy = 0
            var touchesEdge = false
            while let i = stack.popLast() {
                if ink[i] { inkCount += 1; sx += i % gw; sy += i / gw }
                let ex = i % gw, ey = i / gw
                if ex <= border + 1 || ey <= border + 1 || ex >= gw - border - 2 || ey >= gh - border - 2 { touchesEdge = true }
                let x = i % gw, y = i / gw
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < gw && ny < gh && grown[ny * gw + nx] && label[ny * gw + nx] < 0 {
                    label[ny * gw + nx] = count
                    stack.append(ny * gw + nx)
                }
            }
            if inkCount > 0 {
                let cx = Double(sx) / Double(inkCount) / Double(gw) - 0.5
                let cy = Double(sy) / Double(inkCount) / Double(gh) - 0.5
                let centered = max(0.05, 1 - 1.8 * (cx * cx + cy * cy).squareRoot())
                let score = Double(inkCount) * centered * (touchesEdge ? 0.25 : 1)
                if score > best.score { best = (score, count) }
            }
            count += 1
        }
        if debug {
            let inkCells = ink.filter { $0 }.count
            print("[isolate] strong=\(strong) threshold=\(threshold) ink=\(inkCells * 100 / (gw * gh))% shapes=\(count) best=\(best.id) score=\(Int(best.score))")
        }
        guard best.id >= 0 else { return nil }

        // The chosen shape as a mask, and its bounding box.
        var region = [UInt8](repeating: 0, count: gw * gh)
        var minX = gw, minY = gh, maxX = -1, maxY = -1
        for i in 0..<(gw * gh) where label[i] == best.id {
            region[i] = 255
            if ink[i] {
                let x = i % gw, y = i / gw
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        // Areas enclosed by the figure (a face inside its outline) belong to it:
        // anything the outside can't reach without crossing the shape.
        var outside = [Bool](repeating: false, count: gw * gh)
        var queue = [Int]()
        for x in 0..<gw { queue.append(x); queue.append((gh - 1) * gw + x) }
        for y in 0..<gh { queue.append(y * gw); queue.append(y * gw + gw - 1) }
        while let i = queue.popLast() {
            guard !outside[i], region[i] == 0 else { continue }
            outside[i] = true
            let x = i % gw, y = i / gw
            if x > 0 { queue.append(i - 1) }
            if x < gw - 1 { queue.append(i + 1) }
            if y > 0 { queue.append(i - gw) }
            if y < gh - 1 { queue.append(i + gw) }
        }
        for i in 0..<(gw * gh) where region[i] == 0 && !outside[i] { region[i] = 255 }
        // The solid body: the filled shape shrunk back by the bridging distance,
        // so it hugs the strokes instead of spilling past them.
        var interior = [UInt8](repeating: 0, count: gw * gh)
        for y in 0..<gh {
            for x in 0..<gw where region[y * gw + x] != 0 {
                var solid = true
                search: for dy in -reach...reach {
                    for dx in -reach...reach {
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || ny < 0 || nx >= gw || ny >= gh || region[ny * gw + nx] == 0 { solid = false; break search }
                    }
                }
                if solid { interior[y * gw + x] = 255 }
            }
        }
        let inkArea = Double((maxX - minX + 1) * (maxY - minY + 1)) / Double(gw * gh)
        guard maxX >= minX, inkArea > 0.002 else { return nil }

        let regionImage = CIImage(bitmapData: Data(region), bytesPerRow: gw, size: CGSize(width: gw, height: gh),
                                  format: .L8, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(gw), y: e.height / CGFloat(gh)))
            .applyingGaussianBlur(sigma: e.width / CGFloat(gw))
            .cropped(to: e)
        let interiorImage = CIImage(bitmapData: Data(interior), bytesPerRow: gw, size: CGSize(width: gw, height: gh),
                                    format: .L8, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(gw), y: e.height / CGFloat(gh)))
            .applyingGaussianBlur(sigma: e.width / CGFloat(gw) * 0.7)
            .cropped(to: e)
        // Crisp strokes plus filled interiors, clipped to the chosen shape.
        let strokesAndFill = CIFilter.maximumCompositing()
        strokesAndFill.inputImage = drawn
        strokesAndFill.backgroundImage = interiorImage
        let keep = CIFilter.multiplyCompositing()
        keep.inputImage = strokesAndFill.outputImage ?? drawn
        keep.backgroundImage = regionImage
        let mask = keep.outputImage ?? drawn

        // Box in page fractions (top-left origin), padded a little.
        let pad = 0.03
        let box = CGRect(x: Double(minX) / Double(gw), y: Double(minY) / Double(gh),
                         width: Double(maxX - minX + 1) / Double(gw), height: Double(maxY - minY + 1) / Double(gh))
            .insetBy(dx: -pad, dy: -pad)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        // Page-framed cutout for the reveal.
        let clear = CIFilter.blendWithMask()
        clear.inputImage = source
        clear.backgroundImage = CIImage.empty()
        clear.maskImage = mask
        // The figure alone on white, cropped to its box with some breathing room.
        let white = CIImage(color: .white).cropped(to: e)
        let onWhite = CIFilter.blendWithMask()
        onWhite.inputImage = source
        onWhite.backgroundImage = white
        onWhite.maskImage = mask
        let crop = CGRect(x: e.minX + box.minX * e.width, y: e.minY + (1 - box.maxY) * e.height,
                          width: box.width * e.width, height: box.height * e.height).integral
        let margin = max(crop.width, crop.height) * 0.12
        let canvas = crop.insetBy(dx: -margin, dy: -margin)
        guard let cutoutOut = clear.outputImage, let figureOut = onWhite.outputImage,
              let cutout = ciContext.createCGImage(cutoutOut.cropped(to: e), from: e),
              let figure = ciContext.createCGImage(
                  figureOut.cropped(to: crop).composited(over: CIImage(color: .white).cropped(to: canvas)), from: canvas),
              let jpeg = ciContext.jpegRepresentation(
                  of: CIImage(cgImage: figure), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                  options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
        else { return nil }
        return Isolated(cutout: cutout, figure: figure, figureJPEG: jpeg, box: box)
    }

    /// The image divided by its own paper brightness, so blank paper becomes
    /// pure white everywhere (shadows, lamp falloff and gray paper included)
    /// while drawn marks keep their contrast.
    static func flattened(_ image: CIImage) -> CIImage {
        let e = image.extent
        let radius = Float(max(4, min(e.width, e.height) * 0.02))
        // Closing erases strokes, leaving the paper's own brightness.
        let grow = CIFilter.morphologyMaximum()
        grow.inputImage = image.clampedToExtent()
        grow.radius = radius
        let shrink = CIFilter.morphologyMinimum()
        shrink.inputImage = grow.outputImage
        shrink.radius = radius
        guard let paper = shrink.outputImage?.applyingGaussianBlur(sigma: Double(radius)).cropped(to: e) else { return image }
        let divide = CIFilter.divideBlendMode() // background / input
        divide.inputImage = paper
        divide.backgroundImage = image
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = divide.outputImage
        return (clamp.outputImage ?? image).cropped(to: e)
    }

    /// What counts as drawn. Interiors (a white face inside its outline) are
    /// filled in by `isolate`, so no subject detection is needed here.
    static func drawnMask(_ source: CIImage, _ image: CGImage) -> CIImage {
        inkMask(source)
    }

    /// The subject of a rendered image (the concept on its plain background),
    /// cropped to it. Apple's subject lift is made for exactly this.
    static func subjectCutout(_ image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first, !obs.allInstances.isEmpty,
              let masked = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
        else { return nil }
        let ci = CIImage(cvPixelBuffer: masked)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    /// Transparent-background version of a drawing.
    static func cutout(_ image: CGImage) -> CGImage? {
        isolate(image)?.cutout
    }

    /// 1 where something is drawn, 0 on blank paper, soft at the edges.
    ///
    /// Two kinds of marks count, and neither is fooled by shadows or uneven light:
    /// - lines: thin features darker than their surroundings (a morphological
    ///   "black top-hat", which is zero on smooth gradients like a soft shadow);
    /// - color: saturated areas such as crayon fills (shadows are grayish).
    static func inkMask(_ image: CIImage) -> CIImage {
        let e = image.extent
        let darkest = CIFilter.minimumComponent()
        darkest.inputImage = image
        let brightest = CIFilter.maximumComponent()
        brightest.inputImage = image
        guard let d = darkest.outputImage?.cropped(to: e), let b = brightest.outputImage?.cropped(to: e) else { return image }

        // Lines: close the image (max then min) to erase thin dark strokes, then
        // see how much darker each pixel is than that.
        let radius = Float(max(4, min(e.width, e.height) * 0.015))
        let grow = CIFilter.morphologyMaximum()
        grow.inputImage = d.clampedToExtent()
        grow.radius = radius
        let shrink = CIFilter.morphologyMinimum()
        shrink.inputImage = grow.outputImage
        shrink.radius = radius
        let lines = CIFilter.subtractBlendMode() // background - input
        lines.inputImage = d
        lines.backgroundImage = (shrink.outputImage ?? d).cropped(to: e)

        // Color: how far the brightest channel is above the darkest.
        let chroma = CIFilter.subtractBlendMode()
        chroma.inputImage = d
        chroma.backgroundImage = b

        func ramp(_ input: CIImage?, gain k: CGFloat, floor: CGFloat) -> CIImage? {
            let m = CIFilter.colorMatrix()
            m.inputImage = input
            m.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
            m.biasVector = CIVector(x: -k * floor, y: -k * floor, z: -k * floor, w: 0)
            let c = CIFilter.colorClamp()
            c.inputImage = m.outputImage
            return c.outputImage
        }
        // Values are in linear light: a pencil line is ~0.15–0.4 darker than the paper
        // around it; paper grain, JPEG noise and writing showing through from the
        // back of the page stay under ~0.07. Crayon colors are
        // well above 0.3 chroma; a bluish shadow on white paper stays under ~0.2.
        // Very dark areas (a black-filled shape, wider than any line) count too;
        // a shadow on white paper never gets that dark.
        let inverted = CIFilter.colorInvert()
        inverted.inputImage = d
        guard let lineMask = ramp(lines.outputImage, gain: 8, floor: 0.07),
              let colorMask = ramp(chroma.outputImage, gain: 6, floor: 0.22),
              let darkMask = ramp(inverted.outputImage, gain: 8, floor: 0.82) else { return image }
        let union = CIFilter.maximumCompositing()
        union.inputImage = lineMask
        union.backgroundImage = colorMask
        let all = CIFilter.maximumCompositing()
        all.inputImage = union.outputImage
        all.backgroundImage = darkMask
        return (all.outputImage ?? lineMask).cropped(to: e)
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
