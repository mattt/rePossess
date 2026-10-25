import Foundation
import RePossessFormat

/// What a recognition is cached under, apart from the page's strokes:
/// the provider, the model, and the version of the prompt and the strip rules.
public struct RecognitionKey: Sendable, Hashable, Codable {
    /// The provider's name, such as `mlx` or `anthropic`.
    public var provider: String
    /// The model's identifier, with its revision when the provider pins one.
    public var model: String
    /// The version of the prompt, the strip cutting, and the image scale.
    public var promptVersion: String

    public init(provider: String, model: String, promptVersion: String) {
        self.provider = provider
        self.model = model
        self.promptVersion = promptVersion
    }
}

/// The result of recognizing one page's handwriting.
public struct Recognition: Sendable, Equatable {
    public enum Status: String, Sendable, Codable {
        /// The recognizer returned text.
        case text
        /// The recognizer returned no words, as for a drawing without labels.
        case empty
        /// The recognizer declined to read the page, with an error or with a refusal written as text.
        /// The page stays unread; no text from it is shown or indexed.
        case refused
    }

    public var key: RecognitionKey
    public var strokeHash: String
    public var status: Status
    /// The page's text, strip by strip, joined with newlines; empty unless `status` is `text`.
    public var text: String
    /// Who made the text, as tool results name it, such as "Qwen3-VL 8B 4-bit through MLX on this Mac".
    public var label: String
    public var strips: Int
    public var seconds: Double
    public var created: Date

    public init(
        key: RecognitionKey,
        strokeHash: String,
        status: Status,
        text: String,
        label: String,
        strips: Int,
        seconds: Double,
        created: Date = Date()
    ) {
        self.key = key
        self.strokeHash = strokeHash
        self.status = status
        self.text = status == .text ? text : ""
        self.label = label
        self.strips = strips
        self.seconds = seconds
        self.created = created
    }
}

/// A page with strokes, and whether the active recognizer has read it.
public struct InkPage: Sendable, Equatable {
    public var documentID: String
    public var number: Int
    public var strokeHash: String
}

/// The number of pages with strokes, and how many of them each outcome covers, for one key.
public struct RecognitionCounts: Sendable, Equatable {
    public var pagesWithInk = 0
    public var text = 0
    public var empty = 0
    public var refused = 0

    public var waiting: Int { pagesWithInk - text - empty - refused }
}

extension Library {
    /// Phase 4: each page's stroke hash, the cache of recognized handwriting,
    /// and a `kind` column in the search table, which tells typed text from handwriting.
    ///
    /// FTS5 cannot add a column, so the search table is made again from the stored pages.
    /// The stroke hashes of stored pages come from their page files.
    func migrateToVersion3() throws {
        try database.execute(
            """
            BEGIN;
            ALTER TABLE pages ADD COLUMN stroke_hash TEXT;
            CREATE TABLE IF NOT EXISTS recognitions (
                stroke_hash TEXT NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                prompt_version TEXT NOT NULL,
                status TEXT NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                label TEXT NOT NULL,
                strips INTEGER NOT NULL,
                seconds REAL NOT NULL,
                created REAL NOT NULL,
                PRIMARY KEY (stroke_hash, provider, model, prompt_version)
            );
            DROP TABLE IF EXISTS page_text;
            CREATE VIRTUAL TABLE page_text USING fts5(
                document_id UNINDEXED, number UNINDEXED, kind UNINDEXED, body,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            INSERT INTO page_text (document_id, number, kind, body)
              SELECT document_id, number, 'text', markdown FROM pages WHERE has_text = 1;
            PRAGMA user_version = 3;
            COMMIT;
            """
        )
        let rows = try database.query(
            "SELECT document_id, number, page_id FROM pages WHERE stroke_count > 0 AND stroke_hash IS NULL"
        )
        for row in rows {
            guard let id = row[0].string, let number = row[1].int, let pageID = row[2].string,
                let folder = try? folder(for: id), let bytes = try? folder.pageBytes(pageID),
                let hash = pageContent(bytes).strokeHash
            else { continue }
            try database.query(
                "UPDATE pages SET stroke_hash = ? WHERE document_id = ? AND number = ?",
                [.text(hash), .text(id), SQLValue(number)]
            )
        }
    }

    // MARK: The active recognizer

    private static let activeKeyState = "recognizer.active_key"

    /// The key whose recognitions `fetch_document` shows and search indexes, or `nil` when recognition is off.
    public func activeRecognitionKey() throws -> RecognitionKey? {
        decodeJSON(try stateValues()[Self.activeKeyState])
    }

    /// Makes `key` the active recognizer's key, and indexes its recognitions in place of the earlier key's.
    /// `nil` turns recognition off: no handwriting is shown or indexed, and the cache stays.
    public func setActiveRecognitionKey(_ key: RecognitionKey?) throws {
        guard try activeRecognitionKey() != key else { return }
        try database.transaction { t in
            try t.query(
                "INSERT INTO state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(Self.activeKeyState), SQLValue(key.map(encodeJSON))]
            )
            try t.query("DELETE FROM page_text WHERE kind = 'handwriting'")
            try Self.indexHandwriting(t, documentID: nil)
        }
    }

