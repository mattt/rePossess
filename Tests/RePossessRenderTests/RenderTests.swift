import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing

@testable import RePossessFormat
@testable import RePossessRender

private func scene(_ page: PageBuilder, pdf: CGPDFPage? = nil) throws -> PageScene {
    PageScene(pageBytes: try page.bytes(), pdfPage: pdf)
}

private func pixel(_ png: Data, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let source = CGImageSourceCreateWithData(png as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &bytes,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return (bytes[0], bytes[1], bytes[2])
}

@Suite struct TextLayoutTests {
    /// The baselines that the Paper Pure's PDF export gave for spike 4's test notebook,
    /// for paragraphs that do not wrap: Title, Body, Subheading, Body, bullets, and a checkbox.
    @Test func paragraphSpacingMatchesTheTablet() throws {
        var page = PageBuilder()
        page.paragraphs = [
            StyledParagraph(.heading, "Title"), StyledParagraph(.plain, "Body"), StyledParagraph(.bold, "Sub"),
            StyledParagraph(.plain, "Body"), StyledParagraph(.bullet, "One"), StyledParagraph(.bullet2, "Two"),
            StyledParagraph(.checkbox, "Box"), StyledParagraph(.plain, ""), StyledParagraph(.plain, "After"),
        ]
        let layout = try #require(try scene(page).layout)
        let expected: [CGFloat] = [297.2, 367.6, 456.9, 520.2, 589.7, 659.2, 728.7, 798.2, 867.7]
        #expect(layout.lines.count == expected.count)
        for (line, y) in zip(layout.lines, expected) {
            #expect(abs(line.baseline - y) < 0.2, "\(line.plain): \(line.baseline) != \(y)")
        }
        #expect(layout.lines.map(\.x) == [238, 238, 238, 238, 286, 334, 286, 238, 238])
    }

    @Test func longParagraphsWrapAtThePitch() throws {
        var page = PageBuilder()
        page.paragraphs = [StyledParagraph(.plain, String(repeating: "invented words wrap here ", count: 12))]
        let layout = try #require(try scene(page).layout)
        #expect(layout.lines.count > 3)
        #expect(abs(layout.lines[1].baseline - layout.lines[0].baseline - 45.5) < 0.01)
        let widest = layout.lines.map {
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString($0.text), nil, nil, nil)
                - CTLineGetTrailingWhitespaceWidth(CTLineCreateWithAttributedString($0.text))
        }.max()!
        #expect(widest <= 928)
    }
}

@Suite struct PlacementTests {
    @Test func anchoredGroupFollowsItsCharacter() throws {
        var page = PageBuilder()
        page.paragraphs = [StyledParagraph(.heading, "Title"), StyledParagraph(.plain, "Body text")]
        // Character 8 is in the second paragraph ("Title\nBody text").
        page.groups = [
            .init(lines: [PageBuilder.stroke([(-100, -20), (100, 20)])], anchor: (PageBuilder.characterID(8), -17))
        ]
        let s = try scene(page)
        let group = try #require(s.strokeGroups.first)
        #expect(group.anchored)
        #expect(abs(group.bounds.minY - (367.6 - 20)) < 0.2)
        #expect(abs(group.bounds.minX - (702 - 17 - 100)) < 0.01)
        #expect(s.warnings.isEmpty)
    }

    @Test func unanchoredStrokesUseTheCenter() throws {
        var page = PageBuilder()
        page.groups = [.init(lines: [PageBuilder.stroke([(0, 100), (10, 110)])])]
        let group = try #require(try scene(page).strokeGroups.first)
        #expect(!group.anchored && group.bounds.minX == 702 && group.bounds.minY == 100)
    }

    @Test func anchorToMissingTextWarns() throws {
        var page = PageBuilder()
        page.groups = [.init(lines: [PageBuilder.stroke([(0, 0), (1, 1)])], anchor: (CrdtId(1, 999), 0))]
        #expect(try scene(page).warnings.count == 1)
    }

    @Test func longPagesGrow() throws {
        var page = PageBuilder()
        page.groups = [.init(lines: [PageBuilder.stroke([(0, 100), (0, 5000)])])]
        let s = try scene(page)
        #expect(s.height == 5040 && s.screenHeight == 1872)
        let image = try PageRenderer.render(s, maxWidth: 1500, maxHeight: 2000)
        #expect(image.height == 2000 && image.width < 600)
    }

    @Test func paperSizeComesFromTheSceneInfo() throws {
        var page = PageBuilder()
        page.paperSize = (1620, 2160)
        let s = try scene(page)
        #expect(s.width == 1620 && s.screenHeight == 2160)
    }
}

@Suite struct RenderTests {
    @Test func pageImageIs1500By2000() throws {
        var page = PageBuilder()
        page.paragraphs = [StyledParagraph(.heading, "Invented")]
        page.groups = [.init(lines: [PageBuilder.stroke([(-300, 1000), (300, 1000)])])]
        let image = try PageRenderer.render(try scene(page), maxWidth: 1500, maxHeight: 2000)
        #expect(image.width == 1500 && image.height == 2000)
        // The stroke at y 1000 is dark at the page's center; the corner is white.
        let scale = 1500.0 / 1404
        #expect(pixel(image.png, x: 750, y: Int(1000 * scale)).r < 80)
        #expect(pixel(image.png, x: 5, y: 5) == (255, 255, 255))
    }

