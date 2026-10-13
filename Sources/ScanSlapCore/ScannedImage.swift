import CoreGraphics
import Foundation
import ImageIO

struct PreparedScanImage {
    let image: CGImage
    let dpiWidth: CGFloat
    let dpiHeight: CGFloat
}

enum ScannedImageLoader {
    static func load(from url: URL, autoRotatePortrait: Bool) throws -> PreparedScanImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScanOutputWriterError.unreadableImage(url)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpiWidth = max((properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 300, 1)
        let dpiHeight = max((properties?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 300, 1)
        guard autoRotatePortrait, image.width > image.height else {
            return PreparedScanImage(image: image, dpiWidth: dpiWidth, dpiHeight: dpiHeight)
        }
        return PreparedScanImage(
            image: try rotateClockwise(image),
            dpiWidth: dpiHeight,
            dpiHeight: dpiWidth
        )
    }

    private static func rotateClockwise(_ image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = image.bitmapInfo
        guard let context = CGContext(
            data: nil,
            width: height,
            height: width,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ScanOutputWriterError.cannotTransformImage
        }
        context.translateBy(x: CGFloat(height), y: 0)
        context.rotate(by: .pi / 2)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else {
            throw ScanOutputWriterError.cannotTransformImage
        }
        return output
    }
}
