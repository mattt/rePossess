// Ported from rmscene's scene_stream.py (the writing half: `to_stream`,
// `write_blocks`, and `simple_text_document`)
// (https://github.com/ricklupton/rmscene, v0.8.0).
// rmscene is Copyright (c) 2023 Rick Lupton and is MIT licensed;
// see LICENSE-rmscene in this directory.
//
// Added for the notebook writer, with lines and glyph ranges added
// so that tests can make pages with strokes and highlights.
// It writes what rmscene writes when no "version" option is given,
// which is the newest form of each block.

import Foundation

/// A block that can be written.
public protocol WritableBlock: Block {
    /// The (min_version, current_version) pair for the block header.
    func versionInfo() -> (UInt8, UInt8)
    /// Write the content of the block.
    func toStream(_ writer: TaggedBlockWriter) throws
}

extension WritableBlock {
    public func versionInfo() -> (UInt8, UInt8) { (1, 1) }

    /// Write the block header and content, then any extra data kept from a read.
    public func write(_ writer: TaggedBlockWriter) throws {
        let (minVersion, currentVersion) = versionInfo()
        try writer.writeBlock(blockType, minVersion: minVersion, currentVersion: currentVersion) {
            try toStream(writer)
            writer.data.writeBytes(extraData)
        }
    }
}

// MARK: Public initializers, so that other modules can build blocks

extension AuthorIdsBlock {
    public init(_ authorUUIDs: [(UInt16, UUID)]) { self.init(authorUUIDs: authorUUIDs) }
}

extension MigrationInfoBlock {
    public init(migrationId: CrdtId, isDevice: Bool) {
        self.init(migrationId: migrationId, isDevice: isDevice, unknown: false)
    }
}

extension PageInfoBlock {
    public init(loadsCount: UInt32, mergesCount: UInt32, textCharsCount: UInt32, textLinesCount: UInt32) {
        self.init(
            loadsCount: loadsCount,
            mergesCount: mergesCount,
            textCharsCount: textCharsCount,
            textLinesCount: textLinesCount,
            typeFolioUseCount: 0
        )
    }
}

extension SceneTreeBlock {
    public init(tree treeId: CrdtId, node nodeId: CrdtId, isUpdate: Bool, parent parentId: CrdtId) {
        self.init(treeId: treeId, nodeId: nodeId, isUpdate: isUpdate, parentId: parentId)
    }
}

extension TreeNodeBlock {
    public init(_ group: Group) { self.init(group: group) }
}

extension RootTextBlock {
    public init(_ value: Text) { self.init(blockId: CrdtId(0, 0), value: value) }
}

extension SceneItemBlock {
    public init(kind: Kind, parent parentId: CrdtId, item: CrdtSequenceItem<SceneItemValue?>) {
        self.init(kind: kind, parentId: parentId, item: item)
    }
}

// MARK: to_stream

extension UnreadableBlock: WritableBlock {
    public func versionInfo() -> (UInt8, UInt8) {
        (UInt8(info.minVersion), UInt8(info.currentVersion))
    }

    public func toStream(_ writer: TaggedBlockWriter) throws {
        writer.data.writeBytes(data)
    }
}

extension SceneInfo: WritableBlock {
    public func versionInfo() -> (UInt8, UInt8) { (0, 1) }

    public func toStream(_ writer: TaggedBlockWriter) throws {
        try writer.writeLwwId(1, currentLayer)
        if let backgroundVisible { try writer.writeLwwBool(2, backgroundVisible) }
        if let rootDocumentVisible { try writer.writeLwwBool(3, rootDocumentVisible) }
        if let paperSize { writer.writeIntPair(5, paperSize) }
    }
}

extension AuthorIdsBlock: WritableBlock {
    public func toStream(_ writer: TaggedBlockWriter) throws {
        writer.data.writeVarUInt(UInt64(authorUUIDs.count))
        for (authorId, uuid) in authorUUIDs {
            writer.writeSubblock(0) {
                // Python's UUID.bytes_le: the first three fields are little-endian.
                let u = uuid.uuid
                let bytesLE: [UInt8] = [
                    u.3, u.2, u.1, u.0, u.5, u.4, u.7, u.6,
                    u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
                ]
                writer.data.writeVarUInt(UInt64(bytesLE.count))
                writer.data.writeBytes(bytesLE)
                writer.data.writeUInt16(authorId)
            }
        }
    }
}

