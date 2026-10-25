import Foundation
import MCP
import Testing

@testable import RePossessCloud
@testable import RePossessFormat
@testable import RePossessLibrary
@testable import RePossessMCP
@testable import RePossessUSB

/// A library with invented documents: a typed notebook with a page of ink,
/// a handwritten notebook, and a long typed notebook.
func stockedTools(now: @escaping @Sendable () -> Date = Date.init) async throws -> RePossessTools {
    let tablet = FakeTablet()
    var typed1 = PageBuilder()
    typed1.paragraphs = [StyledParagraph(.heading, "Seed order"), StyledParagraph(.plain, "Marigolds for the beds.")]
    var typed2 = PageBuilder()
    typed2.paragraphs = [StyledParagraph(.plain, "Budget notes")]
    typed2.groups = [.init(lines: [PageBuilder.stroke([(0, 600), (200, 650)])])]
    var ink = PageBuilder()
    ink.groups = [.init(lines: [PageBuilder.stroke([(-200, 300), (0, 400), (200, 300)])])]
    let pages = (1 ... 12).map { i -> (String, PageBuilder?) in
        var page = PageBuilder()
        page.paragraphs = [
            StyledParagraph(.plain, "Chapter \(i). " + String(repeating: "Lighthouse log entry. ", count: 160))
        ]
        return ("long-\(i)", page)
    }
    let documents = [
        DocumentBuilder(
            id: "doc-typed",
            name: "Seed Order",
            parent: "folder-1",
            pages: [("t1", typed1), ("t2", typed2)]
        ),
        DocumentBuilder(id: "doc-ink", name: "Raised Bed Sketch", pages: [("i1", ink)]),
        DocumentBuilder(id: "doc-long", name: "Keeper's Log", pages: pages),
    ]
    await tablet.add(USBItem(id: "folder-1", type: "CollectionType", visibleName: "Garden"))
    for (i, document) in documents.enumerated() {
        await tablet.add(
            USBItem(
                id: document.id,
                type: "DocumentType",
                fileType: "notebook",
                modifiedClient: "2026-10-2\(i)T07:00:00.000Z",
                parent: document.parent,
                visibleName: document.name
            ),
            rmdoc: try document.rmdoc()
        )
    }
    let library = try Library(
        root: FileManager.default.temporaryDirectory.appending(path: "repossess-mcp-\(UUID().uuidString)")
    )
    _ = try await library.refreshUSB(client: USBClient(transport: tablet, checkInterface: { true }))
    return RePossessTools(
        library: library,
        refresh: { source in
            var report = RefreshReport(source: source == .cloud ? .cloud : .usb)
            report.listed = 3
            report.unchanged = 3
            return [report]
        },
        usbConnected: { false },
        cloudPaired: { true },
        now: now
    )
}

func call(_ tools: RePossessTools, _ name: String, _ arguments: [String: Value] = [:]) async -> CallTool.Result {
    await tools.call(CallTool.Parameters(name: name, arguments: arguments))
}

func texts(_ result: CallTool.Result) -> [String] {
    result.content.compactMap {
        if case .text(let text, _, _) = $0 { return text }
        return nil
    }
}

func json(_ result: CallTool.Result) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(texts(result)[0].utf8)) as! [String: Any]
}

@Suite struct SchemaTests {
    @Test func toolsHaveFlatClosedSchemas() {
        #expect(
            RePossessTools.all.map(\.name) == [
                "get_overview", "list_documents", "search_documents", "fetch_document", "fetch_page_image",
                "fetch_page_chunks", "recognize_pages", "refresh_documents", "push_markdown", "push_file", "status",
            ]
        )
        for tool in RePossessTools.all {
            let schema = tool.inputSchema.objectValue ?? [:]
            #expect(schema["additionalProperties"] == false, "\(tool.name)")
            #expect(schema["oneOf"] == nil && schema["anyOf"] == nil && schema["allOf"] == nil)
            let writes = tool.name.hasPrefix("push_")
            #expect(tool.annotations.readOnlyHint == !writes, "\(tool.name)")
            if writes {
                #expect(tool.annotations.destructiveHint == false && tool.annotations.idempotentHint == false)
                let description = tool.description ?? ""
                #expect(description.contains("every call creates a new document"))
                #expect(description.contains("Do not call it again to retry"))
                #expect(description.contains("Limits:"))
            }
        }
    }
}

