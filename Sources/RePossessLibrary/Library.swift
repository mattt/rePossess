import Foundation
import RePossessFormat
import Synchronization

/// What a client must look at to read a document: text, ink, or images.
///
/// Phase 2's live check found that a client looking for a handwritten notebook
/// could not tell one from a scanned PDF, because both were `ink`;
/// phase 3 separates ink on notebook pages, ink on PDF pages, and PDF pages without text.
public enum ContentStatus: String, Sendable, Codable {
    /// Every page has text, or has nothing to read; a page may also have some ink.
    case text
    /// Some pages have text, and some notebook pages or PDF pages have none.
    case partial
    /// No page has text, and notebook pages have handwriting or drawings: a handwritten notebook.
    case ink
    /// A PDF or EPUB with handwriting or drawings on its own pages, which the page images show.
    case annotated
    /// No page has text or ink: PDF or EPUB pages without a text layer, such as scans.
    case image
}

/// Where a document's files came from.
public enum Source: String, Sendable, Codable {
    case usb
    case cloud
}

/// A folder or a document in the library.
public struct LibraryItem: Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: ItemKind
    /// The parent folder's ID, or empty for the top level.
    public var parent: String
    /// The folders and the name, joined by `/`.
    public var path: String
    /// `notebook`, `pdf`, or `epub`, for documents.
    public var fileType: String?
    public var modified: Date?
    public var pageCount: Int
    public var contentStatus: ContentStatus
    /// The first words of the document's text.
    public var summary: String
    public var tags: [String]
    /// Tags on pages: the page number and the tag.
    public var pageTags: [PageTag]
    public var source: Source
    /// When rePossess last wrote the item.
    public var refreshed: Date
    /// Why the document could not be read, when it could not.
    public var error: String?
}

/// A tag on one page.
public struct PageTag: Sendable, Equatable, Codable {
    public var pageNo: Int
    public var tag: String

    public init(pageNo: Int, tag: String) {
        self.pageNo = pageNo
        self.tag = tag
    }
}

/// One page of a document in the library.
public struct LibraryPage: Sendable, Equatable {
    public var documentID: String
    /// The page number, from 1.
    public var number: Int
    public var pageID: String
    /// The page of the document's PDF that this page shows, from 0.
    public var sourcePageIndex: Int?
    /// The page's text as Markdown: typed text, the text of a PDF page, and highlights.
    public var markdown: String
    public var hasText: Bool
    /// Whether the page has ink, or is a PDF page without text,
    /// so that a client must look at the image to see all of it.
    public var needsImage: Bool
    public var strokeCount: Int
    /// Problems the reader skipped on this page.
    public var warnings: [String]
}

/// One match from ``Library/search(_:limit:tag:)``.
public struct SearchHit: Sendable, Equatable {
    public enum Match: String, Sendable { case name, tag, text }

    public var item: LibraryItem
    public var match: Match
    /// The page of a text or page tag match.
    public var pageNo: Int?
    public var snippet: String
}

/// The state of the library and of each transport's last refresh.
public struct LibraryStatus: Sendable, Equatable {
    public var root: URL
    public var documents: Int
    public var folders: Int
    public var pages: Int
    /// The time of each source's last refresh that finished.
    public var lastRefresh: [Source: Date]
    /// Each source's error since its last success, if its last refresh failed or stopped early.
    public var lastError: [Source: String]
    /// When each error in ``lastError`` happened, when the library knows.
    public var lastErrorAt: [Source: Date]
    public var cloudRootHash: String?
    public var cloudGeneration: Int64?

    /// The source of the most recent refresh that finished, and its time.
    public var latestRefresh: (source: Source, date: Date)? {
        lastRefresh.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}

/// The mirror of the tablet on the Mac and its index.
///
/// The mirror is a folder, by default `~/Library/Application Support/rePossess/`,
/// with `library.sqlite` and `documents/<id>/`, which holds each document's files
/// as an rmdoc archive lays them out.
/// The index is SQLite with FTS5, through the system `SQLite3` module.
/// Both transports fill the same library.
public final class Library: Sendable {
    /// The library's folder.
    public let root: URL
    let database: Database
    let refreshing = Mutex(false)

