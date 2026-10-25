// The notebook writer from spike 4, kept for phase 3, which sends Markdown to the tablet.
// Phase 1 exposes no write path, so everything here is internal; tests use it to make fixtures.
//
// `textPageBlocks` generalizes rmscene's `simple_text_document` (scene_stream.py)
// (https://github.com/ricklupton/rmscene, v0.8.0) to styled paragraphs.
// rmscene is Copyright (c) 2023 Rick Lupton and is MIT licensed;
// see RMScene/LICENSE-rmscene.

import Foundation

/// One paragraph of typed text: a tablet paragraph style and its text.
struct StyledParagraph: Equatable, Sendable {
    var style: ParagraphStyle
    var text: String
    /// The Markdown heading level, 1 to 6, or 0 for other paragraphs.
    /// Page layout uses it; the tablet does not see it.
    var headingLevel: Int

    init(_ style: ParagraphStyle, _ text: String, headingLevel: Int = 0) {
        self.style = style
        self.text = text
        self.headingLevel = headingLevel
    }
}

/// Return the blocks of one page that holds `paragraphs` as typed text.
///
/// The blocks are those of rmscene's `simple_text_document`.
/// The text is one CRDT item, ID 1:16, with the paragraphs joined by newlines,
/// so character `i` has ID `1:(16 + i)`, counting Unicode scalars as Python counts code points.
/// The first paragraph's style is keyed by the end marker 0:0 with timestamp 1:15,
/// as in `simple_text_document`.
/// Each later paragraph's style is keyed by the newline that starts it,
/// with a timestamp after the last character's ID.
func textPageBlocks(_ paragraphs: [StyledParagraph], authorUUID: UUID) -> [any WritableBlock] {
    precondition(!paragraphs.isEmpty, "a text page needs a paragraph")
    let text = paragraphs.map(\.text).joined(separator: "\n")
    let length = UInt64(text.unicodeScalars.count)

    var styles: [CrdtId: LwwValue<ParagraphStyle>] = [
        CrdtId(0, 0): LwwValue(CrdtId(1, 15), paragraphs[0].style)
    ]
    var offset: UInt64 = 0
    for (k, paragraph) in paragraphs.enumerated() {
        if k > 0 {
            // `offset` is the index of the newline before this paragraph.
            styles[CrdtId(1, 16 + offset)] = LwwValue(CrdtId(1, 16 + length + UInt64(k - 1)), paragraph.style)
            offset += 1
        }
        offset += UInt64(paragraph.text.unicodeScalars.count)
    }

    let rootGroup = Group(nodeId: CrdtId(0, 1))
    let layer = Group(nodeId: CrdtId(0, 11))
    layer.label = LwwValue(CrdtId(0, 12), "Layer 1")
    return [
        AuthorIdsBlock([(1, authorUUID)]),
        MigrationInfoBlock(migrationId: CrdtId(1, 1), isDevice: true),
        PageInfoBlock(
            loadsCount: 1,
            mergesCount: 0,
            textCharsCount: UInt32(length + 1),
            textLinesCount: UInt32(paragraphs.count)
        ),
        SceneTreeBlock(tree: CrdtId(0, 11), node: CrdtId(0, 0), isUpdate: true, parent: CrdtId(0, 1)),
        RootTextBlock(
            Text(
                items: CrdtSequence([
                    CrdtSequenceItem(CrdtId(1, 16), CrdtId(0, 0), CrdtId(0, 0), 0, TextValue.string(text))
                ]),
                styles: styles,
                posX: -468.0,
                posY: 234.0,
                width: 936.0
            )
        ),
        TreeNodeBlock(rootGroup),
        TreeNodeBlock(layer),
        SceneItemBlock(
            kind: .group,
            parent: CrdtId(0, 1),
            item: CrdtSequenceItem(CrdtId(0, 13), CrdtId(0, 0), CrdtId(0, 0), 0, .groupId(CrdtId(0, 11)))
        ),
    ]
}

/// How to split paragraphs into pages.
enum PageLayout: String, Sendable {
    /// All paragraphs on one page, which the tablet may grow downward (unchecked).
    case single
    /// A new page at each `##` heading, unless the current page has only headings.
    case sections
}

/// Split paragraphs into pages.
func layOutPages(_ paragraphs: [StyledParagraph], _ layout: PageLayout) -> [[StyledParagraph]] {
    switch layout {
    case .single:
        return [paragraphs]
    case .sections:
        var pages: [[StyledParagraph]] = [[]]
        for paragraph in paragraphs {
            let pageHasBody = pages[pages.count - 1].contains { $0.headingLevel == 0 }
            if paragraph.headingLevel == 2, pageHasBody {
                pages.append([])
            }
            pages[pages.count - 1].append(paragraph)
        }
        return pages
    }
}

