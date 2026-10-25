import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import RePossessCloud
@testable import RePossessFormat
@testable import RePossessLibrary
@testable import RePossessUSB

/// A PDF with one line of text on each page, drawn with Core Text.
func makePDF(_ pages: [String]) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    for text in pages {
        context.beginPDFPage(nil)
        if !text.isEmpty {
            let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
            )
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// Invented documents: a typed notebook in a folder, a handwritten notebook, and an annotated PDF.
struct Shelf {
    static let folder = "f0000000-0000-4000-8000-000000000001"
    static let typed = "d0000000-0000-4000-8000-000000000001"
    static let handwritten = "d0000000-0000-4000-8000-000000000002"
    static let annotated = "d0000000-0000-4000-8000-000000000003"

    static func typedDocument(extra: String = "") -> DocumentBuilder {
        var page1 = PageBuilder()
        page1.paragraphs = [
            StyledParagraph(.heading, "Seed order"),
            StyledParagraph(.plain, "Marigolds and café beans for the raised beds\(extra)."),
        ]
        var page2 = PageBuilder()
        page2.paragraphs = [StyledParagraph(.bullet, "Lighthouse keeper checklist")]
        page2.groups = [.init(lines: [PageBuilder.stroke([(0, 300), (100, 320)])])]
        var builder = DocumentBuilder(
            id: typed,
            name: "Garden notes",
            parent: folder,
            pages: [("p-1", page1), ("p-2", page2)]
        )
        builder.tags = ["garden"]
        return builder
    }

    static func handwrittenDocument() -> DocumentBuilder {
        var page = PageBuilder()
        page.groups = [.init(lines: [PageBuilder.stroke([(0, 0), (40, 40), (80, 0)])])]
        return DocumentBuilder(id: handwritten, name: "Sketches", pages: [("h-1", page), ("h-2", nil)])
    }

    /// Made once, because Core Graphics writes the time into each PDF.
    static let pdf = makePDF(["Zebra crossing rules", "", "Penguin habitats"])

    static func annotatedDocument() -> DocumentBuilder {
        var page = PageBuilder()
        page.groups = [.init(lines: [PageBuilder.stroke([(0, 0), (40, 40)])])]
        page.highlights = [GlyphRange(length: 5, text: "Walrus", color: .yellow, rectangles: [])]
        var builder = DocumentBuilder(
            id: annotated,
            name: "Reading",
            fileType: "pdf",
            pages: [("a-1", page), ("a-2", nil), ("a-3", nil)]
        )
        builder.pdf = pdf
        return builder
    }

    /// Adds the documents to a fake tablet.
    static func stock(_ tablet: FakeTablet, typedModified: String = "2026-10-25T07:00:00.000Z") async throws {
        await tablet.add(USBItem(id: folder, type: "CollectionType", visibleName: "Garden"))
        await tablet.add(
            USBItem(
                id: typed,
                type: "DocumentType",
                fileType: "notebook",
                modifiedClient: typedModified,
                parent: folder,
                visibleName: "Garden notes"
            ),
            rmdoc: try typedDocument(extra: typedModified.hasPrefix("2026-10-26") ? " again" : "").rmdoc()
        )
        await tablet.add(
            USBItem(
                id: handwritten,
                type: "DocumentType",
                fileType: "notebook",
                modifiedClient: "2026-10-24T07:00:00.000Z",
                visibleName: "Sketches"
            ),
            rmdoc: try handwrittenDocument().rmdoc()
        )
        await tablet.add(
            USBItem(
                id: annotated,
                type: "DocumentType",
                fileType: "pdf",
                modifiedClient: "2026-10-23T07:00:00.000Z",
                visibleName: "Reading"
            ),
            rmdoc: try annotatedDocument().rmdoc()
        )
    }

    /// Adds the documents to a fake cloud, with a schema 3 root, and returns their root entries.
    static func stock(_ cloud: FakeCloud, typed: DocumentBuilder = typedDocument(), trashed: Bool = false)
        async throws -> [IndexEntry]
    {
        var entries: [IndexEntry] = []
        let folderMetadata = #"{"visibleName": "Garden", "type": "CollectionType", "parent": ""}"#
        entries.append(
            try await cloud.seedDocument(
                id: folder,
                files: [("\(folder).metadata", Data(folderMetadata.utf8)), ("\(folder).content", Data("{}".utf8))]
            )
        )
        for builder in [typed, handwrittenDocument(), annotatedDocument()] {
            var builder = builder
            if trashed, builder.id == handwritten { builder.parent = "trash" }
            entries.append(
                try await cloud.seedDocument(id: builder.id, files: try builder.files().map { ($0.name, $0.data) })
            )
        }
        try await cloud.seedRoot(entries)
        return entries
    }
}

func temporaryLibrary() throws -> Library {
    try Library(root: FileManager.default.temporaryDirectory.appending(path: "repossess-library-\(UUID().uuidString)"))
}

@Suite struct USBRefreshTests {
    func usb(_ tablet: FakeTablet) -> USBClient { USBClient(transport: tablet, checkInterface: { true }) }

    @Test func mirrorsAndIndexesTheTablet() async throws {
        let tablet = FakeTablet()
        try await Shelf.stock(tablet)
        let library = try temporaryLibrary()
        let report = try await library.refreshUSB(client: usb(tablet))
        #expect(report.listed == 3 && report.downloaded == 3 && report.failed.isEmpty && report.stoppedBy == nil)
        #expect(report.requests == 5)  // two listings and three downloads

        let documents = try library.documents()
        #expect(documents.map(\.path) == ["Garden/Garden notes", "Reading", "Sketches"])
        let typed = try #require(documents.first { $0.id == Shelf.typed })
        #expect(typed.pageCount == 2 && typed.contentStatus == .text && typed.tags == ["garden"])
        #expect(typed.summary.hasPrefix("Seed order Marigolds"))
        let sketches = try #require(documents.first { $0.id == Shelf.handwritten })
        #expect(sketches.contentStatus == .ink)  // one page of ink, one blank
        let reading = try #require(documents.first { $0.id == Shelf.annotated })
        #expect(reading.contentStatus == .partial)  // page 2 of the PDF has no text

        let pages = try library.pages(of: Shelf.annotated)
        #expect(pages.map(\.sourcePageIndex) == [0, 1, 2])
        #expect(pages[0].markdown == "Zebra crossing rules\n\nHighlighted on this page:\n- Walrus")
        #expect(pages[0].needsImage && pages[0].hasText)
        #expect(pages[1].needsImage && !pages[1].hasText)
        #expect(!pages[2].needsImage && pages[2].markdown == "Penguin habitats")

        let typedPages = try library.pages(of: Shelf.typed)
        #expect(typedPages[0].markdown == "# Seed order\n\nMarigolds and café beans for the raised beds.")
        #expect(typedPages[1].needsImage && typedPages[1].hasText)
        #expect(try library.status().documents == 3 && library.status().folders == 1)
        #expect(try library.status().lastRefresh[.usb] != nil)
    }

    @Test func refreshesOnlyChangedDocuments() async throws {
        let tablet = FakeTablet()
        try await Shelf.stock(tablet)
        let library = try temporaryLibrary()
        _ = try await library.refreshUSB(client: usb(tablet))

        let again = try await library.refreshUSB(client: usb(tablet))
        #expect(again.downloaded == 0 && again.unchanged == 3 && again.requests == 2)

        try await Shelf.stock(tablet, typedModified: "2026-10-26T07:00:00.000Z")
        await tablet.remove(id: Shelf.handwritten)
        let changed = try await library.refreshUSB(client: usb(tablet))
        #expect(changed.downloaded == 1 && changed.unchanged == 1 && changed.removed == 1)
        #expect(try library.pages(of: Shelf.typed)[0].markdown.contains("beds again."))
        #expect(try library.item(id: Shelf.handwritten) == nil)
        #expect(
            !FileManager.default.fileExists(atPath: library.root.appending(path: "documents/\(Shelf.handwritten)").path)
        )
    }

    @Test func aTimeoutStopsTheRefreshAndRemovesNothing() async throws {
        let tablet = FakeTablet()
        try await Shelf.stock(tablet)
        let library = try temporaryLibrary()
        _ = try await library.refreshUSB(client: usb(tablet))
        await tablet.setHang(true)
        await #expect(throws: USBError.self) { try await library.refreshUSB(client: usb(tablet)) }
        #expect(try library.documents().count == 3)
        #expect(try library.status().lastError[.usb]?.contains("off and on") == true)
        #expect(await tablet.paths.suffix(1) == ["/documents/"])
    }

    @Test func aRefreshNeedsTheLock() async throws {
        let tablet = FakeTablet()
        try await Shelf.stock(tablet)
        let library = try temporaryLibrary()
        // Another process holds the lock.
        let fd = open(library.root.appending(path: "refresh.lock").path, O_CREAT | O_RDWR, 0o644)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: RefreshError.self) { try await library.refreshUSB(client: usb(tablet)) }
        #expect(await tablet.paths.isEmpty)
        flock(fd, LOCK_UN)
        _ = try await library.refreshUSB(client: usb(tablet))
        #expect(try library.documents().count == 3)
    }
}