@Suite struct ToolTests {
    @Test func listDocumentsGivesTheSameJSONInBothFields() async throws {
        let result = await call(try await stockedTools(), "list_documents")
        #expect(result.isError != true)
        let object = try json(result)
        let documents = object["documents"] as! [[String: Any]]
        #expect(documents.map { $0["path"] as! String } == ["Garden/Seed Order", "Keeper's Log", "Raised Bed Sketch"])
        #expect(documents.map { $0["content_status"] as! String } == ["text", "text", "ink"])
        #expect(documents.allSatisfy { $0["file_type"] as? String == "notebook" })
        let structured = try #require(result.structuredContent)
        let fromStructured = try JSONSerialization.jsonObject(with: JSONEncoder().encode(structured)) as! [String: Any]
        #expect(NSDictionary(dictionary: fromStructured).isEqual(to: object))
    }

    @Test func searchFindsTextOnAPage() async throws {
        let tools = try await stockedTools()
        let object = try json(await call(tools, "search_documents", ["query": "marigolds"]))
        let results = object["results"] as! [[String: Any]]
        #expect(results.count == 1)
        #expect(results[0]["id"] as? String == "doc-typed" && results[0]["page_no"] as? Int == 1)
        #expect(results[0]["file_type"] as? String == "notebook" && results[0]["content_status"] as? String == "text")
        let limited = try json(await call(tools, "search_documents", ["query": "lighthouse", "limit": 2]))
        #expect(limited["total"] as? Int == 12 && (limited["results"] as! [Any]).count == 2)
        #expect(await call(tools, "search_documents", ["query": ""]).isError == true)
    }

