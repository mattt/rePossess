import CoreGraphics
import Foundation
import ImageIO
import RePossessRender

/// A strip of a page, cut at blank rows, ready for a recognizer.
public struct Strip: @unchecked Sendable {
    /// The strip's rows on the page, in tablet pixels.
    public var top: Int
    public var bottom: Int
    /// Whether the cut at the bottom went through ink because no blank row was close enough.
    public var hardCut: Bool
    /// The strip at one tablet pixel per pixel.
    public var image: CGImage
}

/// Cuts pages into strips.
///
/// The page renders at one tablet pixel per pixel, with only its strokes.
/// Each strip is at most one screen tall (1,872 rows),
/// and each cut is in the middle of the longest run of blank rows in the lower half of the allowed range,
/// so that no cut goes through a line of writing.
/// Strips without ink are skipped.
public enum StripCutter {
    /// One screen of the Paper Pure: the most rows in one strip.
    public static let maxHeight = 1872
    /// The longest side of a strip as the recognizer gets it, in pixels.
    public static let maxSide = 936
    /// A gray value below this is ink.
    static let inkThreshold: UInt8 = 160
    /// The shortest run of blank rows that a cut may use.
    static let minimumGap = 8

    /// The strips of a page's strokes.
    public static func strips(_ scene: PageScene, maxHeight: Int = maxHeight) throws -> [Strip] {
        let strokes = scene.strokesOnly()
        let rendered = try PageRenderer.render(strokes, maxWidth: strokes.width, maxHeight: strokes.height)
        guard let source = CGImageSourceCreateWithData(rendered.png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RecognizerError.image("the page could not be drawn") }
        return strips(image, maxHeight: maxHeight)
    }

    /// The strips of an image, at blank rows.
    public static func strips(_ image: CGImage, maxHeight: Int = maxHeight) -> [Strip] {
        let rows = inkRows(image)
        var result: [Strip] = []
        for (top, bottom, hard) in cuts(rows, maxHeight: maxHeight) {
            guard rows[top ..< bottom].contains(where: { $0 > 0 }),
                let crop = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: bottom - top))
            else { continue }
            result.append(Strip(top: top, bottom: bottom, hardCut: hard, image: crop))
        }
        return result
    }

    /// The number of dark pixels in each row of the image, top row first.
    static func inkRows(_ image: CGImage) -> [Int] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // The bitmap's first row is the image's top row.
        return (0 ..< height).map { row in
            var count = 0
            let base = row * width
            for x in 0 ..< width where pixels[base + x] < inkThreshold { count += 1 }
            return count
        }
    }

    /// Where to cut: each strip is at most `maxHeight` rows,
    /// and each cut is in the middle of the longest run of blank rows
    /// in the lower half of the allowed range; the later run wins a tie.
    static func cuts(_ rows: [Int], maxHeight: Int) -> [(top: Int, bottom: Int, hard: Bool)] {
        var result: [(Int, Int, Bool)] = []
        var top = 0
        let height = rows.count
        while height - top > maxHeight {
            let low = top + maxHeight / 2
            let high = top + maxHeight
            var best: (start: Int, length: Int)?
            var runStart: Int?
            for y in low ... high {
                let blank = y < high && rows[y] == 0
                if blank {
                    if runStart == nil { runStart = y }
                } else if let start = runStart {
                    let length = y - start
                    if length >= (best?.length ?? 0) { best = (start, length) }
                    runStart = nil
                }
            }
            if let best, best.length >= minimumGap {
                let cut = best.start + best.length / 2
                result.append((top, cut, false))
                top = cut
            } else {
                result.append((top, high, true))
                top = high
            }
        }
        result.append((top, height, false))
        return result
    }

    /// The image scaled so that its longer side is at most `maxSide` pixels, with high-quality interpolation.
    /// A smaller image is returned as it is.
    public static func scaled(_ image: CGImage, maxSide: Int = maxSide) throws -> CGImage {
        let longer = max(image.width, image.height)
        guard longer > maxSide else { return image }
        let scale = Double(maxSide) / Double(longer)
        let width = max(Int((Double(image.width) * scale).rounded()), 1)
        let height = max(Int((Double(image.height) * scale).rounded()), 1)
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { throw RecognizerError.image("the strip could not be scaled") }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw RecognizerError.image("the strip could not be scaled") }
        return scaled
    }

    /// The image as PNG data.
    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw RecognizerError.image("the strip could not be encoded")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RecognizerError.image("the strip could not be encoded")
        }
        return data as Data
    }
}