    /// Adds search rows for the handwriting that the active key has read,
    /// for one document or for every document.
    static func indexHandwriting(_ t: Database.Transaction, documentID: String?) throws {
        let value = try t.query("SELECT value FROM state WHERE key = ?", [.text(activeKeyState)]).first?.first
        guard let key: RecognitionKey = decodeJSON(value?.string) else { return }
        var sql = """
            INSERT INTO page_text (document_id, number, kind, body)
            SELECT p.document_id, p.number, 'handwriting', r.text
            FROM pages p JOIN recognitions r ON r.stroke_hash = p.stroke_hash
            WHERE r.provider = ? AND r.model = ? AND r.prompt_version = ? AND r.status = 'text'
            """
        var parameters: [SQLValue] = [.text(key.provider), .text(key.model), .text(key.promptVersion)]
        if let documentID {
            sql += " AND p.document_id = ?"
            parameters.append(.text(documentID))
        }
        try t.query(sql, parameters)
    }

    // MARK: The cache

    /// The cached recognition of a page's strokes under a key, if any.
    public func recognition(strokeHash: String, key: RecognitionKey) throws -> Recognition? {
        try database.query(
            """
            SELECT status, text, label, strips, seconds, created FROM recognitions
            WHERE stroke_hash = ? AND provider = ? AND model = ? AND prompt_version = ?
            """,
            [.text(strokeHash), .text(key.provider), .text(key.model), .text(key.promptVersion)]
        ).first.map { row in
            Recognition(
                key: key,
                strokeHash: strokeHash,
                status: Recognition.Status(rawValue: row[0].string ?? "") ?? .refused,
                text: row[1].string ?? "",
                label: row[2].string ?? "",
                strips: row[3].int ?? 0,
                seconds: row[4].double ?? 0,
                created: Date(timeIntervalSince1970: row[5].double ?? 0)
            )
        }
    }

    /// Stores a recognition, replacing an earlier one for the same strokes and key,
    /// and indexes its text for every page with those strokes when its key is active.
    public func storeRecognition(_ recognition: Recognition) throws {
        let key = recognition.key
        try database.transaction { t in
            try t.query(
                """
                INSERT INTO recognitions (stroke_hash, provider, model, prompt_version, status, text, label, strips,
                                          seconds, created)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(stroke_hash, provider, model, prompt_version) DO UPDATE SET
                  status = excluded.status, text = excluded.text, label = excluded.label, strips = excluded.strips,
                  seconds = excluded.seconds, created = excluded.created
                """,
                [
                    .text(recognition.strokeHash), .text(key.provider), .text(key.model), .text(key.promptVersion),
                    .text(recognition.status.rawValue), .text(recognition.text), .text(recognition.label),
                    SQLValue(recognition.strips), .real(recognition.seconds), SQLValue(recognition.created),
                ]
            )
            let active = try t.query("SELECT value FROM state WHERE key = ?", [.text(Self.activeKeyState)])
            guard let activeKey: RecognitionKey = decodeJSON(active.first?.first?.string), activeKey == key else {
                return
            }
            let pages = try t.query(
                "SELECT document_id, number FROM pages WHERE stroke_hash = ?",
                [.text(recognition.strokeHash)]
            )
            for page in pages {
                try t.query(
                    "DELETE FROM page_text WHERE document_id = ? AND number = ? AND kind = 'handwriting'",
                    [page[0], page[1]]
                )
                if recognition.status == .text {
                    try t.query(
                        "INSERT INTO page_text (document_id, number, kind, body) VALUES (?, ?, 'handwriting', ?)",
                        [page[0], page[1], .text(recognition.text)]
                    )
                }
            }
        }
    }

    /// The pages with strokes, in one document or in all documents that are not in the trash,
    /// in path and page order.
    public func inkPages(documentID: String? = nil) throws -> [InkPage] {
        var sql = """
            SELECT p.document_id, p.number, p.stroke_hash FROM pages p JOIN items i ON i.id = p.document_id
            WHERE p.stroke_hash IS NOT NULL AND i.trashed = 0
            """
        var parameters: [SQLValue] = []
        if let documentID {
            sql += " AND p.document_id = ?"
            parameters.append(.text(documentID))
        }
        let rows = try database.query(sql + " ORDER BY p.document_id, p.number", parameters)
        var pages = rows.map {
            InkPage(documentID: $0[0].string ?? "", number: $0[1].int ?? 0, strokeHash: $0[2].string ?? "")
        }
        if documentID == nil {
            let order = Dictionary(
                try documents().enumerated().map { ($1.id, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            pages.sort {
                (order[$0.documentID] ?? .max, $0.number) < (order[$1.documentID] ?? .max, $1.number)
            }
        }
        return pages
    }

    /// How many pages with strokes the key has read, by outcome.
    public func recognitionCounts(key: RecognitionKey) throws -> RecognitionCounts {
        var counts = RecognitionCounts()
        let rows = try database.query(
            """
            SELECT r.status, count(*) FROM pages p JOIN items i ON i.id = p.document_id
            LEFT JOIN recognitions r ON r.stroke_hash = p.stroke_hash
              AND r.provider = ? AND r.model = ? AND r.prompt_version = ?
            WHERE p.stroke_hash IS NOT NULL AND i.trashed = 0
            GROUP BY r.status
            """,
            [.text(key.provider), .text(key.model), .text(key.promptVersion)]
        )
        for row in rows {
            let n = row[1].int ?? 0
            counts.pagesWithInk += n
            switch Recognition.Status(rawValue: row[0].string ?? "") {
            case .text: counts.text += n
            case .empty: counts.empty += n
            case .refused: counts.refused += n
            case nil: break
            }
        }
        return counts
    }
}