@Suite struct CloudRefreshTests {
    func session(_ cloud: FakeCloud) -> CloudSession {
        CloudSession(transport: cloud, deviceToken: { FakeCloud.deviceToken })
    }

    @Test func mirrorsTheAccountAndSkipsTheTrash() async throws {
        let cloud = FakeCloud()
        _ = try await Shelf.stock(cloud, trashed: true)
        let library = try temporaryLibrary()
        let report = try await library.refreshCloud(session: session(cloud))
        #expect(report.failed.isEmpty)
        #expect(report.downloaded == 2)
        #expect(try library.documents().map(\.path) == ["Garden/Garden notes", "Reading"])
        #expect(try library.pages(of: Shelf.typed)[0].markdown.hasPrefix("# Seed order"))
        #expect(await cloud.requests.allSatisfy { $0.method == "GET" || $0.url.path().hasSuffix("/user/new") })
    }

    @Test func refreshesByRootHashThenByDocumentHash() async throws {
        let cloud = FakeCloud()
        _ = try await Shelf.stock(cloud)
        let library = try temporaryLibrary()
        let sharedSession = session(cloud)
        _ = try await library.refreshCloud(session: sharedSession)

        await cloud.clearRequests()
        let same = try await library.refreshCloud(session: sharedSession)
        #expect(same.downloaded == 0 && same.unchanged == 3)
        #expect(await cloud.requests.map { $0.url.path() } == ["/sync/v4/root"])

        // Change one page of one document: the refresh reads the root index, that document's index,
        // its metadata, and the one changed page.
        _ = try await Shelf.stock(cloud, typed: Shelf.typedDocument(extra: " again"))
        await cloud.clearRequests()
        let changed = try await library.refreshCloud(session: sharedSession)
        #expect(changed.downloaded == 1 && changed.unchanged == 2)
        let names = await cloud.requests.compactMap { $0.headers["rm-filename"] }
        #expect(
            names == ["root.docSchema", "\(Shelf.typed).docSchema", "\(Shelf.typed).metadata", "\(Shelf.typed)/p-1.rm"]
        )
        #expect(try library.pages(of: Shelf.typed)[0].markdown.contains("beds again."))
    }

    @Test func bothTransportsFillOneLibrary() async throws {
        let tablet = FakeTablet()
        try await Shelf.stock(tablet)
        let cloud = FakeCloud()
        _ = try await Shelf.stock(cloud)
        let library = try temporaryLibrary()
        _ = try await library.refreshUSB(client: USBClient(transport: tablet, checkInterface: { true }))
        let report = try await library.refreshCloud(session: session(cloud))
        #expect(try library.documents().count == 3)
        #expect(try library.documents().allSatisfy { $0.source == .cloud })
        // The cloud copy's files match the USB copy's, so only the indexes and metadata were downloaded.
        let files = await cloud.requests.compactMap { $0.headers["rm-filename"] }
        #expect(!files.contains { $0.hasSuffix(".rm") || $0.hasSuffix(".pdf") })
        #expect(report.downloaded == 3)
    }
}

