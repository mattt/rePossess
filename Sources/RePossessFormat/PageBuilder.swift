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

    /// An image, as blocks 14 and 15 hold it: a file name, and a rectangle in page pixels
    /// with x from the page's center and y from its top, in a group of its own.
    struct PageImage {
        var fileName: String
        var x: Float
        var y: Float
        var width: Float
        var height: Float
        /// The group's anchor; the owner's page named an ID that is not a character of the text.
        var anchor: (id: CrdtId, originX: Float)? = (CrdtId(1, 999_999), -464)
    }

    var paragraphs: [StyledParagraph] = []
    var groups: [StrokeGroup] = []
    var images: [PageImage] = []
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
                    backgroundVisible: LwwValue(CrdtId(0, 0), true),
                    rootDocumentVisible: LwwValue(CrdtId(0, 0), true),
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
        var files: [ImageFilesBlock.Entry] = []
        for (i, image) in images.enumerated() {
            let key: ImageKey = (0 ..< 16).map { UInt8(truncatingIfNeeded: $0 * 17 + i) }
            files.append(
                ImageFilesBlock.Entry(
                    key: key,
                    fileName: LwwValue(nextID(), image.fileName),
                    flags: LwwValue(nextID(), [0x11, 0x00])
                )
            )
            let node = nextID()
            let g = Group(nodeId: node)
            if let anchor = image.anchor {
                g.anchorId = LwwValue(nextID(), anchor.id)
                g.anchorType = LwwValue(nextID(), 2)
                g.anchorThreshold = LwwValue(nextID(), 35.75)
                g.anchorOriginX = LwwValue(nextID(), anchor.originX)
            }
            blocks.append(SceneTreeBlock(tree: node, node: CrdtId(0, 0), isUpdate: true, parent: CrdtId(0, 11)))
            blocks.append(TreeNodeBlock(g))
            let groupItem = nextID()
            blocks.append(
                SceneItemBlock(
                    kind: .group,
                    parent: CrdtId(0, 11),
                    item: CrdtSequenceItem(groupItem, previousInLayer, CrdtId(0, 0), 0, .groupId(node))
                )
            )
            previousInLayer = groupItem
            let (x0, y0, x1, y1) = (image.x, image.y, image.x + image.width, image.y + image.height)
            let item = ImageItem(
                key: LwwValue(nextID(), key),
                unknownId: nextID(),
                vertices: [
                    ImageVertex(x: x0, y: y0, u: 0, v: 0), ImageVertex(x: x1, y: y0, u: 1, v: 0),
                    ImageVertex(x: x1, y: y1, u: 1, v: 1), ImageVertex(x: x0, y: y1, u: 0, v: 1),
                ],
                indices: [0, 1, 2, 2, 3, 0]
            )
            blocks.append(
                SceneImageItemBlock(
                    parentId: node,
                    item: CrdtSequenceItem(nextID(), CrdtId(0, 0), CrdtId(0, 0), 0, item)
                )
            )
        }
        if !files.isEmpty {
            // The owner's page had block 14 after the page's first blocks, before the text.
            blocks.insert(ImageFilesBlock(entries: files), at: min(3, blocks.count))
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
    /// Other files, such as a page's images in `<page-id>/<file>.png`, named relative to the document's folder.
    var extraFiles: [ArchiveFile] = []
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
            ArchiveFile(
                name: "\(id).content",
                data: try JSONSerialization.data(withJSONObject: content, options: .sortedKeys)
            ),
            ArchiveFile(
                name: "\(id).metadata",
                data: try JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)
            ),
        ]
        if let pdf { files.append(ArchiveFile(name: "\(id).pdf", data: pdf)) }
        for file in extraFiles { files.append(ArchiveFile(name: "\(id)/\(file.name)", data: file.data)) }
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