    @Test func bandsCropThePage() throws {
        var page = PageBuilder()
        page.groups = [.init(lines: [PageBuilder.stroke([(-300, 600), (300, 600)])])]
        let s = try scene(page)
        let band = try PageRenderer.render(
            s,
            top: 500,
            bottom: 700,
            maxWidth: 2000,
            maxHeight: .greatestFiniteMagnitude
        )
        #expect(band.width == 2000)
        #expect(band.height == Int((200 * 2000 / 1404.0).rounded()))
        #expect(pixel(band.png, x: 1000, y: band.height / 2).r < 80)
    }

    @Test func pdfPageIsTheBackground() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 692, width: 612, height: 100))  // a black band at the top
        context.endPDFPage()
        context.closePDF()
        let pdf = CGPDFDocument(CGDataProvider(data: data)!)!.page(at: 1)!
        let s = PageScene(pageBytes: nil, pdfPage: pdf)
        // A PDF page keeps its size, at 227/72 tablet pixels per point.
        #expect(abs(s.width - 612 * 227 / 72) < 0.01 && abs(s.height - (792 * 227 / 72).rounded(.up)) < 1)
        let image = try PageRenderer.render(s, maxWidth: 1404, maxHeight: 1872)
        #expect(pixel(image.png, x: 700, y: 50).r < 30)
        #expect(pixel(image.png, x: 700, y: 400).r > 220)
    }

    @Test func unknownColorsDrawInBlack() {
        #expect(
            PageRenderer.color(PenColor(rawValue: 99), nil, alpha: 1)
                == CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        )
    }
}

@Suite struct StrokesOnlyTests {
    @Test func strokesOnlyDropsTheTextAndKeepsTheStrokes() throws {
        var page = PageBuilder()
        page.paragraphs = [StyledParagraph(.heading, "A heading in large type")]
        page.groups = [.init(lines: [PageBuilder.stroke([(-300, 900), (300, 900)])])]
        let full = try scene(page)
        let strokes = full.strokesOnly()
        #expect(strokes.hasStrokes && !strokes.drawsText && strokes.pdfPage == nil)
        #expect(strokes.width == full.width && strokes.height == full.height)
        let withText = try PageRenderer.render(full, maxWidth: full.width, maxHeight: full.height)
        let without = try PageRenderer.render(strokes, maxWidth: strokes.width, maxHeight: strokes.height)
        // The heading's first glyph is dark in the full page and blank without the text.
        let line = try #require(full.layout?.lines.first)
        let x = Int(line.x) + 12
        let y = Int(line.baseline) - 20
        let darkest = (-8 ... 8).map { pixel(withText.png, x: x + $0, y: y).r }.min()!
        #expect(darkest < 128)
        #expect((-8 ... 8).allSatisfy { pixel(without.png, x: x + $0, y: y).r > 250 })
        #expect(pixel(without.png, x: 702, y: 900).r < 128)
    }

    @Test func aPageWithoutStrokesHasNone() throws {
        var page = PageBuilder()
        page.paragraphs = [StyledParagraph(.plain, "Text")]
        #expect(!(try scene(page)).hasStrokes)
    }
}

/// A PNG of two colors: red in its top half and blue in its bottom half, so that a flip shows.
func twoColorPNG(width: Int = 40, height: Int = 20) -> Data {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Core Graphics has y up here: the bottom half is y 0 to height / 2.
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Suite struct ImageRenderTests {
    private func page() -> PageBuilder {
        var page = PageBuilder()
        page.paperSize = (1404, 1872)
        page.paragraphs = [StyledParagraph(.plain, "Before the image"), StyledParagraph(.plain, "Also before")]
        // Below the text, in a group whose anchor names no character, as on the owner's page.
        page.images = [.init(fileName: "table.png", x: -400, y: 600, width: 800, height: 400)]
        return page
    }

    @Test func placesAnImageAtItsVerticesWithoutTheAnchorsOrigin() throws {
        let png = twoColorPNG()
        let s = PageScene(pageBytes: try page().bytes()) { $0 == "table.png" ? png : nil }
        let image = try #require(s.images.first)
        #expect(image.fileName == "table.png")
        #expect(image.bounds == CGRect(x: 302, y: 600, width: 800, height: 400))
        #expect(!s.warnings.contains { $0.contains("image") })
        #expect(s.imageReadingPositions == [2])
        #expect(s.height >= 1040)

        let rendered = try PageRenderer.render(s, maxWidth: 1404, maxHeight: s.height)
        let top = pixel(rendered.png, x: 702, y: 700)
        let bottom = pixel(rendered.png, x: 702, y: 900)
        #expect(top.r > 200 && top.b < 50, "the image's top half is red: \(top)")
        #expect(bottom.b > 200 && bottom.r < 50, "the image's bottom half is blue: \(bottom)")
        let outside = pixel(rendered.png, x: 200, y: 800)
        #expect(outside.r > 240 && outside.g > 240 && outside.b > 240)
    }

    @Test func anImageAboveTheTextComesFirstInReadingOrder() throws {
        var builder = page()
        builder.images[0].y = 50
        builder.images[0].height = 100
        let s = PageScene(pageBytes: try builder.bytes())
        #expect(s.imageReadingPositions == [0])
    }

    @Test func aMissingFileDrawsAFrameAndSaysSo() throws {
        let s = PageScene(pageBytes: try page().bytes())
        #expect(s.warnings.contains("The image file table.png is not in the document."))
        let rendered = try PageRenderer.render(s, maxWidth: 1404, maxHeight: s.height)
        let edge = pixel(rendered.png, x: 302, y: 800)
        #expect(edge.r < 200)
        let inside = pixel(rendered.png, x: 702, y: 800)
        #expect(inside.r > 240)
    }

    @Test func theRecognizerSeesNoImages() throws {
        let s = PageScene(pageBytes: try page().bytes()) { _ in twoColorPNG() }
        #expect(s.strokesOnly().images.isEmpty)
    }
}
