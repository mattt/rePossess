import Foundation

/// The kinds of item in the tablet's library.
public enum ItemKind: String, Sendable, Codable {
    /// A notebook, PDF, or EPUB.
    case document = "DocumentType"
    /// A folder.
    case folder = "CollectionType"
}

/// The fields of a `<id>.metadata` file that rePossess uses.
///
/// The keys are those of the tablet's own files.
/// Unknown keys are ignored, and every field has a fallback,
/// so that a new key or a missing one does not fail the document.
public struct DocumentMetadata: Sendable, Equatable {
    /// The name that the tablet shows.
    public var visibleName: String
    /// A document or a folder; anything else reads as a document.
    public var kind: ItemKind
    /// The parent folder's ID: empty for the top level, or `trash`.
    public var parent: String
    /// The last change, from `lastModified` in milliseconds since 1970.
    public var lastModified: Date?
    /// Whether the tablet marks the item as deleted.
    public var deleted: Bool

    public init(
        visibleName: String,
        kind: ItemKind = .document,
        parent: String = "",
        lastModified: Date? = nil,
        deleted: Bool = false
    ) {
        self.visibleName = visibleName
        self.kind = kind
        self.parent = parent
        self.lastModified = lastModified
        self.deleted = deleted
    }

    /// Parses a `.metadata` file.
    public init(parsing data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DocumentError.malformed(".metadata is not a JSON object")
        }
        visibleName = object["visibleName"] as? String ?? ""
        kind = (object["type"] as? String).flatMap(ItemKind.init(rawValue:)) ?? .document
        parent = object["parent"] as? String ?? ""
        lastModified = milliseconds(object["lastModified"])
        deleted = object["deleted"] as? Bool ?? false
    }

    /// Whether the item is in the trash.
    public var isTrashed: Bool { parent == "trash" || deleted }
}

/// Reads a time in milliseconds since 1970, written as a string or a number.
func milliseconds(_ value: Any?) -> Date? {
    let ms: Double? =
        switch value {
        case let s as String: Double(s)
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    guard let ms, ms > 0 else { return nil }
    return Date(timeIntervalSince1970: ms / 1000)
}

/// One page of a document, in the order that the tablet shows.
public struct PageReference: Sendable, Equatable {
    /// The page ID, which names `<document-id>/<page-id>.rm`.
    public var id: String
    /// The page number, from 1.
    public var number: Int
    /// The page of the document's PDF or EPUB that this page shows, from 0,
    /// or `nil` for a page that the tablet added.
    public var sourcePageIndex: Int?
    /// The template name, such as `Blank`, when the content file gives one.
    public var template: String?

    public init(id: String, number: Int, sourcePageIndex: Int? = nil, template: String? = nil) {
        self.id = id
        self.number = number
        self.sourcePageIndex = sourcePageIndex
        self.template = template
    }
}

/// The fields of a `<id>.content` file that rePossess uses.
public struct DocumentContent: Sendable, Equatable {
    /// `notebook`, `pdf`, or `epub`.
    public var fileType: String
    /// The pages, in display order, without deleted pages.
    public var pages: [PageReference]
    /// The document's tags.
    public var tags: [String]
    /// Tags on single pages, by page ID.
    public var pageTags: [String: [String]]

    public init(fileType: String, pages: [PageReference], tags: [String] = [], pageTags: [String: [String]] = [:]) {
        self.fileType = fileType
        self.pages = pages
        self.tags = tags
        self.pageTags = pageTags
    }

    /// Parses a `.content` file.
    ///
    /// Pages come from `cPages.pages` (format version 2), sorted by `idx` and without
    /// pages whose `deleted` value is set, or from the older `pages` list (format version 1),
    /// with `redirectionPageMap` for the PDF page that each page shows.
    public init(parsing data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DocumentError.malformed(".content is not a JSON object")
        }
        fileType = object["fileType"] as? String ?? "notebook"

        var pages: [PageReference] = []
        if let cPages = object["cPages"] as? [String: Any], let list = cPages["pages"] as? [[String: Any]] {
            let live = list.filter { page in
                guard let deleted = page["deleted"] as? [String: Any] else { return true }
                return ((deleted["value"] as? NSNumber)?.intValue ?? 0) == 0
            }
            let sorted = live.enumerated().sorted { a, b in
                let ia = lwwString(a.element["idx"]) ?? ""
                let ib = lwwString(b.element["idx"]) ?? ""
                return ia == ib ? a.offset < b.offset : ia < ib
            }
            for (_, page) in sorted {
                guard let id = page["id"] as? String else { continue }
                let redirect = ((page["redir"] as? [String: Any])?["value"] as? NSNumber)?.intValue
                pages.append(
                    PageReference(
                        id: id,
                        number: pages.count + 1,
                        sourcePageIndex: redirect.flatMap { $0 >= 0 ? $0 : nil },
                        template: lwwString(page["template"])
                    )
                )
            }
        } else if let list = object["pages"] as? [String] {
            let map = (object["redirectionPageMap"] as? [NSNumber])?.map(\.intValue)
            for (i, id) in list.enumerated() {
                var source: Int? = fileType == "notebook" ? nil : i
                if let map, i < map.count { source = map[i] >= 0 ? map[i] : nil }
                pages.append(PageReference(id: id, number: i + 1, sourcePageIndex: source))
            }
        }
        self.pages = pages

        tags = (object["tags"] as? [Any] ?? []).compactMap(tagName)
        var pageTags: [String: [String]] = [:]
        for case let tag as [String: Any] in object["pageTags"] as? [Any] ?? [] {
            if let pageId = tag["pageId"] as? String, let name = tagName(tag) {
                pageTags[pageId, default: []].append(name)
            }
        }
        self.pageTags = pageTags
    }
}