    @Test func fetchDocumentMarksInkAndHasNoStructuredContent() async throws {
        let tools = try await stockedTools()
        let typed = await call(tools, "fetch_document", ["id": "doc-typed"])
        #expect(typed.structuredContent == nil)
        let text = texts(typed)[0]
        #expect(text.contains("--- Page 1 of 2 ---\n\n# Seed order\n\nMarigolds for the beds."))
        #expect(
            text.contains(
                "Budget notes\n\n[This page also has handwriting or drawings. Call fetch_page_image with page_no 2"
            )
        )
        let ink = texts(await call(tools, "fetch_document", ["id": "doc-ink"]))[0]
        #expect(
            ink.contains("[Handwriting or a drawing without text. Call fetch_page_image with page_no 1 to see it.]")
        )
    }

    @Test func fetchDocumentRangesAndLimits() async throws {
        let tools = try await stockedTools()
        let clamped = texts(
            await call(tools, "fetch_document", ["id": "doc-typed", "pages": ["start": 2, "end": 99]])
        )[0]
        #expect(clamped.contains("--- Page 2 of 2 ---") && !clamped.contains("--- Page 1 of 2 ---"))

        let long = texts(await call(tools, "fetch_document", ["id": "doc-long"]))[0]
        #expect(long.contains("--- Stopped before page 9 of 12"))
        #expect(long.contains(#"pages {"start": 9, "end": 12} for the rest"#))
        #expect(long.count < 31_000)

        let both = await call(tools, "fetch_document", ["id": "doc-ink", "ids": ["doc-ink"]])
        #expect(both.isError == true && texts(both)[0] == "Give exactly one of id or ids.")
        let unknown = await call(tools, "fetch_document", ["id": "nope"])
        #expect(unknown.isError == true && texts(unknown)[0].contains("Call list_documents or search_documents"))
        let several = await call(tools, "fetch_document", ["ids": ["doc-ink", "doc-typed"]])
        #expect(texts(several).count == 2)
    }

    @Test func pageImageAndChunks() async throws {
        let tools = try await stockedTools()
        let image = await call(tools, "fetch_page_image", ["id": "doc-ink", "page_no": 1])
        guard case .image(let data, let mimeType, _, _) = image.content.first else {
            Issue.record("expected an image")
            return
        }
        #expect(mimeType == "image/png" && Data(base64Encoded: data)!.count > 1000)
        #expect(texts(image)[0].contains("PNG, 1500 x 2000 pixels"))
        let out = await call(tools, "fetch_page_image", ["id": "doc-ink", "page_no": 3])
        #expect(
            out.isError == true && texts(out)[0] == "Raised Bed Sketch has pages 1 to 1; page_no 3 is out of range."
        )

        let chunks = await call(tools, "fetch_page_chunks", ["id": "doc-ink", "page_no": 1])
        #expect(chunks.content.count == 5)  // two labels, two images, and the JSON
        let object = try JSONSerialization.jsonObject(with: Data(texts(chunks).last!.utf8)) as! [String: Any]
        #expect(object["chunk_count"] as? Int == 4 && object["next_idx"] as? Int == 2)
        let last = await call(tools, "fetch_page_chunks", ["id": "doc-ink", "page_no": 1, "after_idx": 2])
        let lastObject = try JSONSerialization.jsonObject(with: Data(texts(last).last!.utf8)) as! [String: Any]
        #expect(lastObject["next_idx"] == nil)
    }

    @Test func overviewRefreshAndStatus() async throws {
        let tools = try await stockedTools()
        let overview = texts(await call(tools, "get_overview"))[0]
        #expect(overview.contains("3 documents in 1 folders"))
        #expect(overview.contains("id: doc-long · notebook · path: Keeper's Log"))
        let refresh = texts(await call(tools, "refresh_documents", ["source": "cloud"]))[0]
        #expect(refresh.hasPrefix("Refreshed from the cloud"))
        #expect(await call(tools, "refresh_documents", ["source": "ftp"]).isError == true)
        let status = try json(await call(tools, "status"))
        #expect(status["documents"] as? Int == 3)
        let cloud = status["cloud"] as! [String: Any]
        #expect(cloud["available"] as? Bool == true && cloud["last_success"] == nil && cloud["last_error"] == nil)
        let usb = status["usb"] as! [String: Any]
        #expect(usb["last_success"] is String && usb["last_error"] == nil)
        #expect((status["mirror"] as? [String: Any])?["source"] as? String == "usb")
    }

    @Test func resultsSayWhereTheMirrorCameFromAndHowOldItIs() async throws {
        let tools = try await stockedTools(now: { Date().addingTimeInterval(3 * 3600 + 30) })
        let list = try json(await call(tools, "list_documents"))
        let mirror = try #require(list["mirror"] as? [String: Any])
        #expect(mirror["source"] as? String == "usb" && mirror["age"] as? String == "3 hours")
        #expect((mirror["age_seconds"] as? Int ?? 0) >= 3 * 3600)
        #expect((list["documents"] as! [[String: Any]]).allSatisfy { $0["source"] as? String == "usb" })
        let search = try json(await call(tools, "search_documents", ["query": "marigolds"]))
        #expect((search["mirror"] as? [String: Any])?["age"] as? String == "3 hours")

        let text = texts(await call(tools, "fetch_document", ["id": "doc-typed"]))[0]
        #expect(text.contains("· copied from USB\nThe mirror was refreshed from USB 3 hours ago, at "))
        let image = texts(await call(tools, "fetch_page_image", ["id": "doc-ink", "page_no": 1]))[0]
        #expect(image.contains("Copied from USB. The mirror was refreshed from USB 3 hours ago"))
        let chunks = await call(tools, "fetch_page_chunks", ["id": "doc-ink", "page_no": 1])
        let object = try JSONSerialization.jsonObject(with: Data(texts(chunks).last!.utf8)) as! [String: Any]
        #expect((object["mirror"] as? [String: Any])?["source"] as? String == "usb")
        let overview = texts(await call(tools, "get_overview"))[0]
        #expect(overview.contains("The mirror was refreshed from USB 3 hours ago"))
    }

    @Test func statusShowsAnErrorUntilALaterSuccess() async throws {
        let tools = try await stockedTools()
        try tools.library.recordRefreshFailure(.cloud, "invented cloud failure")
        let failed = try json(await call(tools, "status"))
        let cloud = failed["cloud"] as! [String: Any]
        #expect(cloud["last_error"] as? String == "invented cloud failure" && cloud["last_error_at"] is String)
        #expect(texts(await call(tools, "get_overview"))[0].contains("The last refresh from the cloud failed at "))

        try tools.library.recordRefreshSuccess(.cloud)
        let recovered = try json(await call(tools, "status"))
        let after = recovered["cloud"] as! [String: Any]
        #expect(after["last_error"] == nil && after["last_success"] is String)
        #expect((recovered["mirror"] as? [String: Any])?["source"] as? String == "cloud")
    }

    @Test func agesInWords() {
        #expect(RePossessTools.ageText(seconds: 0) == "0 seconds")
        #expect(RePossessTools.ageText(seconds: 1) == "1 second")
        #expect(RePossessTools.ageText(seconds: 59) == "59 seconds")
        #expect(RePossessTools.ageText(seconds: 60) == "1 minute")
        #expect(RePossessTools.ageText(seconds: 7_300) == "2 hours")
        #expect(RePossessTools.ageText(seconds: 90_000) == "1 day")
    }
}

