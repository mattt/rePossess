import Foundation

/// Builds invented version 6 pages for tests:
/// typed paragraphs, strokes in the first layer or in a group anchored to a character,
/// and highlights.
///
/// It follows the block layout of rmscene's `simple_text_document`
/// and of the tablet's pages that spikes 3 and 4 read.
/// It is internal; tests reach it with `@testable import`.
struct PageBuilder {
    /// A group of strokes, optionally anchored to a character of the text.
    struct StrokeGroup {
        var lines: [Line]
        /// The character ID that the group follows, and the group's x origin.
        var anchor: (id: CrdtId, originX: Float)?
    }

    var paragraphs: [StyledParagraph] = []
    var groups: [StrokeGroup] = []
    var highlights: [GlyphRange] = []
    var paperSize: (UInt32, UInt32)?
    var authorUUID = UUID(uuidString: "00000000-0000-4000-8000-0000000000b0")!

    /// The ID of character `i` of the joined text, as ``textPageBlocks(_:authorUUID:)`` writes it.
    static func characterID(_ i: Int) -> CrdtId { CrdtId(1, UInt64(16 + i)) }

    /// A stroke through `points`, with a pressure and width that draw a visible line.
    static func stroke(_ points: [(Double, Double)], tool: Pen = .ballpoint2, color: PenColor = .black) -> Line {
        Line(
            color: color,
            tool: tool,
            points: points.map { Point(x: $0.0, y: $0.1, speed: 0, direction: 0, width: 8, pressure: 100) },
            thicknessScale: 2
        )
    }

    func blocks() -> [any WritableBlock] {
        var blocks: [any WritableBlock]
        if paragraphs.isEmpty {
            let rootGroup = Group(nodeId: CrdtId(0, 1))
            let layer = Group(nodeId: CrdtId(0, 11))
            layer.label = LwwValue(CrdtId(0, 12), "Layer 1")
            blocks = [
                AuthorIdsBlock([(1, authorUUID)]),
                MigrationInfoBlock(migrationId: CrdtId(1, 1), isDevice: true),
                PageInfoBlock(loadsCount: 1, mergesCount: 0, textCharsCount: 0, textLinesCount: 0),
                SceneTreeBlock(tree: CrdtId(0, 11), node: CrdtId(0, 0), isUpdate: true, parent: CrdtId(0, 1)),
                TreeNodeBlock(rootGroup),
                TreeNodeBlock(layer),
                SceneItemBlock(
                    kind: .group,
                    parent: CrdtId(0, 1),
                    item: CrdtSequenceItem(CrdtId(0, 13), CrdtId(0, 0), CrdtId(0, 0), 0, .groupId(CrdtId(0, 11)))
                ),
            ]
        } else {
            blocks = textPageBlocks(paragraphs, authorUUID: authorUUID)
        }
        if let paperSize {
            blocks.insert(
                SceneInfo(
                    currentLayer: LwwValue(CrdtId(0, 0), CrdtId(0, 11)),
                    backgroundVisible: nil,
                    rootDocumentVisible: nil,
                    paperSize: paperSize
                ),
                at: 2
            )
        }

        var counter: UInt64 = 1000
        func nextID() -> CrdtId {
            counter += 1
            return CrdtId(2, counter)
        }
        var previousInLayer = CrdtId(0, 0)
        for group in groups {
            var parent = CrdtId(0, 11)
            if let anchor = group.anchor {
                let node = nextID()
                let g = Group(nodeId: node)
                g.label = LwwValue(CrdtId(0, 0), "")
                g.anchorId = LwwValue(nextID(), anchor.id)
                g.anchorType = LwwValue(nextID(), 2)
                g.anchorThreshold = LwwValue(nextID(), 0)
                g.anchorOriginX = LwwValue(nextID(), anchor.originX)
                blocks.append(SceneTreeBlock(tree: node, node: CrdtId(0, 0), isUpdate: true, parent: CrdtId(0, 11)))
                blocks.append(TreeNodeBlock(g))
                let itemID = nextID()
                blocks.append(
                    SceneItemBlock(
                        kind: .group,
                        parent: CrdtId(0, 11),
                        item: CrdtSequenceItem(itemID, previousInLayer, CrdtId(0, 0), 0, .groupId(node))
                    )
                )
                previousInLayer = itemID
                parent = node
            }
            var previous = parent == CrdtId(0, 11) ? previousInLayer : CrdtId(0, 0)
            for line in group.lines {
                let itemID = nextID()
                blocks.append(
                    SceneItemBlock(
                        kind: .line,
                        parent: parent,
                        item: CrdtSequenceItem(itemID, previous, CrdtId(0, 0), 0, .line(line))
                    )
                )
                previous = itemID
            }
            if parent == CrdtId(0, 11) { previousInLayer = previous }
        }
        for glyph in highlights {
            let itemID = nextID()
            blocks.append(
                SceneItemBlock(
                    kind: .glyph,
                    parent: CrdtId(0, 11),
                    item: CrdtSequenceItem(itemID, previousInLayer, CrdtId(0, 0), 0, .glyphRange(glyph))
                )
            )
            previousInLayer = itemID
        }
        return blocks
    }

    func bytes() throws -> [UInt8] {
        try writeBlocks(blocks())
    }
}

/// Builds an invented document folder or rmdoc archive for tests.
struct DocumentBuilder {
    var id: String
    var name: String
    var parent = ""
    var fileType = "notebook"
    var pages: [(id: String, page: PageBuilder?)] = []
    var pdf: Data?
    var lastModified = Date(timeIntervalSince1970: 1_792_800_000)
    var tags: [String] = []

    func files() throws -> [ArchiveFile] {
        let ms = String(Int64(lastModified.timeIntervalSince1970 * 1000))
        let metadata: [String: Any] = [
            "visibleName": name, "type": "DocumentType", "parent": parent,
            "lastModified": ms, "createdTime": ms,
        ]
        var cPages: [[String: Any]] = []
        for (i, page) in pages.enumerated() {
            var entry: [String: Any] = ["id": page.id, "idx": ["timestamp": "1:2", "value": pageIndex(i)]]
            if fileType == "pdf" { entry["redir"] = ["timestamp": "1:2", "value": i] }
            cPages.append(entry)
        }
        let content: [String: Any] = [
            "fileType": fileType, "formatVersion": 2, "pageCount": pages.count,
            "cPages": ["pages": cPages], "tags": tags.map { ["name": $0, "timestamp": 1] },
        ]
        var files = [
            ArchiveFile(name: "\(id).content", data: try JSONSerialization.data(withJSONObject: content)),
            ArchiveFile(name: "\(id).metadata", data: try JSONSerialization.data(withJSONObject: metadata)),
        ]
        if let pdf { files.append(ArchiveFile(name: "\(id).pdf", data: pdf)) }
        for page in pages {
            if let builder = page.page {
                files.append(ArchiveFile(name: "\(id)/\(page.id).rm", data: Data(try builder.bytes())))
            }
        }
        return files
    }

    func rmdoc() throws -> Data {
        storedZip(try files(), modified: lastModified)
    }
}
