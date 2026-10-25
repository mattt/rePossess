import Foundation
import MCP
import RePossessCloud
import RePossessFormat
import RePossessLibrary
import RePossessRender
import RePossessUSB

/// What `refresh_documents` refreshes from.
public enum RefreshSource: String, Sendable {
    /// USB when the tablet is on the Mac's USB network, and the cloud otherwise.
    case auto
    case usb
    case cloud
}

/// The read tools, with the schemas and rules of the design's "MCP tools" section (spike 7).
///
/// - Pages are numbered from 1 in every tool.
/// - A result with `structuredContent` has the same JSON as its only text;
///   a result with Markdown or hints has `content` only,
///   because Claude Code 2.1.310 showed the model `structuredContent` in place of `content`.
/// - Errors are `isError` results that say what to call instead.
public struct ReadTools: Sendable {
    public let library: Library
    let loader: PageLoader
    let refresh: @Sendable (RefreshSource) async throws -> [RefreshReport]
    let usbConnected: @Sendable () -> Bool
    let cloudPaired: @Sendable () -> Bool

    /// The most text that one `fetch_document` call returns, in characters.
    /// About 7,500 tokens: under Claude Code's 10,000-token warning
    /// and its 50,000-character limit before it saves a result to a file.
    public static let textBudget = 30_000
    /// Page images fit in 1500 x 2000 pixels; a 3:4 page fills it.
    public static let imageWidth: CGFloat = 1500
    public static let imageHeight: CGFloat = 2000
    /// Strips are 2000 pixels wide and a quarter of a screen high, with 40 pixels of overlap.
    public static let chunkWidth: CGFloat = 2000
    public static let chunksPerScreen = 4
    public static let chunkOverlap: CGFloat = 40
    public static let chunksPerCall = 2

    public init(
        library: Library,
        refresh: @escaping @Sendable (RefreshSource) async throws -> [RefreshReport],
        usbConnected: @escaping @Sendable () -> Bool = USBNetwork.isPresent,
        cloudPaired: @escaping @Sendable () -> Bool = DeviceTokenKeychain.exists
    ) {
        self.library = library
        self.loader = PageLoader(library: library)
        self.refresh = refresh
        self.usbConnected = usbConnected
        self.cloudPaired = cloudPaired
    }

    // MARK: Schemas

    static let readOnly = Tool.Annotations(readOnlyHint: true, openWorldHint: false)

    static let idProperty: Value = [
        "type": "string",
        "description": "A document ID from list_documents or search_documents. Never guess one.",
    ]
    static let pageNoProperty: Value = [
        "type": "integer", "minimum": 1,
        "description": "The page number, starting at 1, as the tablet shows it.",
    ]

