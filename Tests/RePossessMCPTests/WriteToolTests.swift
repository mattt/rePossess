import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MCP
import Synchronization
import Testing

@testable import RePossessCloud
@testable import RePossessFormat
@testable import RePossessLibrary
@testable import RePossessMCP
@testable import RePossessUSB

/// A PDF with one page for each height, in points, 445 points wide like the Paper Pure's exports,
/// with a black band across the top of each page so that a rendering shows where it came from.
func makeExport(heights: [CGFloat]) -> Data {
    let data = NSMutableData()
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    var box = CGRect(x: 0, y: 0, width: 445, height: heights.first ?? 594)
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    for height in heights {
        var page = CGRect(x: 0, y: 0, width: 445, height: height)
        let info = [kCGPDFContextMediaBox as String: Data(bytes: &page, count: MemoryLayout<CGRect>.size)]
        context.beginPDFPage(info as CFDictionary)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 60, width: 445, height: 60))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// A library mirrored from a fake tablet over USB, and tools with a pusher whose paths the test chooses.
func writableTools(
    tablet: FakeTablet,
    paths: @escaping @Sendable () -> PushPaths,
    fetch: @escaping @Sendable (URL, Int) async throws -> Data = { _, _ in throw PushError("no network in tests") }
) async throws -> RePossessTools {
    let library = try Library(
        root: FileManager.default.temporaryDirectory.appending(path: "repossess-write-\(UUID().uuidString)")
    )
    _ = try await library.refreshUSB(client: USBClient(transport: tablet, checkInterface: { true }))
    return RePossessTools(
        library: library,
        refresh: { _ in [] },
        usbConnected: { true },
        cloudPaired: { false },
        pusher: Pusher(library: library, paths: paths, fetch: fetch)
    )
}

/// A fake tablet that names an uploaded rmdoc from its metadata, as the Paper Pure did in spike 4.
func namingTablet() async -> FakeTablet {
    let tablet = FakeTablet()
    await tablet.set(nameForUpload: { fileName, data in
        if fileName.hasSuffix(".rmdoc"), let archive = try? RmdocArchive(data: data),
            let file = archive.files.first(where: { $0.name.hasSuffix(".metadata") }),
            let metadata = try? DocumentMetadata(parsing: file.data)
        {
            return metadata.visibleName
        }
        return (fileName as NSString).deletingPathExtension
    })
    return tablet
}

@Suite struct PushToolTests {
    @Test func pushMarkdownSendsANotebookOverUSB() async throws {
        let tablet = await namingTablet()
        let tools = try await writableTools(
            tablet: tablet,
            paths: { PushPaths(usb: { USBClient(transport: tablet, checkInterface: { true }) }, cloud: nil) }
        )
        let result = await call(
            tools,
            "push_markdown",
            [
                "title": "rePossess test note", "markdown": "# Invented\n\n## One\n\nbody\n\n## Two\n\nmore",
                "paginate": true,
            ]
        )
        #expect(result.isError != true)
        let object = try json(result)
        #expect(object["status"] as? String == "sent" && object["via"] as? String == "usb")
        #expect(object["kind"] as? String == "notebook" && object["pages"] as? Int == 2)
        let item = try #require(await tablet.items.first)
        #expect(object["tablet_id"] as? String == item.id && item.visibleName == "rePossess test note")
        #expect((object["message"] as? String)?.contains("new document") == true)
        let upload = try #require(await tablet.uploads.first)
        #expect(upload.fileName == "rePossess test note.rmdoc")

        let status = try json(await call(tools, "status"))
        #expect(status["pushes"] as? [String: Int] == ["sent": 1])
    }

    @Test func aPushWithoutAPathIsQueued() async throws {
        let tools = try await writableTools(tablet: FakeTablet(), paths: { .none })
        let object = try json(await call(tools, "push_markdown", ["title": "rePossess test", "markdown": "- one"]))
        #expect(object["status"] as? String == "queued" && object["via"] == nil)
        #expect((object["message"] as? String)?.contains("Do not push it again") == true)
        #expect((try json(await call(tools, "status")))["pushes"] as? [String: Int] == ["queued": 1])
    }

    @Test func pushFileReadsALocalPDFAndSendsItThroughTheCloud() async throws {
        let cloud = FakeCloud()
        try await cloud.seedRoot([], schema: .v3)
        let session = CloudSession(transport: cloud, deviceToken: { FakeCloud.deviceToken })
        let tools = try await writableTools(tablet: FakeTablet(), paths: { PushPaths(usb: nil, cloud: session) })
        let file = FileManager.default.temporaryDirectory.appending(path: "rePossess test \(UUID().uuidString).pdf")
        try makeExport(heights: [594]).write(to: file)
        let object = try json(await call(tools, "push_file", ["path": .string(file.path)]))
        #expect(object["status"] as? String == "sent" && object["via"] as? String == "cloud")
        #expect(object["kind"] as? String == "pdf")
        #expect((object["title"] as? String)?.hasPrefix("rePossess test ") == true)
        let id = try #require(object["push_id"] as? String)
        #expect(try await cloud.documentFiles(id: id)["\(id).pdf"] != nil)
    }