    /// The default folder: `~/Library/Application Support/rePossess/`.
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "rePossess", directoryHint: .isDirectory)
    }

    /// Opens the library in `root`, creating it if needed.
    public init(root: URL = Library.defaultRoot) throws {
        self.root = root
        try FileManager.default.createDirectory(at: documentsFolder(root), withIntermediateDirectories: true)
        database = try Database(url: root.appending(path: "library.sqlite"))
        try migrate()
    }

    var documentsURL: URL { documentsFolder(root) }

    /// The folder that holds a document's files.
    public func folder(for id: String) throws -> DocumentFolder {
        try DocumentFolder(id: id, url: documentsURL.appending(path: id, directoryHint: .isDirectory))
    }

    private func migrate() throws {
        let version = try database.query("PRAGMA user_version").first?.first?.int ?? 0
        if version < 1 { try migrateToVersion1() }
        if version < 2 { try migrateToVersion2() }
    }

    private func migrateToVersion1() throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                name TEXT NOT NULL,
                parent TEXT NOT NULL DEFAULT '',
                file_type TEXT,
                modified REAL,
                page_count INTEGER NOT NULL DEFAULT 0,
                content_status TEXT NOT NULL DEFAULT 'text',
                summary TEXT NOT NULL DEFAULT '',
                tags TEXT NOT NULL DEFAULT '[]',
                source TEXT NOT NULL,
                usb_modified TEXT,
                cloud_hash TEXT,
                trashed INTEGER NOT NULL DEFAULT 0,
                refreshed REAL NOT NULL,
                error TEXT
            );
            CREATE TABLE IF NOT EXISTS pages (
                document_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                number INTEGER NOT NULL,
                page_id TEXT NOT NULL,
                source_page INTEGER,
                markdown TEXT NOT NULL DEFAULT '',
                has_text INTEGER NOT NULL,
                needs_image INTEGER NOT NULL,
                stroke_count INTEGER NOT NULL,
                tags TEXT NOT NULL DEFAULT '[]',
                warnings TEXT NOT NULL DEFAULT '[]',
                PRIMARY KEY (document_id, number)
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS page_text USING fts5(
                document_id UNINDEXED, number UNINDEXED, body,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT);
            PRAGMA user_version = 1;
            """
        )
    }

    /// Phase 3: whether a document has typed text, the queue of pushes, and the tablet's PDF exports.
    ///
    /// Until a document is indexed again, `typed_text` comes from its pages:
    /// a notebook with a page of text has typed text.
    /// A PDF with a text box on a page gets the flag at its next download.
    /// `content_status` gains `annotated` and `image` from the stored pages.
    /// A refresh error without a time is cleared: before phase 2, a failed refresh
    /// wrote its error without a time, and `status` showed it as "time unknown" after later successes.
    private func migrateToVersion2() throws {
        try database.execute(
            """
            BEGIN;
            ALTER TABLE items ADD COLUMN typed_text INTEGER NOT NULL DEFAULT 0;
            UPDATE items SET typed_text = 1
              WHERE kind = 'DocumentType' AND file_type = 'notebook'
              AND EXISTS (SELECT 1 FROM pages WHERE pages.document_id = items.id AND pages.has_text = 1);
            CREATE TABLE IF NOT EXISTS pushes (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                payload TEXT NOT NULL,
                bytes INTEGER NOT NULL,
                pages INTEGER,
                created REAL NOT NULL,
                status TEXT NOT NULL,
                via TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_attempt REAL,
                sent REAL,
                tablet_id TEXT,
                preexisting TEXT NOT NULL DEFAULT '[]',
                error TEXT
            );
            CREATE TABLE IF NOT EXISTS exports (
                document_id TEXT PRIMARY KEY,
                modified REAL,
                pages INTEGER NOT NULL,
                bytes INTEGER NOT NULL,
                downloaded REAL NOT NULL
            );
            UPDATE items SET content_status = 'annotated'
              WHERE kind = 'DocumentType' AND EXISTS (SELECT 1 FROM pages WHERE pages.document_id = items.id
                AND pages.source_page IS NOT NULL AND pages.stroke_count > 0);
            UPDATE items SET content_status = 'image'
              WHERE content_status = 'ink' AND NOT EXISTS (SELECT 1 FROM pages WHERE pages.document_id = items.id
                AND pages.source_page IS NULL AND pages.stroke_count > 0);
            UPDATE state SET value = ''
              WHERE key IN ('usb.last_error', 'cloud.last_error') AND NOT EXISTS (
                SELECT 1 FROM state AS t WHERE t.key = replace(state.key, 'last_error', 'last_error_at')
                  AND t.value IS NOT NULL AND t.value != '');
            PRAGMA user_version = 2;
            COMMIT;
            """
        )
    }

    // MARK: Reading

    private static let itemColumns = """
        id, kind, name, parent, file_type, modified, page_count, content_status, summary, tags, source, refreshed, error
        """

    private func item(_ row: [SQLValue]) -> LibraryItem {
        LibraryItem(
            id: row[0].string ?? "",
            name: row[2].string ?? "",
            kind: ItemKind(rawValue: row[1].string ?? "") ?? .document,
            parent: row[3].string ?? "",
            path: "",
            fileType: row[4].string,
            modified: row[5].double.map(Date.init(timeIntervalSince1970:)),
            pageCount: row[6].int ?? 0,
            contentStatus: ContentStatus(rawValue: row[7].string ?? "") ?? .text,
            summary: row[8].string ?? "",
            tags: decodeJSON(row[9].string) ?? [],
            pageTags: [],
            source: Source(rawValue: row[10].string ?? "") ?? .usb,
            refreshed: Date(timeIntervalSince1970: row[11].double ?? 0),
            error: row[12].string
        )
    }

    /// Every folder and document that is not in the trash, with paths and page tags.
    public func items() throws -> [LibraryItem] {
        var items = try database.query("SELECT \(Self.itemColumns) FROM items WHERE trashed = 0").map(item)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var pageTags: [String: [PageTag]] = [:]
        for row in try database.query("SELECT document_id, number, tags FROM pages WHERE tags != '[]'") {
            let tags: [String] = decodeJSON(row[2].string) ?? []
            pageTags[row[0].string ?? "", default: []] += tags.map { PageTag(pageNo: row[1].int ?? 0, tag: $0) }
        }
        for i in items.indices {
            items[i].path = path(of: items[i], in: byID)
            items[i].pageTags = pageTags[items[i].id] ?? []
        }
        return items.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The folders, sorted by path.
    public func folders() throws -> [LibraryItem] { try items().filter { $0.kind == .folder } }

    /// The documents, sorted by path.
    public func documents() throws -> [LibraryItem] { try items().filter { $0.kind == .document } }

    /// One document or folder, or `nil`.
    public func item(id: String) throws -> LibraryItem? {
        try items().first { $0.id == id }
    }

    private func path(of item: LibraryItem, in items: [String: LibraryItem]) -> String {
        var parts = [item.name]
        var parent = item.parent
        var seen: Set<String> = [item.id]
        while !parent.isEmpty, let folder = items[parent], !seen.contains(parent) {
            seen.insert(parent)
            parts.insert(folder.name, at: 0)
            parent = folder.parent
        }
        return parts.joined(separator: "/")
    }

    /// The pages of a document, in order.
    public func pages(of id: String) throws -> [LibraryPage] {
        try database.query(
            """
            SELECT document_id, number, page_id, source_page, markdown, has_text, needs_image, stroke_count, warnings
            FROM pages WHERE document_id = ? ORDER BY number
            """,
            [.text(id)]
        ).map { row in
            LibraryPage(
                documentID: row[0].string ?? "",
                number: row[1].int ?? 0,
                pageID: row[2].string ?? "",
                sourcePageIndex: row[3].int,
                markdown: row[4].string ?? "",
                hasText: row[5].int == 1,
                needsImage: row[6].int == 1,
                strokeCount: row[7].int ?? 0,
                warnings: decodeJSON(row[8].string) ?? []
            )
        }
    }

    /// Searches names, tags, and page text.
    ///
    /// Names and tags match a case-insensitive substring.
    /// Page text uses FTS5: every word of the query must appear, each as a word or the start of one,
    /// ignoring case and accents. Text results are ordered by FTS5's rank.
    /// - Returns: The first `limit` hits and the total number of hits.
    public func search(_ query: String, limit: Int = 50, tag: String? = nil) throws -> (hits: [SearchHit], total: Int) {
        let documents = try documents().filter { hasTag($0, tag) }
        let byID = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var hits: [SearchHit] = []
        for document in documents where document.name.localizedStandardContains(query) {
            hits.append(SearchHit(item: document, match: .name, pageNo: nil, snippet: document.name))
        }
        for document in documents {
            for t in document.tags where t.localizedStandardContains(query) {
                hits.append(SearchHit(item: document, match: .tag, pageNo: nil, snippet: t))
            }
            for t in document.pageTags where t.tag.localizedStandardContains(query) {
                hits.append(SearchHit(item: document, match: .tag, pageNo: t.pageNo, snippet: t.tag))
            }
        }
        let words = query.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if !words.isEmpty {
            let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
            let rows = try database.query(
                """
                SELECT document_id, number, snippet(page_text, 2, '', '', '…', 16)
                FROM page_text WHERE page_text MATCH ? ORDER BY rank
                """,
                [.text(match)]
            )
            for row in rows {
                guard let document = byID[row[0].string ?? ""] else { continue }
                let snippet = (row[2].string ?? "").replacingOccurrences(of: "\n", with: " ")
                hits.append(SearchHit(item: document, match: .text, pageNo: row[1].int, snippet: snippet))
            }
        }
        return (Array(hits.prefix(max(limit, 0))), hits.count)
    }

    private func hasTag(_ item: LibraryItem, _ tag: String?) -> Bool {
        guard let tag else { return true }
        return item.tags.contains(tag) || item.pageTags.contains { $0.tag == tag }
    }

    /// The counts and the state of the last refreshes.
    public func status() throws -> LibraryStatus {
        let counts =
            try database.query(
                """
                SELECT
                  (SELECT count(*) FROM items WHERE trashed = 0 AND kind = 'DocumentType'),
                  (SELECT count(*) FROM items WHERE trashed = 0 AND kind = 'CollectionType'),
                  (SELECT count(*) FROM pages)
                """
            ).first ?? []
        let state = try stateValues()
        var lastRefresh: [Source: Date] = [:]
        var lastError: [Source: String] = [:]
        var lastErrorAt: [Source: Date] = [:]
        for source in [Source.usb, .cloud] {
            let success = state["\(source.rawValue).last_refresh"].flatMap(Double.init)
            let failure = state["\(source.rawValue).last_error_at"].flatMap(Double.init)
            if let success { lastRefresh[source] = Date(timeIntervalSince1970: success) }
            // An error older than a later success is stale.
            if let e = state["\(source.rawValue).last_error"], !e.isEmpty, (failure ?? .infinity) > (success ?? 0) {
                lastError[source] = e
                if let failure { lastErrorAt[source] = Date(timeIntervalSince1970: failure) }
            }
        }
        return LibraryStatus(
            root: root,
            documents: counts.first?.int ?? 0,
            folders: counts.dropFirst().first?.int ?? 0,
            pages: counts.dropFirst(2).first?.int ?? 0,
            lastRefresh: lastRefresh,
            lastError: lastError,
            lastErrorAt: lastErrorAt,
            cloudRootHash: state["cloud.root_hash"],
            cloudGeneration: state["cloud.generation"].flatMap(Int64.init)
        )
    }

    func stateValues() throws -> [String: String] {
        var values: [String: String] = [:]
        for row in try database.query("SELECT key, value FROM state") {
            values[row[0].string ?? ""] = row[1].string
        }
        return values
    }

    func setState(_ values: [String: String?]) throws {
        try database.transaction { t in
            for (key, value) in values {
                try t.query(
                    "INSERT INTO state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [.text(key), SQLValue(value)]
                )
            }
        }
    }
}

func documentsFolder(_ root: URL) -> URL {
    root.appending(path: "documents", directoryHint: .isDirectory)
}

func decodeJSON<T: Decodable>(_ text: String?) -> T? {
    guard let text else { return nil }
    return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
}

func encodeJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
}
