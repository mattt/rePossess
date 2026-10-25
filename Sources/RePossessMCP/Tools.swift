import Foundation
import MCP
import RePossessCloud
import RePossessFormat
import RePossessLibrary
import RePossessRecognize
import RePossessRender
import RePossessUSB

/// What `refresh_documents` refreshes from.
public enum RefreshSource: String, Sendable {
    /// USB when the tablet is on the Mac's USB network, and the cloud otherwise.
    case auto
    case usb
    case cloud
}

/// The tools, with the schemas and rules of the design's "MCP tools" section (spike 7):
/// the read tools, from phase 3 `push_markdown` and `push_file`, and from phase 4 `recognize_pages`.
///
/// - Pages are numbered from 1 in every tool.
/// - A result with `structuredContent` has the same JSON as its only text;
///   a result with Markdown or hints has `content` only,
///   because Claude Code 2.1.310 showed the model `structuredContent` in place of `content`.
/// - Errors are `isError` results that say what to call instead.
public struct RePossessTools: Sendable {
    public let library: Library
    let loader: PageLoader
    let refresh: @Sendable (RefreshSource) async throws -> [RefreshReport]
    let usbConnected: @Sendable () -> Bool
    let cloudPaired: @Sendable () -> Bool
    let now: @Sendable () -> Date
    /// Queues and sends pushes; `nil` turns the push tools off.
    let pusher: Pusher?
    /// The handwriting recognizer, when the owner configures one.
    let recognition: RecognitionContext

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
        cloudPaired: @escaping @Sendable () -> Bool = DeviceTokenKeychain.exists,
        now: @escaping @Sendable () -> Date = Date.init,
        pusher: Pusher? = nil,
        recognition: RecognitionContext? = nil
    ) {
        self.pusher = pusher
        self.recognition = recognition ?? .live(library: library)
        self.library = library
        self.loader = PageLoader(library: library)
        self.refresh = refresh
        self.usbConnected = usbConnected
        self.cloudPaired = cloudPaired
        self.now = now
    }

    // MARK: Schemas

    static let readOnly = Tool.Annotations(readOnlyHint: true, openWorldHint: false)
    static let write = Tool.Annotations(
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
    )

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
                page count, modification time, text status, tags, and page tags, \
                and where the mirror came from and how old it is.
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
                match is handwriting when the words are in handwriting that the owner's recognizer read as text; \
                handwriting that has not been recognized is not searchable.
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
                Pages are numbered from 1. When the owner has configured a handwriting recognizer, \
                handwriting that it has read comes as text, labeled with the recognizer; \
                otherwise a page with handwriting or drawings says so and names the tool to call: \
                fetch_page_image to see it, or recognize_pages to read it as text. \
                One call returns at most \(textBudget) characters; \
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
            name: "recognize_pages",
            title: "Recognize handwriting",
            description: """
                Read the handwriting on a document's pages as text, with the recognizer that the owner configured, \
                and keep the text, so that fetch_document and search_documents include it. \
                Pages already read come from the cache at once; each new page takes a few seconds for each screen \
                of handwriting. One call starts new pages for about \(Int(RecognitionContext.defaultBudgetSeconds)) seconds, \
                and the result names the pages that remain. \
                Fails when recognition is off.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": idProperty,
                    "pages": [
                        "type": "object",
                        "description":
                            "The pages to read, from start to end inclusive, numbered from 1. Out-of-range values are clamped. Omit for the whole document.",
                        "properties": [
                            "start": ["type": "integer", "minimum": 1],
                            "end": ["type": "integer", "minimum": 1],
                        ],
                        "additionalProperties": false,
                    ],
                ],
                "required": ["id"],
                "additionalProperties": false,
            ],
            annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: true)
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
            name: "push_markdown",
            title: "Send Markdown to the tablet",
            description: """
                Send Markdown to the reMarkable tablet as a new notebook with typed text that the user can edit. \
                Side effects: every call creates a new document at the top level of the tablet's library; \
                it never changes or replaces an existing document, so calling it twice makes two copies. \
                Do not call it again to retry: check the result's status instead. \
                "sent" means the tablet or reMarkable's cloud has it; "queued" and "unknown" mean rePossess \
                sends it, or checks whether it arrived, at the next refresh; "failed" means it was refused. \
                Headings become Title (#) and Subheading (## to ######); bullets, nested bullets, and \
                task lists keep their styles; emphasis, links, and inline code become plain text; \
                numbered items keep their numbers; code blocks and tables become plain lines. \
                Limits: a title of 1 to \(MarkdownNotebook.maxTitleLength) characters on one line, \
                Markdown of at most \(MarkdownNotebook.maxMarkdownLength) characters, \
                and at most \(MarkdownNotebook.maxPages) pages.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string", "minLength": 1, "maxLength": .int(MarkdownNotebook.maxTitleLength),
                        "description": "The document's name on the tablet.",
                    ],
                    "markdown": [
                        "type": "string", "minLength": 1, "maxLength": .int(MarkdownNotebook.maxMarkdownLength),
                        "description": "The note's text as Markdown.",
                    ],
                    "paginate": [
                        "type": "boolean", "default": false,
                        "description":
                            "Start a new page at each ## heading. By default all the text goes on one page, which the tablet makes as long as the text.",
                    ],
                ],
                "required": ["title", "markdown"],
                "additionalProperties": false,
            ],
            annotations: write
        ),
        Tool(
            name: "push_file",
            title: "Send a PDF or EPUB to the tablet",
            description: """
                Send a PDF or EPUB file to the reMarkable tablet as a new document. \
                Give exactly one of path, a file on this Mac, or url, an https URL that rePossess downloads. \
                Side effects: every call creates a new document at the top level of the tablet's library; \
                it never changes or replaces an existing document, so calling it twice makes two copies. \
                Do not call it again to retry: check the result's status instead. \
                "sent" means the tablet or reMarkable's cloud has it; "queued" and "unknown" mean rePossess \
                sends it, or checks whether it arrived, at the next refresh; "failed" means it was refused. \
                Limits: \(Library.maxPushBytes / 1_000_000) MB, https URLs only, \
                and a title of at most \(MarkdownNotebook.maxTitleLength) characters.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "A PDF or EPUB file on this Mac."],
                    "url": [
                        "type": "string", "description": "An https URL of a PDF or EPUB. Use instead of path.",
                    ],
                    "title": [
                        "type": "string", "minLength": 1, "maxLength": .int(MarkdownNotebook.maxTitleLength),
                        "description": "The document's name on the tablet. The default is the file's name.",
                    ],
                ],
                "additionalProperties": false,
            ],
            annotations: write
        ),
        Tool(
            name: "status",
            title: "Status",
            description: """
                Report how rePossess reaches the tablet, each source's last successful refresh and last error, \
                the age of the mirror, the number of documents, the pushes that wait, and the handwriting recognizer.
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
            case "get_overview": return try await overview(arguments)
            case "list_documents": return try listDocuments(arguments)
            case "search_documents": return try searchDocuments(arguments)
            case "fetch_document": return try await fetchDocument(arguments)
            case "recognize_pages": return try await recognizePages(arguments)
            case "fetch_page_image": return try fetchPageImage(arguments)
            case "fetch_page_chunks": return try fetchPageChunks(arguments)
            case "refresh_documents": return try await refreshDocuments(arguments)
            case "push_markdown": return try await pushMarkdown(arguments)
            case "push_file": return try await pushFile(arguments)
            case "status": return try await status()
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

    // MARK: Mirror age

    /// Where the mirror came from and how old it is, as tool results report it.
    struct MirrorEntry: Codable, Equatable {
        /// `usb` or `cloud`: the source of the most recent refresh that finished.
        let source: String
        /// When that refresh finished.
        let refreshed: String
        let age_seconds: Int
        /// The age in words, such as "3 hours".
        let age: String
    }

    static func sourceName(_ source: Source) -> String { source == .usb ? "USB" : "the cloud" }

    /// An age in the largest whole unit, such as "45 seconds", "1 minute", or "3 days".
    static func ageText(seconds: Int) -> String {
        let units = [(86_400, "day"), (3_600, "hour"), (60, "minute"), (1, "second")]
        let seconds = max(seconds, 0)
        for (size, name) in units where seconds >= size {
            let n = seconds / size
            return "\(n) \(name)\(n == 1 ? "" : "s")"
        }
        return "0 seconds"
    }

    func mirror(_ status: LibraryStatus) -> MirrorEntry? {
        guard let latest = status.latestRefresh else { return nil }
        let age = Int(now().timeIntervalSince(latest.date).rounded(.down))
        return MirrorEntry(
            source: latest.source.rawValue,
            refreshed: Self.date(latest.date),
            age_seconds: max(age, 0),
            age: Self.ageText(seconds: age)
        )
    }

    func mirror() throws -> MirrorEntry? { mirror(try library.status()) }

    /// A sentence such as "The mirror was refreshed from the cloud 3 hours ago, at ...".
    func mirrorSentence(_ status: LibraryStatus) -> String {
        guard let latest = status.latestRefresh, let entry = mirror(status) else {
            return "The mirror has never been refreshed; call refresh_documents."
        }
        return
            "The mirror was refreshed from \(Self.sourceName(latest.source)) \(entry.age) ago, at \(entry.refreshed)."
    }
}
