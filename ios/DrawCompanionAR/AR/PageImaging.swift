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

    /// The image sent to the model: the page with a faint labeled grid in
    /// paper units, which makes its coordinates much more accurate.
    static func uploadJPEG(_ pixelBuffer: CVPixelBuffer, corners: [CGPoint], paper: PaperSize, width: Int = 768) -> Data? {
        let height = Int((Double(width) * paper.h / paper.w).rounded())
        guard let raw = rgba(pixelBuffer, corners: corners, width: width, height: height),
              let cg = cgImage(rgba: PageEnhance.enhanced(rgba: raw, width: width, height: height), width: width, height: height)
        else { return nil }
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
            let px = CGFloat(width) / CGFloat(paper.w)
            let g = ctx.cgContext
            g.setStrokeColor(UIColor(red: 0, green: 0.59, blue: 1, alpha: 0.25).cgColor)
            g.setLineWidth(1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor(red: 0, green: 0.47, blue: 0.86, alpha: 0.8),
            ]
            for u in stride(from: 100, to: Int(paper.w), by: 100) {
                let x = CGFloat(u) * px
                g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: size.height)); g.strokePath()
                ("\(u)" as NSString).draw(at: CGPoint(x: x + 2, y: 1), withAttributes: attrs)
            }
            for v in stride(from: 100, to: Int(paper.h), by: 100) {
                let y = CGFloat(v) * px
                g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: size.width, y: y)); g.strokePath()
                ("\(v)" as NSString).draw(at: CGPoint(x: 2, y: y - 13), withAttributes: attrs)
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