    @Test func pushFileDownloadsOnlyHTTPS() async throws {
        let epub = Data(
            [0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 26) + Array("mimetypeapplication/epub+zip".utf8)
        )
        let fetched = Mutex<[URL]>([])
        let tools = try await writableTools(
            tablet: FakeTablet(),
            paths: { .none },
            fetch: { url, limit in
                fetched.withLock { $0.append(url) }
                #expect(limit == 100_000_000)
                return epub
            }
        )
        let object = try json(await call(tools, "push_file", ["url": "https://example.com/books/Invented.epub"]))
        #expect(object["kind"] as? String == "epub" && object["title"] as? String == "Invented")
        #expect(object["status"] as? String == "queued")
        let insecure = await call(tools, "push_file", ["url": "http://example.com/a.pdf"])
        #expect(insecure.isError == true && texts(insecure)[0].contains("https"))
        #expect(fetched.withLock { $0.count } == 1)
    }

    @Test func refusesBadInputsWithoutQueuing() async throws {
        let tools = try await writableTools(tablet: FakeTablet(), paths: { .none })
        let both = await call(tools, "push_file", ["path": "/tmp/a.pdf", "url": "https://example.com/a.pdf"])
        #expect(both.isError == true && texts(both)[0] == "Give exactly one of path or url.")
        let empty = await call(tools, "push_markdown", ["title": "t", "markdown": "\n\n---\n"])
        #expect(empty.isError == true && texts(empty)[0].hasPrefix("Nothing was sent"))
        let notPDF = FileManager.default.temporaryDirectory.appending(path: "repossess-\(UUID().uuidString).txt")
        try Data("plain text".utf8).write(to: notPDF)
        let wrong = await call(tools, "push_file", ["path": .string(notPDF.path)])
        #expect(wrong.isError == true && texts(wrong)[0].contains("PDF and EPUB"))
        #expect(try tools.library.pushes().isEmpty)
    }

    @Test func aRefreshSendsTheQueue() async throws {
        let tablet = await namingTablet()
        let library = try Library(
            root: FileManager.default.temporaryDirectory.appending(path: "repossess-drain-\(UUID().uuidString)")
        )
        let notebook = try MarkdownNotebook(
            title: "rePossess test",
            markdown: "text",
            documentID: UUID().uuidString.lowercased()
        )
        let record = try library.enqueuePush(
            id: notebook.documentID,
            kind: .notebook,
            title: notebook.title,
            data: notebook.rmdoc
        )
        let usb: @Sendable () -> USBClient = { USBClient(transport: tablet, checkInterface: { true }) }
        let reports = try await refreshLibrary(
            library,
            .usb,
            session: CloudSession(transport: FakeCloud(), deviceToken: { FakeCloud.deviceToken }),
            usb: usb,
            pushes: PushPaths(usb: usb, cloud: nil)
        )
        #expect(reports.last?.pushes.map(\.id) == [record.id])
        #expect(try library.push(id: record.id)?.status == .sent)
    }
}

@Suite struct TabletRenderingTests {
    /// A tablet with one typed notebook of two pages, the second longer than a screen, and its export.
    func typedTablet(exportHeights: [CGFloat]) async throws -> FakeTablet {
        let tablet = FakeTablet()
        var page1 = PageBuilder()
        page1.paragraphs = [StyledParagraph(.heading, "Invented title")]
        var page2 = PageBuilder()
        page2.paragraphs = [StyledParagraph(.plain, String(repeating: "Invented words for a long page. ", count: 300))]
        let document = DocumentBuilder(id: "doc-typed", name: "Typed", pages: [("p1", page1), ("p2", page2)])
        await tablet.add(
            USBItem(
                id: "doc-typed",
                type: "DocumentType",
                fileType: "notebook",
                modifiedClient: "2026-10-25T07:00:00.000Z",
                visibleName: "Typed"
            ),
            rmdoc: try document.rmdoc(),
            pdf: makeExport(heights: exportHeights)
        )
        return tablet
    }

