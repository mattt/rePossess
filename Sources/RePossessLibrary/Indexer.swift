import Foundation
import PDFKit
import RePossessFormat
import RePossessRender

/// A document's index records, read from its files.
struct IndexedDocument {
    var metadata: DocumentMetadata
    var fileType: String
    var tags: [String]
    var pages: [LibraryPage]
    var pageTags: [Int: [String]]
    /// Whether any page has typed text, which rePossess draws with substitute fonts.
    var typedText = false

    /// `annotated` when a PDF or EPUB page has ink;
    /// otherwise `text` when no page needs an image without having text,
    /// `partial` when some pages have text, `ink` when a notebook page has ink, and `image` otherwise.
    var contentStatus: ContentStatus {
        if pages.contains(where: { $0.sourcePageIndex != nil && $0.strokeCount > 0 }) { return .annotated }
        guard pages.contains(where: { $0.needsImage && !$0.hasText }) else { return .text }
        if pages.contains(where: \.hasText) { return .partial }
        return pages.contains(where: { $0.sourcePageIndex == nil && $0.strokeCount > 0 }) ? .ink : .image
    }

    /// The first 160 characters of the first page with text, on one line.
    var summary: String {
        guard let page = pages.first(where: \.hasText) else { return "" }
        let words = searchBody(page).split(whereSeparator: \.isWhitespace).map { word in
            word.trimmingCharacters(in: CharacterSet(charactersIn: "#*-[]>|"))
        }
        let text = words.filter { !$0.isEmpty }.joined(separator: " ")
        return text.count > 160 ? String(text.prefix(159)) + "…" : text
    }
}

/// Reads a document's metadata, content, pages, and PDF text.
///
/// A page that cannot be read gets its warnings and no text; the document still indexes.
func indexDocument(_ folder: DocumentFolder) throws -> IndexedDocument {
    let metadata = try folder.metadata()
    var content = try folder.content() ?? DocumentContent(fileType: "notebook", pages: [])
    let pdf = folder.hasPDF ? PDFDocument(url: folder.pdfURL) : nil
    if content.pages.isEmpty, let pdf {
        // A PDF with no page list: one page for each PDF page.
        content.pages = (0 ..< pdf.pageCount).map {
            PageReference(id: "pdf-page-\($0 + 1)", number: $0 + 1, sourcePageIndex: $0)
        }
    }

    var pages: [LibraryPage] = []
    var pageTags: [Int: [String]] = [:]
    var typedText = false
    for reference in content.pages {
        var warnings: [String] = []
        var page = PageContent()
        var imagePositions: [Int] = []
        do {
            if let bytes = try folder.pageBytes(reference.id) {
                page = pageContent(bytes)
                warnings += page.warnings
                if !page.images.isEmpty {
                    // Where each image falls among the paragraphs, from rePossess's layout of the text.
                    imagePositions = PageScene(pageBytes: bytes).imageReadingPositions
                }
            }
        } catch {
            warnings.append("The page file could not be read: \(error)")
        }

        var pdfText = ""
        var isPDFPage = false
        if let index = reference.sourcePageIndex, let pdf {
            if let pdfPage = pdf.page(at: index) {
                isPDFPage = true
                pdfText = (pdfPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                warnings.append("The PDF has no page \(index + 1)")
            }
        }

        typedText = typedText || page.hasText
        var parts: [String] = []
        if !pdfText.isEmpty { parts.append(pdfText) }
        let placeholder = imagePlaceholder(page: reference.number)
        if page.hasText || !imagePositions.isEmpty {
            parts.append(page.markdown(inserting: imagePositions.map { ($0, placeholder) }))
        }
        if !page.highlights.isEmpty {
            parts.append("Highlighted on this page:\n" + page.highlights.map { "- \($0)" }.joined(separator: "\n"))
        }
        let markdown = parts.joined(separator: "\n\n")
        let hasText = !pdfText.isEmpty || page.hasText || !page.highlights.isEmpty
        pages.append(
            LibraryPage(
                documentID: folder.id,
                number: reference.number,
                pageID: reference.id,
                sourcePageIndex: reference.sourcePageIndex,
                markdown: markdown,
                hasText: hasText,
                needsImage: page.hasInk || (isPDFPage && pdfText.isEmpty) || (!imagePositions.isEmpty && !hasText),
                strokeCount: page.strokeCount,
                warnings: warnings,
                strokeHash: page.strokeHash
            )
        )
        if let tags = content.pageTags[reference.id] { pageTags[reference.number] = tags }
    }
    return IndexedDocument(
        metadata: metadata,
        fileType: content.fileType,
        tags: content.tags,
        pages: pages,
        pageTags: pageTags,
        typedText: typedText
    )
}

/// The line that stands for an image in a page's Markdown, in reading order.
/// The image itself, such as a table that reMarkdown drew, is only in the page image.
func imagePlaceholder(page: Int) -> String {
    "[Image: see fetch_page_image for page \(page).]"
}

/// The search text of a page: its Markdown without the Markdown markers and the image placeholders,
/// so that search snippets show the words alone. `fetch_document` keeps the Markdown.
func searchBody(_ page: LibraryPage) -> String {
    searchBody(markdown: page.markdown, page: page.number)
}

func searchBody(markdown: String, page: Int) -> String {
    let placeholder = imagePlaceholder(page: page)
    var lines: [String] = []
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        var text = Substring(line)
        if text == Substring(placeholder) { continue }
        // Leading spaces, then heading, list, and task markers.
        text = text.drop { $0 == " " }
        if let hashes = text.firstIndex(where: { $0 != "#" }), hashes != text.startIndex,
            text[hashes] == " "
        {
            text = text[text.index(after: hashes)...]
        }
        for marker in ["- [ ] ", "- [x] ", "- "] where text.hasPrefix(marker) {
            text = text.dropFirst(marker.count)
            break
        }
        // Emphasis markers: runs of asterisks.
        let plain = String(text).replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        if !plain.isEmpty { lines.append(plain) }
    }
    // One line for each paragraph or item, without blank lines, so that a snippet has single spaces.
    return lines.joined(separator: "\n")
}