/// A tag is a string in old files and `{"name": ..., "timestamp": ...}` in new ones.
private func tagName(_ value: Any) -> String? {
    if let s = value as? String { return s }
    return (value as? [String: Any])?["name"] as? String
}

/// Reads the value of a last-write-wins field, `{"timestamp": ..., "value": ...}`.
private func lwwString(_ value: Any?) -> String? {
    (value as? [String: Any])?["value"] as? String
}

/// An error in a document's files.
public enum DocumentError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case missing(String)
    case invalidID(String)

    public var description: String {
        switch self {
        case .malformed(let what): what
        case .missing(let file): "the document has no \(file)"
        case .invalidID(let id): "not a document ID: \(id)"
        }
    }
}

/// Document and page IDs on the tablet are lowercase UUIDs.
/// rePossess accepts letters, digits, and hyphens, so that an ID can name a file safely.
public func isValidItemID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64
        && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
}

/// The files of one document in a folder,
/// laid out as in an rmdoc archive: `<id>.content`, `<id>.metadata`,
/// `<id>.pdf` or `<id>.epub`, and `<id>/<page-id>.rm`.
public struct DocumentFolder: Sendable {
    /// The document ID.
    public var id: String
    /// The folder that holds the files.
    public var url: URL

    public init(id: String, url: URL) throws {
        guard isValidItemID(id) else { throw DocumentError.invalidID(id) }
        self.id = id
        self.url = url
    }

    /// The URL of a file, named as in the archive.
    public func file(_ name: String) -> URL { url.appending(path: name) }

    public var metadataURL: URL { file("\(id).metadata") }
    public var contentURL: URL { file("\(id).content") }
    public var pdfURL: URL { file("\(id).pdf") }

    /// The URL of a page's `.rm` file, which exists only for pages with marks or text.
    public func pageURL(_ pageId: String) -> URL { file("\(id)/\(pageId).rm") }

    public func metadata() throws -> DocumentMetadata {
        try DocumentMetadata(parsing: Data(contentsOf: metadataURL))
    }

    /// The content file, or `nil` when the document has none, as a folder does not.
    public func content() throws -> DocumentContent? {
        guard FileManager.default.fileExists(atPath: contentURL.path) else { return nil }
        return try DocumentContent(parsing: Data(contentsOf: contentURL))
    }

    /// The bytes of a page, or `nil` when the page has no `.rm` file.
    public func pageBytes(_ pageId: String) throws -> [UInt8]? {
        guard isValidItemID(pageId) else { throw DocumentError.invalidID(pageId) }
        let url = pageURL(pageId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return [UInt8](try Data(contentsOf: url))
    }

    /// Whether the document has a PDF.
    public var hasPDF: Bool { FileManager.default.fileExists(atPath: pdfURL.path) }

    /// The bytes of an image on a page, in `<id>/<page-id>/<file>`, or `nil` when the file is missing
    /// or its name is not a plain file name, as the page names it in block type 14.
    public func imageData(page pageId: String, file name: String) -> Data? {
        guard isValidItemID(pageId), !name.isEmpty, name.count <= 128, !name.hasPrefix("."),
            name.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
            })
        else { return nil }
        return try? Data(contentsOf: file("\(id)/\(pageId)/\(name)"))
    }
}
