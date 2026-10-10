import ARKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Top-down views of the page cut out of the camera image.
enum PageImaging {
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Perspective-corrects the page. corners: image pixels (origin top-left),
    /// ordered top-left, top-right, bottom-right, bottom-left.
    static func rectified(_ pixelBuffer: CVPixelBuffer, corners: [CGPoint], width: Int, height: Int) -> CIImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let h = image.extent.height
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        // Core Image's origin is bottom-left.
        filter.topLeft = CGPoint(x: corners[0].x, y: h - corners[0].y)
        filter.topRight = CGPoint(x: corners[1].x, y: h - corners[1].y)
        filter.bottomRight = CGPoint(x: corners[2].x, y: h - corners[2].y)
        filter.bottomLeft = CGPoint(x: corners[3].x, y: h - corners[3].y)
        guard var out = filter.outputImage, out.extent.width > 1, out.extent.height > 1 else { return nil }
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        return out.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / out.extent.width,
                                                     y: CGFloat(height) / out.extent.height))
    }

    /// Everything the AI needs from one camera frame: the whole page, an
    /// enlarged close-up of the drawing when it's small, and the ink style.
    /// The page is rectified once at high resolution and cut from there.
    static func photos(_ pixelBuffer: CVPixelBuffer, corners: [CGPoint], paper: PaperSize) -> (PagePhotos, InkStyle)? {
        let hiW = 1600
        let hiH = Int((Double(hiW) * paper.h / paper.w).rounded())
        guard let raw = rgba(pixelBuffer, corners: corners, width: hiW, height: hiH) else { return nil }
        // Ink style from the raw camera colors so the outline matches what's on screen.
        let style = InkStyle.estimate(rgba: raw, width: hiW, height: hiH, paperWidth: paper.w)
        let region = PageRegion.focus(rgba: raw, width: hiW, height: hiH, paper: paper)
        guard let page = cgImage(rgba: PageEnhance.enhanced(rgba: raw, width: hiW, height: hiH), width: hiW, height: hiH),
              let full = gridded(page, from: PaperRect(x: 0, y: 0, w: paper.w, h: paper.h), paper: paper, width: 768, step: 100)
        else { return nil }
        let closeUp = region.flatMap { gridded(page, from: $0, paper: paper, width: 900, step: 50) }
        return (PagePhotos(full: full, closeUp: closeUp, region: closeUp == nil ? nil : region), style)
    }

    /// Part of the page, scaled to `width` pixels, with a faint grid labeled in
    /// page coordinates every `step` units, which makes the model's coordinates
    /// much more accurate.
    private static func gridded(_ page: CGImage, from r: PaperRect, paper: PaperSize, width: Int, step: Int) -> Data? {
        let k = Double(page.width) / paper.w // page pixels per unit
        guard let crop = page.cropping(to: CGRect(x: r.x * k, y: r.y * k, width: r.w * k, height: r.h * k)) else { return nil }
        let height = Int((Double(width) * r.h / r.w).rounded())
        let size = CGSize(width: width, height: height)
        let px = Double(width) / r.w // output pixels per unit
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
            let g = ctx.cgContext
            g.setStrokeColor(UIColor(red: 0, green: 0.59, blue: 1, alpha: 0.3).cgColor)
            g.setLineWidth(1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor(red: 0, green: 0.47, blue: 0.86, alpha: 0.85),
            ]
            var u = (Int(r.x) / step + 1) * step
            while Double(u) < r.x + r.w {
                let x = (Double(u) - r.x) * px
                g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: size.height)); g.strokePath()
                ("\(u)" as NSString).draw(at: CGPoint(x: x + 2, y: 1), withAttributes: attrs)
                u += step
            }
            var v = (Int(r.y) / step + 1) * step
            while Double(v) < r.y + r.h {
                let y = (Double(v) - r.y) * px
                g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: size.width, y: y)); g.strokePath()
                ("\(v)" as NSString).draw(at: CGPoint(x: 2, y: y - 15), withAttributes: attrs)
                v += step
            }
        }
        return image.jpegData(compressionQuality: 0.85)
    }

    /// How the drawing on the page looks (ink color and line thickness),
    /// measured from the raw camera colors so the outline matches what's on screen.
    static func inkStyle(_ pixelBuffer: CVPixelBuffer, corners: [CGPoint], paper: PaperSize, width: Int = 480) -> InkStyle {
        let height = Int((Double(width) * paper.h / paper.w).rounded())
        guard let bytes = rgba(pixelBuffer, corners: corners, width: width, height: height) else { return .fallback }
        return InkStyle.estimate(rgba: bytes, width: width, height: height, paperWidth: paper.w)
    }

    /// Top-down page as RGBA bytes (sRGB, row 0 = top of the page).
    static func rgba(_ pixelBuffer: CVPixelBuffer, corners: [CGPoint], width: Int, height: Int) -> [UInt8]? {
        guard let page = rectified(pixelBuffer, corners: corners, width: width, height: height),
              let cg = context.createCGImage(page, from: CGRect(x: 0, y: 0, width: width, height: height))
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes : nil
    }

    private static func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Small grayscale top-down page (0–255, row 0 = top of the page) for
    /// completion tracking.
    static func gray(_ pixelBuffer: CVPixelBuffer, corners: [CGPoint], width: Int, height: Int) -> [Float]? {
        guard let page = rectified(pixelBuffer, corners: corners, width: width, height: height),
              let cg = context.createCGImage(page, from: CGRect(x: 0, y: 0, width: width, height: height))
        else { return nil }
        // A CGImage drawn into a bitmap context lands with its top row first in memory.
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes.map(Float.init) : nil
    }
}