extension MigrationInfoBlock: WritableBlock {
    public func toStream(_ writer: TaggedBlockWriter) throws {
        try writer.writeId(1, migrationId)
        writer.writeBool(2, isDevice)
        writer.writeBool(3, unknown)  // rmscene writes this for version 3.2.2 and later
    }
}

extension TreeNodeBlock: WritableBlock {
    public func versionInfo() -> (UInt8, UInt8) { (1, 2) }  // rmscene: version 3.4 and later

    public func toStream(_ writer: TaggedBlockWriter) throws {
        try writer.writeId(1, group.nodeId)
        try writer.writeLwwString(2, group.label)
        try writer.writeLwwBool(3, group.visible)
        if let anchorId = group.anchorId {
            guard let anchorType = group.anchorType, let anchorThreshold = group.anchorThreshold,
                let anchorOriginX = group.anchorOriginX
            else {
                throw RMSceneError.assertion("anchor fields")
            }
            try writer.writeLwwId(7, anchorId)
            try writer.writeLwwByte(8, anchorType)
            try writer.writeLwwFloat(9, anchorThreshold)
            try writer.writeLwwFloat(10, anchorOriginX)
        }
    }
}

extension PageInfoBlock: WritableBlock {
    public func versionInfo() -> (UInt8, UInt8) { (0, 1) }

    public func toStream(_ writer: TaggedBlockWriter) throws {
        writer.writeInt(1, loadsCount)
        writer.writeInt(2, mergesCount)
        writer.writeInt(3, textCharsCount)
        writer.writeInt(4, textLinesCount)
        writer.writeInt(5, typeFolioUseCount)  // rmscene writes this for version 3.2.2 and later
    }
}

extension SceneTreeBlock: WritableBlock {
    public func toStream(_ writer: TaggedBlockWriter) throws {
        try writer.writeId(1, treeId)
        try writer.writeId(2, nodeId)
        writer.writeBool(3, isUpdate)
        try writer.writeSubblock(4) {
            try writer.writeId(1, parentId)
        }
    }
}

extension SceneItemBlock: WritableBlock {
    public func versionInfo() -> (UInt8, UInt8) {
        kind == .line ? (2, 2) : (1, 1)  // rmscene: lines are (2, 2) after version 3.0
    }

    public func toStream(_ writer: TaggedBlockWriter) throws {
        try writer.writeId(1, parentId)
        try writer.writeId(2, item.itemId)
        try writer.writeId(3, item.leftId)
        try writer.writeId(4, item.rightId)
        writer.writeInt(5, item.deletedLength)

        if let value = item.value {
            try writer.writeSubblock(6) {
                writer.data.writeUInt8(kind.itemType)
                switch value {
                case .groupId(let id):
                    try writer.writeId(2, id)
                case .line(let line):
                    try lineToStream(line, writer)
                case .glyphRange(let glyph):
                    try glyphRangeToStream(glyph, writer)
                }
                writer.data.writeBytes(extraValueData)
            }
        }
    }
}

/// rmscene's `point_to_stream`, version 2.
func pointToStream(_ point: Point, _ writer: TaggedBlockWriter) {
    let d = writer.data
    d.writeFloat32(Float(point.x))
    d.writeFloat32(Float(point.y))
    d.writeUInt16(UInt16(clamping: Int(point.speed)))
    d.writeUInt16(UInt16(clamping: point.width))
    d.writeUInt8(UInt8(clamping: Int(point.direction)))
    d.writeUInt8(UInt8(clamping: Int(point.pressure)))
}

/// rmscene's `line_to_stream`, version 2.
func lineToStream(_ line: Line, _ writer: TaggedBlockWriter) throws {
    writer.writeInt(1, line.tool.rawValue)
    writer.writeInt(2, line.color.rawValue)
    writer.writeDouble(3, line.thicknessScale)
    writer.writeFloat(4, Float(line.startingLength))
    writer.writeSubblock(5) {
        for point in line.points {
            pointToStream(point, writer)
        }
    }
    // rmscene: "XXX didn't save"
    try writer.writeId(6, CrdtId(0, 1))
    if let moveId = line.moveId {
        try writer.writeId(7, moveId)
    }
    if let rgba = line.colorRGBA {
        writer.writeColor(8, rgba)
    }
}