extension Library {
    /// Writes a document's records, replacing any earlier ones.
    ///
    /// A `nil` version key keeps the stored one, so that each source's key survives
    /// a refresh from the other source.
    /// The key then still names a version that is no newer than the mirror's copy,
    /// so the next refresh from that source skips the document until the source changes it.
    func store(
        _ document: IndexedDocument,
        id: String,
        source: Source,
        usbModified: String?,
        cloudHash: String?
    ) throws {
        try database.transaction { t in
            try t.query(
                """
                INSERT INTO items (id, kind, name, parent, file_type, modified, page_count, content_status, summary,
                                   tags, source, usb_modified, cloud_hash, trashed, refreshed, error, typed_text)
                VALUES (?, 'DocumentType', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
                ON CONFLICT(id) DO UPDATE SET
                  kind = excluded.kind, name = excluded.name, parent = excluded.parent,
                  file_type = excluded.file_type, modified = excluded.modified, page_count = excluded.page_count,
                  content_status = excluded.content_status, summary = excluded.summary, tags = excluded.tags,
                  typed_text = excluded.typed_text,
                  source = excluded.source, usb_modified = coalesce(excluded.usb_modified, items.usb_modified),
                  cloud_hash = coalesce(excluded.cloud_hash, items.cloud_hash),
                  trashed = excluded.trashed, refreshed = excluded.refreshed, error = NULL
                """,
                [
                    .text(id), .text(document.metadata.visibleName), .text(document.metadata.parent),
                    .text(document.fileType), SQLValue(document.metadata.lastModified),
                    SQLValue(document.pages.count), .text(document.contentStatus.rawValue),
                    .text(document.summary), .text(encodeJSON(document.tags)), .text(source.rawValue),
                    SQLValue(usbModified), SQLValue(cloudHash), SQLValue(document.metadata.isTrashed),
                    SQLValue(Date()), SQLValue(document.typedText),
                ]
            )
            try t.query("DELETE FROM pages WHERE document_id = ?", [.text(id)])
            try t.query("DELETE FROM page_text WHERE document_id = ?", [.text(id)])
            for page in document.pages {
                try t.query(
                    """
                    INSERT INTO pages (document_id, number, page_id, source_page, markdown, has_text, needs_image,
                                       stroke_count, tags, warnings, stroke_hash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(id), SQLValue(page.number), .text(page.pageID), SQLValue(page.sourcePageIndex),
                        .text(page.markdown), SQLValue(page.hasText), SQLValue(page.needsImage),
                        SQLValue(page.strokeCount), .text(encodeJSON(document.pageTags[page.number] ?? [])),
                        .text(encodeJSON(page.warnings)), SQLValue(page.strokeHash),
                    ]
                )
                if page.hasText {
                    try t.query(
                        "INSERT INTO page_text (document_id, number, kind, body) VALUES (?, ?, 'text', ?)",
                        [.text(id), SQLValue(page.number), .text(searchBody(page))]
                    )
                }
            }
            // Handwriting that the active recognizer already read, such as on a page whose strokes did not change.
            try Self.indexHandwriting(t, documentID: id)
        }
    }

    /// Writes a folder's record, or a trashed item's, which the tools do not show.
    /// A `nil` version key keeps the stored one, as in ``store(_:id:source:usbModified:cloudHash:)``.
    func storeItem(
        id: String,
        kind: ItemKind,
        name: String,
        parent: String,
        trashed: Bool,
        source: Source,
        usbModified: String?,
        cloudHash: String?,
        error: String? = nil
    ) throws {
        try database.transaction { t in
            try t.query(
                """
                INSERT INTO items (id, kind, name, parent, source, usb_modified, cloud_hash, trashed, refreshed, error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  kind = excluded.kind, name = excluded.name, parent = excluded.parent, source = excluded.source,
                  usb_modified = coalesce(excluded.usb_modified, items.usb_modified),
                  cloud_hash = coalesce(excluded.cloud_hash, items.cloud_hash),
                  trashed = excluded.trashed, refreshed = excluded.refreshed, error = excluded.error
                """,
                [
                    .text(id), .text(kind.rawValue), .text(name), .text(parent), .text(source.rawValue),
                    SQLValue(usbModified), SQLValue(cloudHash), SQLValue(trashed), SQLValue(Date()),
                    SQLValue(error),
                ]
            )
            if trashed || kind == .folder {
                try t.query("DELETE FROM pages WHERE document_id = ?", [.text(id)])
                try t.query("DELETE FROM page_text WHERE document_id = ?", [.text(id)])
            }
        }
    }

    /// Removes items and their files.
    func remove(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try database.transaction { t in
            for id in ids {
                try t.query("DELETE FROM pages WHERE document_id = ?", [.text(id)])
                try t.query("DELETE FROM page_text WHERE document_id = ?", [.text(id)])
                try t.query("DELETE FROM items WHERE id = ?", [.text(id)])
                try t.query("DELETE FROM exports WHERE document_id = ?", [.text(id)])
            }
        }
        for id in ids where isValidItemID(id) {
            try? FileManager.default.removeItem(at: documentsURL.appending(path: id))
            try? FileManager.default.removeItem(at: exportURL(id))
        }
    }

    /// Records that a document could not be read.
    /// A new item gets a row with the error; a stored item keeps its name, files, and pages,
    /// and gains the error, so that the next refresh tries it again.
    func markFailed(id: String, name: String, parent: String, source: Source, error: String) throws {
        _ = try database.query(
            """
            INSERT INTO items (id, kind, name, parent, source, trashed, refreshed, error)
            VALUES (?, 'DocumentType', ?, ?, ?, 0, ?, ?)
            ON CONFLICT(id) DO UPDATE SET refreshed = excluded.refreshed, error = excluded.error
            """,
            [.text(id), .text(name), .text(parent), .text(source.rawValue), SQLValue(Date()), .text(error)]
        )
    }

    /// Records the cloud's version key for a document whose copy in the mirror is newer.
    func setCloudHash(_ hash: String, id: String) throws {
        _ = try database.query("UPDATE items SET cloud_hash = ? WHERE id = ?", [.text(hash), .text(id)])
    }

    /// The stored version keys of every item.
    func versions() throws -> [String: StoredVersion] {
        var result: [String: StoredVersion] = [:]
        for row in try database.query("SELECT id, usb_modified, cloud_hash, error, kind, source, trashed FROM items") {
            result[row[0].string ?? ""] = StoredVersion(
                usbModified: row[1].string,
                cloudHash: row[2].string,
                error: row[3].string,
                kind: ItemKind(rawValue: row[4].string ?? "") ?? .document,
                source: Source(rawValue: row[5].string ?? "") ?? .usb,
                trashed: row[6].int == 1
            )
        }
        return result
    }
}

/// An item's version keys and state, as the library stored them.
struct StoredVersion {
    /// The `ModifiedClient` from the last USB refresh that wrote the item.
    var usbModified: String?
    /// The index hash from the last cloud refresh that wrote or checked the item.
    var cloudHash: String?
    var error: String?
    var kind: ItemKind
    /// The source that last wrote the item's files.
    var source: Source
    var trashed: Bool

    /// Whether the item is a document that the tools show.
    var isVisibleDocument: Bool { kind == .document && !trashed }
}

extension Library {
    /// Indexes a document folder that is already in the mirror, without a transport.
    /// The `render` and `layout` commands use it to check a downloaded rmdoc file.
    public func importForChecking(_ folder: DocumentFolder) throws {
        try store(indexDocument(folder), id: folder.id, source: .usb, usbModified: nil, cloudHash: nil)
    }
}
