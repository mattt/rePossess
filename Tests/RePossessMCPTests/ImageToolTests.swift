import CoreGraphics
import Foundation
import ImageIO
import MCP
import Testing

@testable import RePossessFormat
@testable import RePossessLibrary
@testable import RePossessMCP
@testable import RePossessUSB

/// A red PNG, made for the test.
private func redPNG() -> Data {
    let context = CGContext(
        data: nil,
        width: 30,
        height: 10,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 30, height: 10))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// The color of one pixel of a PNG, from the top left.
private func color(_ png: Data, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
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

/// A typed notebook whose page ends with a line that introduces a table, which is an image below the text,
/// as on a page that reMarkdown wrote; and a page with an image alone.
private func toolsWithImages() async throws -> RePossessTools {
    var page = PageBuilder()
    page.paperSize = (1404, 1872)
    page.paragraphs = [StyledParagraph(.heading, "Invented report"), StyledParagraph(.plain, "The table follows:")]
    page.images = [.init(fileName: "table-1.png", x: -400, y: 600, width: 800, height: 400)]
    var alone = PageBuilder()
    alone.images = [.init(fileName: "table-2.png", x: -400, y: 100, width: 800, height: 400, anchor: nil)]
    let document = DocumentBuilder(
        id: "doc-images",
        name: "Invented Report",
        pages: [("p1", page), ("p2", alone)],
        extraFiles: [
            ArchiveFile(name: "p1/table-1.png", data: redPNG()), ArchiveFile(name: "p2/table-2.png", data: redPNG()),
        ]
    )
    let tablet = FakeTablet()
    await tablet.add(
        USBItem(
            id: document.id,
            type: "DocumentType",
            fileType: "notebook",
            modifiedClient: "2026-10-25T07:00:00.000Z",
            visibleName: document.name
        ),
        rmdoc: try document.rmdoc()
    )
    let library = try Library(
        root: FileManager.default.temporaryDirectory.appending(path: "repossess-images-\(UUID().uuidString)")
    )
    _ = try await library.refreshUSB(client: USBClient(transport: tablet, checkInterface: { true }), exports: false)
    return RePossessTools(library: library, refresh: { _ in [] }, usbConnected: { false }, cloudPaired: { false })
}

@Suite struct ImageToolTests {
    @Test func fetchDocumentPutsAPlaceholderWhereTheImageIs() async throws {
        let tools = try await toolsWithImages()
        let text = texts(await call(tools, "fetch_document", ["id": "doc-images"]))[0]
        #expect(
            text.contains(
                "--- Page 1 of 2 ---\n\n# Invented report\n\nThe table follows:\n\n"
                    + "[Image: see fetch_page_image for page 1.]"
            )
        )
        #expect(text.contains("--- Page 2 of 2 ---\n\n[Image: see fetch_page_image for page 2.]"))
        #expect(!text.contains("could not be read"))
        #expect(!text.contains("handwriting"))
        #expect(!text.contains("[Blank page.]"))
    }

    @Test func pageImagesDrawTheImages() async throws {
        let tools = try await toolsWithImages()
        let result = await call(tools, "fetch_page_image", ["id": "doc-images", "page_no": 1])
        guard case .image(let data, _, _, _) = result.content.first, let png = Data(base64Encoded: data) else {
            Issue.record("expected an image")
            return
        }
        // The page is 1404 x 1872 tablet pixels in 1500 x 2000; the image covers x 302 to 1102 and y 600 to 1000.
        let scale = 2000.0 / 1872
        let inside = color(png, x: Int(702 * scale), y: Int(800 * scale))
        #expect(inside.r > 200 && inside.g < 60 && inside.b < 60, "\(inside)")
        let outside = color(png, x: Int(150 * scale), y: Int(800 * scale))
        #expect(outside.r > 240 && outside.g > 240)

        let chunks = await call(tools, "fetch_page_chunks", ["id": "doc-images", "page_no": 1])
        #expect(chunks.isError != true)
    }

    @Test func searchSnippetsHaveNoMarkdownMarkers() async throws {
        let tools = try await stockedTools()
        let object = try json(await call(tools, "search_documents", ["query": "seed order"]))
        let results = object["results"] as! [[String: Any]]
        let page = try #require(results.first { $0["match"] as? String == "text" })
        let snippet = try #require(page["snippet"] as? String)
        #expect(snippet.hasPrefix("Seed order"), "\(snippet)")
        #expect(!snippet.contains("#"))
        // fetch_document keeps the Markdown.
        #expect(texts(await call(tools, "fetch_document", ["id": "doc-typed"]))[0].contains("# Seed order"))
    }
}
