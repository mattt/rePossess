import CoreGraphics
import CoreText
import Foundation
import ImageIO
import RePossessFormat
import UniformTypeIdentifiers

/// A PNG image of a page or of part of one.
public struct RenderedImage: Sendable {
    public var png: Data
    public var width: Int
    public var height: Int
}

/// An error while rendering.
public enum RenderError: Error, CustomStringConvertible {
    case context
    case encode

    public var description: String {
        switch self {
        case .context: "could not make a drawing context"
        case .encode: "could not encode the PNG"
        }
    }
}

/// A stroke placed on the page.
struct PlacedStroke {
    var line: Line
    /// Added to the stroke's x and y to give page pixels from the top left.
    var offset: CGPoint
}

/// A page, ready to draw.
///
/// Coordinates are the tablet's pixels.
/// Strokes and highlights store x from the page's center and y from its top;
/// this type moves them to x from the left edge.
/// A stroke group anchored to a character of the text moves with that character's line:
/// its y origin is the baseline of the line, and its x origin is the group's `anchor_origin_x`
/// from the center (checked on 2026-10-25 against the Paper Pure's PDF export of a circle
/// that Mattt drew around a typed paragraph).
public struct PageScene {
    /// The page width in pixels.
    public var width: CGFloat
    /// The height of one screen, 4:3 to the width.
    public var screenHeight: CGFloat
    /// The height of everything on the page, at least one screen; long pages are taller.
    public var height: CGFloat
    public var layout: TextLayout?
    public var pdfPage: CGPDFPage?
    var strokes: [PlacedStroke] = []
    var highlights: [GlyphRange] = []
    /// What could not be read or placed.
    public var warnings: [String] = []

    /// The page size when a page names none: the Paper Pure's and the reMarkable 2's display.
    public static let defaultSize = CGSize(width: 1404, height: 1872)

    /// Reads a page for drawing.
    ///
    /// - Parameters:
    ///   - pageBytes: The `.rm` file, or `nil` for a page without one.
    ///   - pdfPage: The PDF page that the page shows, if any.
    public init(pageBytes: [UInt8]?, pdfPage: CGPDFPage? = nil) {
        self.pdfPage = pdfPage
        let result = pageBytes.map(readPage)
        warnings = result?.warnings ?? []

        var size = Self.defaultSize
        if let paper = result?.tree.sceneInfo?.paperSize, paper.0 > 0, paper.1 > 0 {
            size = CGSize(width: CGFloat(paper.0), height: CGFloat(paper.1))
        }
        width = size.width
        screenHeight = size.height
        height = size.height

        if let tree = result?.tree {
            if let text = tree.rootText {
                do {
                    layout = try TextLayout(text: text, pageWidth: width)
                } catch {
                    warnings.append("The typed text could not be laid out: \(error)")
                }
            }
            collect(tree.root, offset: CGPoint(x: width / 2, y: 0))
        }

        if let pdfPage {
            height = max(height, pdfFrame(pdfPage).maxY)
        }
        if let layout { height = max(height, layout.bottom + 40) }
        for stroke in strokes {
            for p in stroke.line.points { height = max(height, p.y + stroke.offset.y + 40) }
        }
        for glyph in highlights {
            for r in glyph.rectangles { height = max(height, r.y + r.h + 40) }
        }
        height = ceil(height)
    }

    /// The special anchor IDs that rmc treats as the top and the bottom of the text.
    static let topAnchor = CrdtId(0, 281_474_976_710_654)
    static let bottomAnchor = CrdtId(0, 281_474_976_710_655)

    private mutating func collect(_ group: Group, offset: CGPoint) {
        guard group.visible.value else { return }
        let children: [SceneItem?]
        do {
            children = try group.children.values()
        } catch {
            warnings.append("A group's items could not be ordered: \(error)")
            return
        }
        for item in children {
            switch item {
            case .group(let child)?:
                var childOffset = offset
                if let anchor = child.anchorId?.value {
                    childOffset.x = width / 2 + CGFloat(child.anchorOriginX?.value ?? 0)
                    childOffset.y = anchorY(anchor)
                }
                collect(child, offset: childOffset)
            case .line(let line)?:
                if !line.tool.isEraser { strokes.append(PlacedStroke(line: line, offset: offset)) }
            case .glyphRange(let glyph)?:
                highlights.append(glyph)
            case nil:
                break
            }
        }
    }