    @Test func pageImagesComeFromTheTabletsExport() async throws {
        let tablet = try await typedTablet(exportHeights: [594, 1782])
        let tools = try await writableTools(tablet: tablet, paths: { .none })
        let image = await call(tools, "fetch_page_image", ["id": "doc-typed", "page_no": 1])
        let note = texts(image)[0]
        #expect(note.contains("Drawn from the tablet's own PDF export"))
        guard case .image(let data, _, _, _) = image.content.first,
            let png = Data(base64Encoded: data),
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            Issue.record("expected an image")
            return
        }
        // The export's black band is at the top of the image.
        #expect(darkness(cgImage, atFraction: 0.01) > 0.9)

        // The long page is one tall export page of about three screens, so about twelve strips.
        let chunks = await call(tools, "fetch_page_chunks", ["id": "doc-typed", "page_no": 2])
        let object = try JSONSerialization.jsonObject(with: Data(texts(chunks).last!.utf8)) as! [String: Any]
        #expect(object["rendering"] as? String == "tablet")
        #expect((12 ... 13).contains(object["chunk_count"] as? Int ?? 0))
    }

    @Test func aMismatchedExportFallsBackToRePossess() async throws {
        let tablet = try await typedTablet(exportHeights: [594])
        let tools = try await writableTools(tablet: tablet, paths: { .none })
        let note = texts(await call(tools, "fetch_page_image", ["id": "doc-typed", "page_no": 1]))[0]
        #expect(note.contains("Drawn by rePossess, because the tablet's PDF export has 1 pages and the document has 2"))
        let chunks = await call(tools, "fetch_page_chunks", ["id": "doc-typed", "page_no": 1])
        let object = try JSONSerialization.jsonObject(with: Data(texts(chunks).last!.utf8)) as! [String: Any]
        #expect(object["rendering"] as? String == "repossess")
    }

    @Test func handwritingStaysWithRePossessRendering() async throws {
        let tools = try await stockedTools()
        let note = texts(await call(tools, "fetch_page_image", ["id": "doc-ink", "page_no": 1]))[0]
        #expect(note.contains("Drawn by rePossess. Copied from USB."))
        let typed = texts(await call(tools, "fetch_page_image", ["id": "doc-typed", "page_no": 1]))[0]
        #expect(typed.contains("A refresh over USB gets the tablet's own PDF"))
    }
}

@Suite struct ContentStatusTests {
    /// Phase 2's live check: a client looking for a handwritten notebook opened a printed PDF page,
    /// because every document's kind was DocumentType and scans and notebooks were both `ink`.
    @Test func listsTellNotebooksFromPDFsAndInkFromScans() async throws {
        let tablet = FakeTablet()
        var ink = PageBuilder()
        ink.groups = [.init(lines: [PageBuilder.stroke([(0, 100), (50, 150)])])]
        var scan = DocumentBuilder(id: "doc-scan", name: "Scan", fileType: "pdf", pages: [("s1", nil)])
        scan.pdf = makeExport(heights: [792])
        var marked = DocumentBuilder(id: "doc-marked", name: "Marked", fileType: "pdf", pages: [("m1", ink)])
        marked.pdf = makeExport(heights: [792])
        let documents = [
            DocumentBuilder(id: "doc-hand", name: "Hand", pages: [("h1", ink)]), scan, marked,
        ]
        for document in documents {
            await tablet.add(
                USBItem(
                    id: document.id,
                    type: "DocumentType",
                    fileType: document.fileType,
                    modifiedClient: "2026-10-25T07:00:00.000Z",
                    visibleName: document.name
                ),
                rmdoc: try document.rmdoc()
            )
        }
        let tools = try await writableTools(tablet: tablet, paths: { .none })
        let list = try json(await call(tools, "list_documents"))
        let entries = Dictionary(
            uniqueKeysWithValues: (list["documents"] as! [[String: Any]]).map {
                ($0["name"] as! String, "\($0["file_type"] as! String) \($0["content_status"] as! String)")
            }
        )
        #expect(entries == ["Hand": "notebook ink", "Scan": "pdf image", "Marked": "pdf annotated"])
        let overview = texts(await call(tools, "get_overview"))[0]
        #expect(overview.contains("id: doc-scan · pdf · path: Scan · 1 pages"))
    }
}

/// The share of dark pixels in the row at a fraction of the image's height.
func darkness(_ image: CGImage, atFraction fraction: CGFloat) -> Double {
    let width = image.width
    let context = CGContext(
        data: nil,
        width: width,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    let y = CGFloat(image.height) * (1 - fraction)
    context.draw(image, in: CGRect(x: 0, y: -y + 1, width: CGFloat(width), height: CGFloat(image.height)))
    let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width)
    var dark = 0
    for x in 0 ..< width where pixels[x] < 64 { dark += 1 }
    return Double(dark) / Double(width)
}
