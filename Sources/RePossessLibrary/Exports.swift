import Foundation
import PDFKit
import RePossessFormat

/// The tablet's own PDF of a document, from `GET /download/<id>/pdf` over USB.
///
/// The tablet draws typed text with its own fonts, which rePossess cannot ship,
/// so the export shows a typed page as the tablet does.
/// rePossess rasterizes its pages and never extracts the fonts inside it.
/// Exports stay in the library folder, in `exports/<id>.pdf`; they are never sent anywhere.
public struct TabletExport: Sendable, Equatable {
    public var documentID: String
    /// The PDF file.
    public var url: URL
    /// The document's `lastModified` when the export was downloaded.
    public var modified: Date?
    public var pages: Int
    public var bytes: Int
    public var downloaded: Date
}

/// Whether a document's page images come from the tablet's export, and why not when they do not.
public enum ExportState: Sendable, Equatable {
    /// The export matches the mirror's copy of the document.
    case current(TabletExport)
    /// The document has no typed text, so rePossess's own rendering matches the tablet's.
    case notNeeded
    /// The document has typed text and no export yet.
    case missing
    /// The export is older than the mirror's copy, as after a cloud refresh brings a change.
    case stale(TabletExport)
    /// The export's pages do not match the document's.
    case pageCountDiffers(TabletExport, documentPages: Int)
}

/// An export that is not a PDF the library can read.
public struct ExportError: Error, CustomStringConvertible {
    public var description: String
}

extension Library {
    var exportsURL: URL { root.appending(path: "exports", directoryHint: .isDirectory) }

    func exportURL(_ id: String) -> URL { exportsURL.appending(path: "\(id).pdf") }

    /// The stored export of a document, current or not.
    public func export(for id: String) throws -> TabletExport? {
        guard isValidItemID(id) else { return nil }
        let rows = try database.query(
            "SELECT document_id, modified, pages, bytes, downloaded FROM exports WHERE document_id = ?",
            [.text(id)]
        )
        guard let row = rows.first, FileManager.default.fileExists(atPath: exportURL(id).path) else { return nil }
        return TabletExport(
            documentID: id,
            url: exportURL(id),
            modified: row[1].double.map(Date.init(timeIntervalSince1970:)),
            pages: row[2].int ?? 0,
            bytes: row[3].int ?? 0,
            downloaded: Date(timeIntervalSince1970: row[4].double ?? 0)
        )
    }

    /// Whether the page images of a document can come from the tablet's export.
    ///
    /// An export is current when it was downloaded for the document's `lastModified`
    /// and has one page for each of the document's pages.
    /// The tablet exports one PDF page for each page, in order,
    /// and a page longer than the screen as one taller PDF page
    /// (checked on 2026-10-25 on exports of typed test notebooks and of a handwritten notebook of 10 pages).
    public func exportState(for item: LibraryItem) throws -> ExportState {
        let typed =
            try database.query("SELECT typed_text FROM items WHERE id = ?", [.text(item.id)]).first?.first?.int == 1
        guard let export = try export(for: item.id) else { return typed ? .missing : .notNeeded }
        let sameVersion =
            switch (export.modified, item.modified) {
            case (let a?, let b?): abs(a.timeIntervalSince(b)) < 0.001
            case (nil, nil): true
            default: false
            }
        guard sameVersion else { return .stale(export) }
        guard export.pages == item.pageCount else { return .pageCountDiffers(export, documentPages: item.pageCount) }
        return .current(export)
    }

    /// The documents with typed text whose export is missing or older than the mirror's copy.
    func documentsNeedingExports(among ids: Set<String>) throws -> [String] {
        try database.query(
            """
            SELECT items.id FROM items LEFT JOIN exports ON exports.document_id = items.id
            WHERE items.kind = 'DocumentType' AND items.trashed = 0 AND items.error IS NULL AND items.typed_text = 1
              AND (exports.document_id IS NULL OR exports.modified IS NOT items.modified)
            ORDER BY items.id
            """
        ).compactMap { $0.first?.string }.filter { ids.contains($0) }
    }

    /// Forgets a document's export, because the tablet sent a new copy of the document.
    /// A new copy can keep its `lastModified`, so the key alone would not show the change.
    func forgetExport(id: String) throws {
        try database.query("DELETE FROM exports WHERE document_id = ?", [.text(id)])
        try? FileManager.default.removeItem(at: exportURL(id))
    }

    /// Stores an export, keyed by the document's `lastModified` as the index holds it.
    func storeExport(id: String, data: Data) throws {
        guard data.starts(with: Data("%PDF-".utf8)), let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
            throw ExportError(description: "the tablet's PDF of \(id) could not be read")
        }
        try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        try data.write(to: exportURL(id), options: .atomic)
        try database.query(
            """
            INSERT INTO exports (document_id, modified, pages, bytes, downloaded)
            SELECT id, modified, ?, ?, ? FROM items WHERE id = ?
            ON CONFLICT(document_id) DO UPDATE SET
              modified = excluded.modified, pages = excluded.pages, bytes = excluded.bytes,
              downloaded = excluded.downloaded
            """,
            [SQLValue(pdf.pageCount), SQLValue(data.count), SQLValue(Date()), .text(id)]
        )
    }
}
