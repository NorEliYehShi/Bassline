import AppKit
import ImageIO

/// Samples the average luminance of the bottom strip of the wallpaper, so the
/// Auto tint can pick ink that stays readable.
enum BackdropSampler {
    private static let stripFraction: CGFloat = 0.12
    private static let sampleWidth = 32
    private static let sampleHeight = 4

    static func bottomLuminance(ofWallpaperAt url: URL) -> CGFloat? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let context = CGContext(
                  data: nil,
                  width: sampleWidth,
                  height: sampleHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: sampleWidth * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(
            x: 0,
            y: 0,
            width: CGFloat(sampleWidth),
            height: CGFloat(sampleHeight) / stripFraction
        ))

        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let pixelCount = sampleWidth * sampleHeight
        var total: CGFloat = 0
        for index in 0..<pixelCount {
            let red = CGFloat(pixels[index * 4]) / 255
            let green = CGFloat(pixels[index * 4 + 1]) / 255
            let blue = CGFloat(pixels[index * 4 + 2]) / 255
            total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
        return total / CGFloat(pixelCount)
    }
}