@Suite struct SearchTests {
    func library() async throws -> Library {
        let tablet = FakeTablet()
        try await Shelf.stock(tablet)
        let library = try temporaryLibrary()
        _ = try await library.refreshUSB(client: USBClient(transport: tablet, checkInterface: { true }))
        return library
    }

    @Test func findsNamesTagsAndText() async throws {
        let library = try await library()
        let name = try library.search("sketch")
        #expect(name.hits.map(\.match) == [.name])
        let tag = try library.search("garden")
        #expect(tag.hits.map(\.match).contains(.tag))
        let text = try library.search("lighthouse")
        #expect(text.hits.map(\.match) == [.text] && text.hits[0].pageNo == 2)
        #expect(text.hits[0].snippet.contains("Lighthouse keeper"))
    }

    @Test func textSearchIgnoresCaseAndAccentsAndMatchesWordStarts() async throws {
        let library = try await library()
        #expect(try library.search("CAFE").hits.first?.item.id == Shelf.typed)
        #expect(try library.search("marigold").hits.first?.pageNo == 1)
        #expect(try library.search("walrus").hits.first?.item.id == Shelf.annotated)
        #expect(try library.search("zebra crossing").total == 1)
        #expect(try library.search("\"(*").total == 0)
    }

    @Test func limitAndTag() async throws {
        let library = try await library()
        let all = try library.search("e", limit: 1)
        #expect(all.hits.count == 1 && all.total >= 1)
        #expect(try library.search("lighthouse", tag: "nope").total == 0)
        #expect(try library.search("lighthouse", tag: "garden").total == 1)
    }
}