/// rmscene's `glyph_range_to_stream`.
func glyphRangeToStream(_ glyph: GlyphRange, _ writer: TaggedBlockWriter) throws {
    if let start = glyph.start {
        writer.writeInt(2, start)
        writer.writeInt(3, UInt32(glyph.length))
    }
    writer.writeInt(4, glyph.color.rawValue)
    writer.writeString(5, glyph.text)
    writer.writeSubblock(6) {
        writer.data.writeVarUInt(UInt64(glyph.rectangles.count))
        for r in glyph.rectangles {
            writer.data.writeFloat64(r.x)
            writer.data.writeFloat64(r.y)
            writer.data.writeFloat64(r.w)
            writer.data.writeFloat64(r.h)
        }
    }
    if let rgba = glyph.colorRGBA {
        writer.writeColor(10, rgba)
    }
}

func textItemToStream(_ item: CrdtSequenceItem<TextValue>, _ writer: TaggedBlockWriter) throws {
    try writer.writeSubblock(0) {
        try writer.writeId(2, item.itemId)
        try writer.writeId(3, item.leftId)
        try writer.writeId(4, item.rightId)
        writer.writeInt(5, item.deletedLength)

        // Python writes the value only when it is truthy.
        switch item.value {
        case .string(let s) where !s.isEmpty:
            writer.writeString(6, s)
        case .format(let code) where code != 0:
            writer.writeStringWithFormat(6, "", code)
        default:
            break
        }
    }
}

func textFormatToStream(_ charId: CrdtId, _ value: LwwValue<ParagraphStyle>, _ writer: TaggedBlockWriter) throws {
    try writer.data.writeCrdtId(charId)
    try writer.writeId(1, value.timestamp)
    writer.writeSubblock(2) {
        writer.data.writeUInt8(17)  // rmscene: "XXX not sure what this is format?"
        writer.data.writeUInt8(UInt8(value.value.rawValue))
    }
}

extension RootTextBlock: WritableBlock {
    /// Writes the styles in `CrdtId` order.
    /// rmscene writes them in its dict's order, which is file order for a page it read;
    /// `Text.styles` is a Swift dictionary and keeps no order.
    public func toStream(_ writer: TaggedBlockWriter) throws {
        try writer.writeId(1, blockId)

        try writer.writeSubblock(2) {
            // Text items
            let textItems = value.items.sequenceItems()
            try writer.writeSubblock(1) {
                try writer.writeSubblock(1) {
                    writer.data.writeVarUInt(UInt64(textItems.count))
                    for item in textItems {
                        try textItemToStream(item, writer)
                    }
                }
            }
            // Formatting
            let textFormats = value.styles.sorted { $0.key < $1.key }
            try writer.writeSubblock(2) {
                try writer.writeSubblock(1) {
                    writer.data.writeVarUInt(UInt64(textFormats.count))
                    for (key, item) in textFormats {
                        try textFormatToStream(key, item, writer)
                    }
                }
            }
        }

        // Last section
        writer.writeSubblock(3) {
            writer.data.writeFloat64(value.posX)
            writer.data.writeFloat64(value.posY)
        }

        // "width" from ddvk
        writer.writeFloat(4, Float(value.width))
    }
}

// MARK: Writing streams of blocks

/// Write blocks to a new file, and return its bytes.
public func writeBlocks(_ blocks: [any WritableBlock]) throws -> [UInt8] {
    let writer = TaggedBlockWriter()
    writer.writeHeader()
    for block in blocks {
        try block.write(writer)
    }
    return writer.bytes
}

/// Return the basic blocks to represent `text` as plain text.
public func simpleTextDocument(_ text: String, authorUUID: UUID = UUID()) -> [any WritableBlock] {
    let rootGroup = Group(nodeId: CrdtId(0, 1))
    let layer = Group(nodeId: CrdtId(0, 11))
    layer.label = LwwValue(CrdtId(0, 12), "Layer 1")
    return [
        AuthorIdsBlock([(1, authorUUID)]),
        MigrationInfoBlock(migrationId: CrdtId(1, 1), isDevice: true),
        PageInfoBlock(
            loadsCount: 1,
            mergesCount: 0,
            // Python's len() counts code points.
            textCharsCount: UInt32(text.unicodeScalars.count + 1),
            textLinesCount: UInt32(text.unicodeScalars.filter { $0 == "\n" }.count + 1)
        ),
        SceneTreeBlock(tree: CrdtId(0, 11), node: CrdtId(0, 0), isUpdate: true, parent: CrdtId(0, 1)),
        RootTextBlock(
            Text(
                items: CrdtSequence([
                    CrdtSequenceItem(CrdtId(1, 16), CrdtId(0, 0), CrdtId(0, 0), 0, TextValue.string(text))
                ]),
                styles: [CrdtId(0, 0): LwwValue(CrdtId(1, 15), .plain)],
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