/// A new notebook with typed-text pages.
///
/// The archive layout and the `.content` and `.metadata` fields follow
/// a notebook exported by a reMarkable 2 (in remarquee's test data),
/// remarquee's notebook compiler, and rmapi-js's schema;
/// see RESULT.md for the sources.
struct Notebook: Sendable {
    var documentId: String
    var visibleName: String
    var authorUUID: UUID
    var createdMilliseconds: Int64
    var pageIds: [String]
    var pages: [[StyledParagraph]]

    /// Lowercase UUIDs, as the tablet writes them.
    static func newId() -> String { UUID().uuidString.lowercased() }

    init(
        visibleName: String,
        pages: [[StyledParagraph]],
        documentId: String = Notebook.newId(),
        pageIds: [String]? = nil,
        authorUUID: UUID = UUID(),
        created: Date = Date()
    ) {
        self.visibleName = visibleName
        self.pages = pages
        self.documentId = documentId
        self.pageIds = pageIds ?? pages.map { _ in Notebook.newId() }
        self.authorUUID = authorUUID
        self.createdMilliseconds = Int64((created.timeIntervalSince1970 * 1000).rounded(.down))
        precondition(self.pageIds.count == pages.count, "one page ID for each page")
    }

    /// The `.rm` bytes of each page.
    func pageFiles() throws -> [[UInt8]] {
        try pages.map { try writeBlocks(textPageBlocks($0, authorUUID: authorUUID)) }
    }

    /// The files of the archive, in the order of the tablet's own export:
    /// `.content`, `.metadata`, then each page.
    func files() throws -> [ArchiveFile] {
        var files = [
            ArchiveFile(name: "\(documentId).content", data: Data(try json(content()))),
            ArchiveFile(name: "\(documentId).metadata", data: Data(try json(metadata()))),
        ]
        for (pageId, bytes) in zip(pageIds, try pageFiles()) {
            files.append(ArchiveFile(name: "\(documentId)/\(pageId).rm", data: Data(bytes)))
        }
        return files
    }

    /// The rmdoc archive: a zip file with stored (uncompressed) entries.
    func rmdoc() throws -> Data {
        storedZip(try files(), modified: Date(timeIntervalSince1970: Double(createdMilliseconds) / 1000))
    }

    func content() -> Content {
        let ms = String(createdMilliseconds)
        return Content(
            cPages: CPages(
                lastOpened: Lww(timestamp: "1:1", value: pageIds[0]),
                original: Lww(timestamp: "0:0", value: -1),
                pages: pageIds.enumerated().map { i, id in
                    CPage(id: id, idx: Lww(timestamp: "1:2", value: pageIndex(i)), modifed: ms)
                },
                uuids: [AuthorUUID(first: authorUUID.uuidString.lowercased(), second: 1)]
            ),
            pageCount: pageIds.count
        )
    }

    func metadata() -> Metadata {
        let ms = String(createdMilliseconds)
        return Metadata(createdTime: ms, lastModified: ms, visibleName: visibleName)
    }
}

/// The `idx` of page `i`: "ba", "bb", ..., "bz", "ca", ...,
/// as remarquee writes them and as the tablet wrote them for two pages.
/// The pattern past "bb" is unchecked on the tablet.
func pageIndex(_ i: Int) -> String {
    let letters = Array("abcdefghijklmnopqrstuvwxyz")
    precondition(i >= 0 && i < 25 * 26, "page index out of range")
    return String([letters[1 + i / 26], letters[i % 26]])
}

struct Lww<T: Encodable & Sendable>: Encodable, Sendable {
    var timestamp: String
    var value: T
}

struct CPage: Encodable, Sendable {
    var id: String
    var idx: Lww<String>
    /// reMarkable's own spelling.
    var modifed: String
}

struct AuthorUUID: Encodable, Sendable {
    var first: String
    var second: Int
}

struct CPages: Encodable, Sendable {
    var lastOpened: Lww<String>
    var original: Lww<Int>
    var pages: [CPage]
    var uuids: [AuthorUUID]
}

struct Content: Encodable, Sendable {
    var cPages: CPages
    var coverPageNumber = -1
    var documentMetadata: [String: String] = [:]
    var extraMetadata: [String: String] = [:]
    var fileType = "notebook"
    var fontName = ""
    var formatVersion = 2
    var lineHeight = -1
    var orientation = "portrait"
    var pageCount: Int
    var pageTags: [String] = []
    var tags: [String] = []
    var textAlignment = "justify"
    var textScale = 1
    var zoomMode = "bestFit"
}

struct Metadata: Encodable, Sendable {
    var createdTime: String
    var lastModified: String
    var lastOpened = "0"
    var lastOpenedPage = 0
    var new = false
    var parent = ""
    var pinned = false
    var source = ""
    var type = "DocumentType"
    var visibleName: String
}

func json<T: Encodable>(_ value: T) throws -> [UInt8] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return Array(try encoder.encode(value))
}
