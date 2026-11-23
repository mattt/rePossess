import Foundation
import MCP
import Testing

@testable import RePossessLibrary
@testable import RePossessMCP
@testable import RePossessUSB

/// The ways that a JSON value breaks a schema: a missing required property, an undeclared key,
/// a value of another JSON type, a value outside an `enum`, or an integer below its `minimum`.
///
/// It reads only the keywords that the output schemas use.
func violations(_ value: Value, _ schema: Value, at path: String = "$") -> [String] {
    guard let schema = schema.objectValue, let type = schema["type"]?.stringValue else {
        return ["\(path): the schema has no type"]
    }
    switch (type, value) {
    case ("object", .object(let object)):
        let properties = schema["properties"]?.objectValue ?? [:]
        let required = (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        var found = required.filter { object[$0] == nil }.map { "\(path).\($0): required but absent" }
        if schema["additionalProperties"] != false { found.append("\(path): the object is not closed") }
        for (key, child) in object.sorted(by: { $0.key < $1.key }) {
            guard let property = properties[key] else {
                found.append("\(path).\(key): not declared")
                continue
            }
            found += violations(child, property, at: "\(path).\(key)")
        }
        return found
    case ("array", .array(let items)):
        guard let itemSchema = schema["items"] else { return ["\(path): the array has no items schema"] }
        return items.enumerated().flatMap { violations($1, itemSchema, at: "\(path)[\($0)]") }
    case ("string", .string(let string)):
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(.string(string)) {
            return ["\(path): \(string) is not in the enum"]
        }
        return []
    case ("integer", .int(let int)):
        if let minimum = schema["minimum"]?.intValue, int < minimum { return ["\(path): \(int) < \(minimum)"] }
        return []
    case ("boolean", .bool):
        return []
    default:
        return ["\(path): \(value) is not a JSON \(type)"]
    }
}

/// The violations of a result against a tool's output schema,
/// for its `structuredContent` and for the JSON in its text.
func violations(_ result: CallTool.Result, tool name: String) throws -> [String] {
    let tool = try #require(RePossessTools.all.first { $0.name == name })
    let schema = try #require(tool.outputSchema)
    let structured = try #require(result.structuredContent)
    let text = try JSONDecoder().decode(Value.self, from: Data(texts(result)[0].utf8))
    return violations(structured, schema) + violations(text, schema)
}

/// The keys of an encoded result's object, to show which optional properties a sample leaves out.
func keys(_ result: CallTool.Result) throws -> Set<String> {
    Set(try #require(result.structuredContent?.objectValue).keys)
}

@Suite struct OutputSchemaTests {
    static let structured = ["list_documents", "search_documents", "push_markdown", "push_file", "status"]

    static let mirror = RePossessTools.MirrorEntry(
        source: "usb",
        refreshed: "2026-10-20T07:00:00Z",
        age_seconds: 10_800,
        age: "3 hours"
    )

    @Test func onlyToolsWithStructuredContentHaveAnOutputSchema() {
        for tool in RePossessTools.all {
            #expect((tool.outputSchema != nil) == Self.structured.contains(tool.name), "\(tool.name)")
            guard let schema = tool.outputSchema?.objectValue else { continue }
            #expect(schema["type"] == "object" && schema["additionalProperties"] == false, "\(tool.name)")
        }
    }

    @Test func toolsListIncludesTheOutputSchemas() throws {
        let listed = try JSONDecoder().decode(
            [Tool].self,
            from: JSONEncoder().encode(RePossessTools.all)
        )
        for tool in listed {
            #expect((tool.outputSchema != nil) == Self.structured.contains(tool.name), "\(tool.name)")
        }
    }

    @Test func listResultsMatchTheirSchema() throws {
        let folder = RePossessTools.FolderEntry(id: "folder-1", name: "Garden", parent: "", path: "Garden")
        let document = RePossessTools.DocumentEntry(
            id: "doc-1",
            name: "Seed Order",
            parent: "folder-1",
            path: "Garden/Seed Order",
            modified: "",
            file_type: "notebook",
            page_count: 2,
            content_status: "partial",
            summary: "Marigolds for the beds.",
            tags: ["garden"],
            page_tags: [.init(page_no: 2, tag: "budget")],
            source: "cloud"
        )
        let full = try RePossessTools.json(
            RePossessTools.ListResult(folders: [folder], documents: [document], mirror: Self.mirror)
        )
        #expect(try violations(full, tool: "list_documents").isEmpty)
        let empty = try RePossessTools.json(RePossessTools.ListResult(folders: [], documents: [], mirror: nil))
        #expect(try keys(empty) == ["folders", "documents"])
        #expect(try violations(empty, tool: "list_documents").isEmpty)
    }

    @Test func searchResultsMatchTheirSchema() throws {
        func entry(_ match: String, _ pageNo: Int?) -> RePossessTools.SearchEntry {
            .init(
                id: "doc-1",
                name: "Seed Order",
                path: "Seed Order",
                file_type: "pdf",
                content_status: "annotated",
                match: match,
                page_no: pageNo,
                snippet: "marigolds"
            )
        }
        let result = try RePossessTools.json(
            RePossessTools.SearchResult(
                query: "marigold",
                total: 3,
                results: [entry("name", nil), entry("handwriting", 4)],
                mirror: nil
            )
        )
        let results = try #require(result.structuredContent?.objectValue?["results"]?.arrayValue)
        #expect(results[0].objectValue?["page_no"] == nil && results[1].objectValue?["page_no"] == 4)
        #expect(try keys(result) == ["query", "total", "results"])
        #expect(try violations(result, tool: "search_documents").isEmpty)
    }

    @Test(arguments: ["push_markdown", "push_file"])
    func pushResultsMatchTheirSchema(tool: String) throws {
        let queued = PushRecord(
            id: "00000000-0000-4000-8000-000000000001",
            kind: .pdf,
            title: "rePossess test",
            bytes: 2048,
            pages: nil,
            created: Date(timeIntervalSince1970: 0),
            status: .pending,
            via: nil,
            attempts: 0,
            lastAttempt: nil,
            sent: nil,
            tabletID: nil,
            preexisting: [],
            error: nil,
            folder: nil,
            folderID: nil,
            folderIsNew: nil
        )
        var sent = queued
        sent.kind = .notebook
        sent.pages = 2
        sent.status = .sent
        sent.via = .cloud
        sent.tabletID = "00000000-0000-4000-8000-000000000001"
        sent.folder = "Garden"
        let minimal = try RePossessTools.json(PushResult(queued))
        #expect(try keys(minimal) == ["push_id", "title", "kind", "status", "bytes", "message"])
        #expect(try violations(minimal, tool: tool).isEmpty)
        let full = try RePossessTools.json(PushResult(sent))
        #expect(try keys(full).isSuperset(of: ["via", "tablet_id", "pages", "folder"]))
        #expect(try violations(full, tool: tool).isEmpty)
        for status in [PushStatus.unknown, .failed] {
            var record = sent
            record.status = status
            #expect(try violations(RePossessTools.json(PushResult(record)), tool: tool).isEmpty)
        }
    }

    @Test func statusResultsMatchTheirSchema() throws {
        let off = RePossessTools.RecognizerStatus(
            state: "off",
            provider: nil,
            model: nil,
            label: nil,
            page_images_go_to: nil,
            pages_with_handwriting: nil,
            pages_recognized: nil,
            pages_without_words: nil,
            pages_refused: nil,
            pages_waiting: nil,
            note: "Handwriting recognition is off."
        )
        let ready = RePossessTools.RecognizerStatus(
            state: "ready",
            provider: "ollama",
            model: "invented-vision",
            label: "invented-vision (Ollama)",
            page_images_go_to: "the Ollama server on this Mac",
            pages_with_handwriting: 5,
            pages_recognized: 3,
            pages_without_words: 1,
            pages_refused: 0,
            pages_waiting: 1,
            note: "fetch_document includes recognized handwriting."
        )
        let never = RePossessTools.TransportStatus(
            available: false,
            last_success: nil,
            last_error: nil,
            last_error_at: nil
        )
        let failed = RePossessTools.TransportStatus(
            available: true,
            last_success: "2026-10-20T07:00:00Z",
            last_error: "The tablet did not answer.",
            last_error_at: "2026-10-21T07:00:00Z"
        )
        let minimal = try RePossessTools.json(
            RePossessTools.StatusResult(
                library: "/tmp/library",
                documents: 0,
                folders: 0,
                pages: 0,
                usb: never,
                cloud: never,
                mirror: nil,
                pushes: [:],
                recognizer: off
            )
        )
        #expect(!(try keys(minimal).contains("mirror")))
        #expect(minimal.structuredContent?.objectValue?["usb"]?.objectValue?.keys.sorted() == ["available"])
        #expect(try violations(minimal, tool: "status").isEmpty)
        let full = try RePossessTools.json(
            RePossessTools.StatusResult(
                library: "/tmp/library",
                documents: 3,
                folders: 1,
                pages: 15,
                usb: failed,
                cloud: never,
                mirror: Self.mirror,
                pushes: ["queued": 1, "unknown": 1, "sent": 2, "failed": 1],
                recognizer: ready
            )
        )
        #expect(try violations(full, tool: "status").isEmpty)
    }

    @Test func liveResultsMatchTheirSchemas() async throws {
        let tools = try await stockedTools()
        let list = await call(tools, "list_documents")
        #expect(try violations(list, tool: "list_documents").isEmpty)
        let search = await call(tools, "search_documents", ["query": "marigolds"])
        #expect(try violations(search, tool: "search_documents").isEmpty)
        let status = await call(tools, "status")
        #expect(try violations(status, tool: "status").isEmpty)

        let push = await call(
            try await writableTools(tablet: FakeTablet(), paths: { .none }),
            "push_markdown",
            ["title": "rePossess test", "markdown": "- one"]
        )
        #expect(try violations(push, tool: "push_markdown").isEmpty)
    }

    @Test func theValidatorFindsViolations() {
        let schema = RePossessTools.pushOutputSchema
        let value: Value = ["push_id": 1, "status": "lost", "extra": true]
        let found = violations(value, schema)
        #expect(found.contains("$.push_id: 1 is not a JSON string"))
        #expect(found.contains("$.status: lost is not in the enum"))
        #expect(found.contains("$.extra: not declared"))
        #expect(found.contains("$.title: required but absent"))
    }
}