@Suite struct RefreshFallbackTests {
    @Test func autoFallsBackToTheCloudAfterAUSBTimeout() async throws {
        let tablet = FakeTablet()
        await tablet.setHang(true)
        let cloud = FakeCloud()
        let entry = try await cloud.seedDocument(
            id: "doc-cloud",
            files: [
                (
                    "doc-cloud.metadata",
                    Data(#"{"visibleName": "Invented", "type": "DocumentType", "parent": ""}"#.utf8)
                ),
                ("doc-cloud.content", Data(#"{"fileType": "notebook", "cPages": {"pages": []}}"#.utf8)),
            ]
        )
        try await cloud.seedRoot([entry])
        let library = try Library(
            root: FileManager.default.temporaryDirectory.appending(path: "repossess-fallback-\(UUID().uuidString)")
        )
        let reports = try await refreshLibrary(
            library,
            .auto,
            session: CloudSession(transport: cloud, deviceToken: { FakeCloud.deviceToken }),
            usb: { USBClient(transport: tablet, checkInterface: { true }) },
            usbPresent: { true }
        )
        #expect(reports.map(\.source) == [.usb, .cloud])
        #expect(reports[0].stoppedBy?.contains("off and on") == true)
        #expect(try library.documents().map(\.name) == ["Invented"])
        #expect(await tablet.paths == ["/documents/"])
    }

    @Test func autoUsesOnlyTheCloudWithoutUSB() async throws {
        let cloud = FakeCloud()
        try await cloud.seedRoot([])
        let library = try Library(
            root: FileManager.default.temporaryDirectory.appending(path: "repossess-fallback-\(UUID().uuidString)")
        )
        let reports = try await refreshLibrary(
            library,
            .auto,
            session: CloudSession(transport: cloud, deviceToken: { FakeCloud.deviceToken }),
            usb: { fatalError("no USB client without the USB network") },
            usbPresent: { false }
        )
        #expect(reports.map(\.source) == [.cloud])
    }
}