    /// The y of an anchor: the baseline of the anchor character's line.
    ///
    /// The top and bottom anchors follow rmc: the top and the bottom of the text,
    /// or of the screen on a page without text (unchecked on the tablet).
    private mutating func anchorY(_ id: CrdtId) -> CGFloat {
        if let y = layout?.baselines[id] { return y }
        if id == Self.topAnchor { return layout?.top ?? 0 }
        if id == Self.bottomAnchor { return layout?.bottom ?? screenHeight }
        warnings.append("A stroke group is anchored to text that the page does not have (\(id)).")
        return 0
    }

    /// Where the PDF page goes: scaled to the page width, at the top.
    /// That the tablet places a PDF page this way is checked in docs/phase-1.md.
    func pdfFrame(_ page: CGPDFPage) -> CGRect {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let pdfWidth = rotated ? box.height : box.width
        let pdfHeight = rotated ? box.width : box.height
        guard pdfWidth > 0 else { return .zero }
        let scale = width / pdfWidth
        return CGRect(x: 0, y: 0, width: width, height: pdfHeight * scale)
    }

    /// The bounds of each stroke group as placed on the page, in page pixels,
    /// and whether the group is anchored to the text.
    public var strokeGroups: [(bounds: CGRect, anchored: Bool, strokes: Int)] {
        var groups: [String: (CGRect, Bool, Int)] = [:]
        var order: [String] = []
        for stroke in strokes {
            let key = "\(stroke.offset.x),\(stroke.offset.y)"
            var bounds = CGRect.null
            for p in stroke.line.points {
                bounds = bounds.union(CGRect(x: p.x + stroke.offset.x, y: p.y + stroke.offset.y, width: 0, height: 0))
            }
            if let existing = groups[key] {
                groups[key] = (existing.0.union(bounds), existing.1, existing.2 + 1)
            } else {
                order.append(key)
                groups[key] = (bounds, stroke.offset != CGPoint(x: width / 2, y: 0), 1)
            }
        }
        return order.map { (groups[$0]!.0, groups[$0]!.1, groups[$0]!.2) }
    }

    /// Whether the page draws anything.
    public var isEmpty: Bool {
        strokes.isEmpty && highlights.isEmpty && pdfPage == nil && (layout?.lines.isEmpty ?? true)
    }
}