    public static let all: [Tool] = [
        Tool(
            name: "get_overview",
            title: "Overview",
            description: """
                Start here for questions about the user's reMarkable notes. \
                Returns the library's size and the most recently changed documents, \
                each with its id, folder path, and the start of its text.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer", "minimum": 1, "maximum": 50, "default": 10,
                        "description": "How many recent documents to show.",
                    ]
                ],
                "additionalProperties": false,
            ],
            annotations: readOnly
        ),
        Tool(
            name: "list_documents",
            title: "List documents",
            description: """
                List the tablet's folders and documents, with each document's folder path, \
                page count, modification time, text status, tags, and page tags.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "tag": [
                        "type": "string", "description": "Only documents with this tag, on the document or on a page.",
                    ]
                ],
                "additionalProperties": false,
            ],
            annotations: readOnly
        ),
        Tool(
            name: "search_documents",
            title: "Search documents",
            description: """
                Search document names, tags, and text for words. Every word must appear in a page; \
                case and accents are ignored, and a word matches the start of a longer word. \
                Each result has the page number of the match and a snippet. \
                Handwriting is not searchable yet.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "minLength": 1, "description": "The words to find."],
                    "limit": [
                        "type": "integer", "minimum": 1, "maximum": 200, "default": 50,
                        "description": "The most results to return.",
                    ],
                    "tag": ["type": "string", "description": "Only documents with this tag."],
                ],
                "required": ["query"],
                "additionalProperties": false,
            ],
            annotations: readOnly
        ),
        Tool(
            name: "fetch_document",
            title: "Fetch document text",
            description: """
                Return documents as Markdown, page by page. Give exactly one of id or ids. \
                Pages are numbered from 1. A page with handwriting or drawings says so; \
                call fetch_page_image to see it. One call returns at most \(textBudget) characters; \
                when it stops early, the result names the next pages to ask for.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": idProperty,
                    "ids": [
                        "type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 8,
                        "description": "Up to 8 document IDs. Use instead of id.",
                    ],
                    "pages": [
                        "type": "object",
                        "description":
                            "The pages to return, from start to end inclusive, numbered from 1. Out-of-range values are clamped. Omit for the whole document.",
                        "properties": [
                            "start": ["type": "integer", "minimum": 1],
                            "end": ["type": "integer", "minimum": 1],
                        ],
                        "additionalProperties": false,
                    ],
                ],
                "additionalProperties": false,
            ],
            annotations: readOnly
        ),
        Tool(
            name: "fetch_page_image",
            title: "Fetch page image",
            description: """
                Return one page as a PNG image that fits in 1500 by 2000 pixels, \
                to read handwriting, drawings, or layout.
                """,
            inputSchema: [
                "type": "object",
                "properties": ["id": idProperty, "page_no": pageNoProperty],
                "required": ["id", "page_no"],
                "additionalProperties": false,
            ],
            annotations: readOnly
        ),
        Tool(
            name: "fetch_page_chunks",
            title: "Fetch page chunks",
            description: """
                Return a page as horizontal strips, 2000 pixels wide, top to bottom, \
                \(chunksPerCall) strips per call, for small handwriting that the whole-page image \
                shows too small. A screen is \(chunksPerScreen) strips; a long page has more. \
                Strips overlap by about a line. Pass the result's next_idx as after_idx to get the next strips.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": idProperty,
                    "page_no": pageNoProperty,
                    "after_idx": [
                        "type": "integer", "minimum": 0, "default": 0,
                        "description": "Return the strips after this one; strips are numbered from 1.",
                    ],
                ],
                "required": ["id", "page_no"],
                "additionalProperties": false,
            ],
            annotations: readOnly
        ),
        Tool(
            name: "refresh_documents",
            title: "Refresh documents",
            description: """
                Read the tablet's documents again, over USB when the tablet is connected by cable \
                and through reMarkable's cloud otherwise. Only changed documents are downloaded. \
                Call it when a document that the user just made is missing.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "source": [
                        "type": "string", "enum": ["auto", "usb", "cloud"], "default": "auto",
                        "description": "Where to read from.",
                    ]
                ],
                "additionalProperties": false,
            ],
            annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: true)
        ),
        Tool(
            name: "status",
            title: "Status",
            description: """
                Report how rePossess reaches the tablet, when the mirror was last refreshed, \
                the number of documents, and the handwriting recognizer.
                """,
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
            annotations: readOnly
        ),
    ]

    // MARK: Calls

    public func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        let arguments = params.arguments ?? [:]
        do {
            switch params.name {
            case "get_overview": return try overview(arguments)
            case "list_documents": return try listDocuments(arguments)
            case "search_documents": return try searchDocuments(arguments)
            case "fetch_document": return try fetchDocument(arguments)
            case "fetch_page_image": return try fetchPageImage(arguments)
            case "fetch_page_chunks": return try fetchPageChunks(arguments)
            case "refresh_documents": return try await refreshDocuments(arguments)
            case "status": return try status()
            default: throw ToolError("Unknown tool \(params.name).")
            }
        } catch let error as ToolError {
            return .init(content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(content: [.text(text: "\(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    // MARK: Argument helpers

    static func string(_ arguments: [String: Value], _ key: String) -> String? {
        arguments[key]?.stringValue
    }

    /// Reads an integer, and accepts a whole double or a numeric string,
    /// because clients do not all send JSON integers.
    static func integer(_ arguments: [String: Value], _ key: String) throws -> Int? {
        guard let value = arguments[key], !value.isNull else { return nil }
        if let int = value.intValue { return int }
        if let double = value.doubleValue, double == double.rounded() { return Int(double) }
        if let string = value.stringValue, let int = Int(string) { return int }
        throw ToolError("\(key) must be an integer.")
    }

    static func text(_ markdown: String) -> CallTool.Result {
        .init(content: [.text(text: markdown, annotations: nil, _meta: nil)])
    }

    static func json(_ value: some Codable) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return try .init(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: value
        )
    }

    static let dateFormat = Date.ISO8601FormatStyle()

    static func date(_ date: Date?) -> String { date.map { dateFormat.format($0) } ?? "" }
}