/// Draws pages with Core Graphics and Core Text.
public enum PageRenderer {
    /// Renders a horizontal band of the page, from `top` to `bottom` in page pixels,
    /// or the whole page, scaled to fit `maxWidth` by `maxHeight` pixels.
    public static func render(
        _ scene: PageScene,
        top: CGFloat = 0,
        bottom: CGFloat? = nil,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) throws -> RenderedImage {
        let bottom = min(bottom ?? scene.height, scene.height)
        let regionHeight = max(bottom - top, 1)
        let scale = min(maxWidth / scene.width, maxHeight / regionHeight)
        let pixelWidth = max(Int((scene.width * scale).rounded()), 1)
        let pixelHeight = max(Int((regionHeight * scale).rounded()), 1)
        guard
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { throw RenderError.context }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // Page pixels, with y down from the top of the region.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: 0, y: -top)
        draw(scene, in: context)

        guard let image = context.makeImage() else { throw RenderError.context }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw RenderError.encode }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encode }
        return RenderedImage(png: data as Data, width: pixelWidth, height: pixelHeight)
    }

    static func draw(_ scene: PageScene, in context: CGContext) {
        if let page = scene.pdfPage {
            let frame = scene.pdfFrame(page)
            let box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let native = rotated ? CGSize(width: box.height, height: box.width) : box.size
            context.saveGState()
            // PDF space has y up; flip it into the frame, then scale up to the frame.
            // `getDrawingTransform` handles rotation but never scales up, so it maps to the native size.
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: frame.width / native.width, y: -frame.width / native.width)
            let transform = page.getDrawingTransform(
                .cropBox,
                rect: CGRect(origin: .zero, size: native),
                rotate: 0,
                preserveAspectRatio: true
            )
            context.concatenate(transform)
            context.clip(to: box)
            context.drawPDFPage(page)
            context.restoreGState()
        }

        for glyph in scene.highlights {
            context.setFillColor(color(glyph.color, glyph.colorRGBA, alpha: 0.35))
            for r in glyph.rectangles {
                context.fill(CGRect(x: r.x + scene.width / 2, y: r.y, width: r.w, height: r.h))
            }
        }

        if let layout = scene.layout { drawText(layout, in: context) }

        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in scene.strokes { draw(stroke, in: context) }
    }

    static func drawText(_ layout: TextLayout, in context: CGContext) {
        context.saveGState()
        // Core Text draws with y up; flip each glyph back.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let ink = CGColor(gray: 0, alpha: 1)
        for line in layout.lines {
            context.textPosition = CGPoint(x: line.x, y: line.baseline)
            CTLineDraw(CTLineCreateWithAttributedString(line.text), context)
            guard line.isFirst else { continue }
            context.setFillColor(ink)
            context.setStrokeColor(ink)
            context.setLineWidth(2.5)
            switch line.style {
            case .bullet, .bullet2:
                let center = CGPoint(x: line.x - 22, y: line.baseline - 11)
                let rect = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
                if line.style == .bullet { context.fillEllipse(in: rect) } else { context.strokeEllipse(in: rect) }
            case .checkbox, .checkboxChecked:
                let box = CGRect(x: line.x - 40, y: line.baseline - 26, width: 26, height: 26)
                context.stroke(box)
                if line.style == .checkboxChecked {
                    context.move(to: CGPoint(x: box.minX + 5, y: box.midY))
                    context.addLine(to: CGPoint(x: box.minX + 11, y: box.maxY - 6))
                    context.addLine(to: CGPoint(x: box.maxX - 4, y: box.minY + 5))
                    context.strokePath()
                    let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(line.text), nil, nil, nil)
                    context.move(to: CGPoint(x: line.x, y: line.baseline - 10))
                    context.addLine(to: CGPoint(x: line.x + width, y: line.baseline - 10))
                    context.strokePath()
                }
            default:
                break
            }
        }
        context.restoreGState()
    }

    static func draw(_ stroke: PlacedStroke, in context: CGContext) {
        let line = stroke.line
        let o = stroke.offset
        guard let first = line.points.first else { return }
        func point(_ p: Point) -> CGPoint { CGPoint(x: p.x + o.x, y: p.y + o.y) }

        if line.tool.isHighlighter || line.tool == .shader {
            // One path, so that overlapping segments do not darken.
            let path = CGMutablePath()
            path.move(to: point(first))
            for p in line.points.dropFirst() { path.addLine(to: point(p)) }
            let width = line.points.map { Double($0.width) }.max()! / 4
            let alpha = line.tool == .shader ? 0.5 : 0.35
            context.setStrokeColor(color(line.color, line.colorRGBA, alpha: alpha, highlighter: true))
            context.setLineWidth(max(1, width))
            context.addPath(path)
            context.strokePath()
            return
        }

        let alpha = line.tool == .pencil1 || line.tool == .pencil2 ? 0.8 : 1.0
        context.setStrokeColor(color(line.color, line.colorRGBA, alpha: alpha))
        if line.points.count == 1 {
            let w = max(1, Double(first.width) / 4)
            context.setFillColor(color(line.color, line.colorRGBA, alpha: alpha))
            let c = point(first)
            context.fillEllipse(in: CGRect(x: c.x - w / 2, y: c.y - w / 2, width: w, height: w))
            return
        }
        for (a, b) in zip(line.points, line.points.dropFirst()) {
            context.setLineWidth(max(1, Double(a.width) / 4))
            context.move(to: point(a))
            context.addLine(to: point(b))
            context.strokePath()
        }
    }

    /// The color of a stroke or highlight. An unknown color draws in black.
    static func color(_ color: PenColor, _ rgba: RGBA?, alpha: Double, highlighter: Bool = false) -> CGColor {
        if let rgba {
            return CGColor(
                srgbRed: Double(rgba.r) / 255,
                green: Double(rgba.g) / 255,
                blue: Double(rgba.b) / 255,
                alpha: min(alpha, Double(rgba.a) / 255)
            )
        }
        let (r, g, b): (Double, Double, Double) =
            switch color {
            case .gray, .grayOverlap: (0.5, 0.5, 0.5)
            case .white: (1, 1, 1)
            case .yellow, .yellow2, .highlight: (1, 0.92, 0.2)
            case .green, .green2: (0.3, 0.75, 0.3)
            case .pink: (1, 0.4, 0.7)
            case .blue: (0.1, 0.35, 0.85)
            case .red: (0.85, 0.1, 0.1)
            case .cyan: (0.2, 0.75, 0.9)
            case .magenta: (0.85, 0.2, 0.75)
            default: highlighter ? (1, 0.92, 0.2) : (0, 0, 0)
            }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
