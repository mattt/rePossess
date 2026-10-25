// Ported from rmscene's scene_stream.py (the reading half)
// (https://github.com/ricklupton/rmscene, v0.8.0).
// rmscene is Copyright (c) 2023 Rick Lupton and is MIT licensed;
// see LICENSE-rmscene in this directory.

import Foundation

// MARK: Top-level block types

/// A top-level block. `extraData` keeps any data the reader did not understand.
public protocol Block {
    var blockType: Int { get }
    var extraData: [UInt8] { get set }
}

/// Look up and read one block, as rmscene's `Block.read` does.
/// Returns `nil` when no block remains.
func readBlock(_ reader: TaggedBlockReader) throws -> (any Block)? {
    var blockInfo: MainBlockInfo?
    var block: (any Block)? = try reader.readBlock { info -> (any Block)? in
        guard let info else { return nil }
        blockInfo = info
        if let read = blockReader(for: info.blockType) {
            do {
                return try read(reader)
            } catch {
                reader.data.seek(info.offset)
                let data = try reader.data.readBytes(info.size)
                return UnreadableBlock(error: "\(error)", data: data, info: info)
            }
        }
        let data = try reader.data.readBytes(info.size)
        return UnreadableBlock(
            error: "Unknown block type \(info.blockType). Skipping \(info.size) bytes.",
            data: data,
            info: info
        )
    }
    // Keep any unparsed extra data, which the length check filled in.
    if let blockInfo { block?.extraData = blockInfo.extraData }
    return block
}

/// rmscene's `Block.lookup`, which searches the subclasses of `Block`.
func blockReader(for blockType: Int) -> ((TaggedBlockReader) throws -> any Block)? {
    switch blockType {
    case SceneInfo.blockType: SceneInfo.fromStream
    case AuthorIdsBlock.blockType: AuthorIdsBlock.fromStream
    case MigrationInfoBlock.blockType: MigrationInfoBlock.fromStream
    case TreeNodeBlock.blockType: TreeNodeBlock.fromStream
    case PageInfoBlock.blockType: PageInfoBlock.fromStream
    case SceneTreeBlock.blockType: SceneTreeBlock.fromStream
    case SceneItemBlock.Kind.tombstone.rawValue, SceneItemBlock.Kind.glyph.rawValue,
        SceneItemBlock.Kind.group.rawValue, SceneItemBlock.Kind.line.rawValue,
        SceneItemBlock.Kind.text.rawValue:
        SceneItemBlock.fromStream
    case RootTextBlock.blockType: RootTextBlock.fromStream
    // rePossess's own: images, which rmscene 0.8.0 does not read (see PageImages.swift).
    case ImageFilesBlock.blockType: ImageFilesBlock.fromStream
    case SceneImageItemBlock.blockType: SceneImageItemBlock.fromStream
    default: nil
    }
}

/// A block that could not be read; its bytes are kept as they are.
public struct UnreadableBlock: Block {
    public var error: String
    public var data: [UInt8]
    public var info: MainBlockInfo
    public var extraData: [UInt8] = []
    public var blockType: Int { info.blockType }
}

public struct SceneInfo: Block {
    public static let blockType = 0x0D
    public var blockType: Int { Self.blockType }
    public var extraData: [UInt8] = []

    public var currentLayer: LwwValue<CrdtId>
    public var backgroundVisible: LwwValue<Bool>?
    public var rootDocumentVisible: LwwValue<Bool>?
    public var paperSize: (UInt32, UInt32)?

    static func fromStream(_ stream: TaggedBlockReader) throws -> any Block {
        let currentLayer = try stream.readLwwId(1)
        let backgroundVisible = try stream.bytesRemainingInBlock() > 0 ? try stream.readLwwBool(2) : nil
        let rootDocumentVisible = try stream.bytesRemainingInBlock() > 0 ? try stream.readLwwBool(3) : nil
        let paperSize = try stream.bytesRemainingInBlock() > 0 ? try stream.readIntPair(5) : nil
        return SceneInfo(
            currentLayer: currentLayer,
            backgroundVisible: backgroundVisible,
            rootDocumentVisible: rootDocumentVisible,
            paperSize: paperSize
        )
    }
}

public struct AuthorIdsBlock: Block {
    public static let blockType = 0x09
    public var blockType: Int { Self.blockType }
    public var extraData: [UInt8] = []

    /// Author IDs and their UUIDs, in file order.
    public var authorUUIDs: [(UInt16, UUID)]

    static func fromStream(_ stream: TaggedBlockReader) throws -> any Block {
        let count = try stream.data.readVarUInt()
        var authors: [(UInt16, UUID)] = []
        for _ in 0 ..< count {
            try stream.readSubblock(0) { _ in
                let uuidLength = try stream.data.readVarUInt()
                if uuidLength != 16 {
                    throw RMSceneError.value("Expected UUID length to be 16 bytes")
                }
                let b = try stream.data.readBytes(16)
                // Python's UUID(bytes_le=): the first three fields are little-endian.
                let uuid = UUID(
                    uuid: (
                        b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6],
                        b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
                    )
                )
                let authorId = try stream.data.readUInt16()
                authors.removeAll { $0.0 == authorId }  // a dict keeps the last value
                authors.append((authorId, uuid))
            }
        }
        return AuthorIdsBlock(authorUUIDs: authors)
    }
}

public struct MigrationInfoBlock: Block {
    public static let blockType = 0x00
    public var blockType: Int { Self.blockType }
    public var extraData: [UInt8] = []

    public var migrationId: CrdtId
    public var isDevice: Bool
    public var unknown: Bool

    static func fromStream(_ stream: TaggedBlockReader) throws -> any Block {
        let migrationId = try stream.readId(1)
        let isDevice = try stream.readBool(2)
        let unknown = try stream.bytesRemainingInBlock() != 0 ? try stream.readBool(3) : false
        return MigrationInfoBlock(migrationId: migrationId, isDevice: isDevice, unknown: unknown)
    }
}

public struct TreeNodeBlock: Block {
    public static let blockType = 0x02
    public var blockType: Int { Self.blockType }
    public var extraData: [UInt8] = []

    public var group: Group

    static func fromStream(_ stream: TaggedBlockReader) throws -> any Block {
        let group = Group(nodeId: try stream.readId(1))
        group.label = try stream.readLwwString(2)
        group.visible = try stream.readLwwBool(3)
        if try stream.bytesRemainingInBlock() > 0 {
            group.anchorId = try stream.readLwwId(7)
            group.anchorType = try stream.readLwwByte(8)
            group.anchorThreshold = try stream.readLwwFloat(9)
            group.anchorOriginX = try stream.readLwwFloat(10)
        }
        return TreeNodeBlock(group: group)
    }
}

public struct PageInfoBlock: Block {
    public static let blockType = 0x0A
    public var blockType: Int { Self.blockType }
    public var extraData: [UInt8] = []

    public var loadsCount: UInt32
    public var mergesCount: UInt32
    public var textCharsCount: UInt32
    public var textLinesCount: UInt32
    public var typeFolioUseCount: UInt32 = 0

    static func fromStream(_ stream: TaggedBlockReader) throws -> any Block {
        var info = PageInfoBlock(
            loadsCount: try stream.readInt(1),
            mergesCount: try stream.readInt(2),
            textCharsCount: try stream.readInt(3),
            textLinesCount: try stream.readInt(4)
        )
        if try stream.bytesRemainingInBlock() != 0 {
            info.typeFolioUseCount = try stream.readInt(5)
        }
        return info
    }
}

public struct SceneTreeBlock: Block {
    public static let blockType = 0x01
    public var blockType: Int { Self.blockType }
    public var extraData: [UInt8] = []

    public var treeId: CrdtId
    public var nodeId: CrdtId
    public var isUpdate: Bool
    public var parentId: CrdtId

    static func fromStream(_ stream: TaggedBlockReader) throws -> any Block {
        let treeId = try stream.readId(1)
        let nodeId = try stream.readId(2)
        let isUpdate = try stream.readBool(3)
        let parentId = try stream.readSubblock(4) { _ in try stream.readId(1) }
        return SceneTreeBlock(treeId: treeId, nodeId: nodeId, isUpdate: isUpdate, parentId: parentId)
    }
}

// MARK: Points and lines

func pointFromStream(_ stream: TaggedBlockReader, version: Int = 2) throws -> Point {
    guard version == 1 || version == 2 else {
        throw RMSceneError.value("Unknown version \(version)")
    }
    let d = stream.data
    let x = Double(try d.readFloat32())
    let y = Double(try d.readFloat32())
    if version == 1 {
        // Calculation based on ddvk's reader, in Python's double arithmetic.
        let speed = Double(try d.readFloat32()) * 4
        let direction = 255 * Double(try d.readFloat32()) / (Double.pi * 2)
        let w = Double(try d.readFloat32()) * 4
        guard w.isFinite else { throw RMSceneError.value("cannot round \(w)") }
        let width = Int(w.rounded(.toNearestOrEven))  // Python's round()
        let pressure = Double(try d.readFloat32()) * 255
        return Point(x: x, y: y, speed: speed, direction: direction, width: width, pressure: pressure)
    }
    let speed = try d.readUInt16()
    let width = try d.readUInt16()
    let direction = try d.readUInt8()
    let pressure = try d.readUInt8()
    return Point(
        x: x,
        y: y,
        speed: Double(speed),
        direction: Double(direction),
        width: Int(width),
        pressure: Double(pressure)
    )
}

func pointSerializedSize(version: Int = 2) throws -> Int {
    switch version {
    case 1: 0x18
    case 2: 0x0E
    default: throw RMSceneError.value("Unknown version \(version)")
    }
}

func lineFromStream(_ stream: TaggedBlockReader, version: Int = 2) throws -> Line {
    let tool = Pen(rawValue: try stream.readInt(1))
    let color = PenColor(rawValue: try stream.readInt(2))
    let thicknessScale = try stream.readDouble(3)
    let startingLength = Double(try stream.readFloat(4))
    let points = try stream.readSubblock(5) { info in
        let pointSize = try pointSerializedSize(version: version)
        if info.size % pointSize != 0 {
            throw RMSceneError.value("Point data size mismatch: \(info.size) is not multiple of point_size")
        }
        return try (0 ..< info.size / pointSize).map { _ in try pointFromStream(stream, version: version) }
    }

    _ = try stream.readId(6)  // timestamp, unused

    var moveId: CrdtId?
    if stream.bytesRemainingInEnclosing() >= 3 {
        do {
            moveId = try stream.readId(7)
        } catch RMSceneError.unexpectedBlock {
            moveId = nil
        }
    }

    let colorRGBA = try stream.readColorOptional(8)
    return Line(
        color: color,
        tool: tool,
        points: points,
        thicknessScale: thicknessScale,
        startingLength: startingLength,
        moveId: moveId,
        colorRGBA: colorRGBA
    )
}

// MARK: Scene items

/// The value that a scene item block carries.
public enum SceneItemValue {
    case glyphRange(GlyphRange)
    /// The node ID of a group; `build_tree` swaps in the group.
    case groupId(CrdtId)
    case line(Line)
}

/// rmscene's `SceneItemBlock` and its five subclasses, told apart by `kind`.
public struct SceneItemBlock: Block {
    public enum Kind: Int, Sendable {
        case glyph = 0x03, group = 0x04, line = 0x05, text = 0x06, tombstone = 0x08

        /// The item type byte in the value subblock.
        var itemType: UInt8 {
            switch self {
            case .glyph: 0x01
            case .group: 0x02
            case .line: 0x03
            case .text: 0x05
            case .tombstone: 0x00
            }
        }

        /// The Python class name.
        public var name: String {
            switch self {
            case .glyph: "SceneGlyphItemBlock"
            case .group: "SceneGroupItemBlock"
            case .line: "SceneLineItemBlock"
            case .text: "SceneTextItemBlock"
            case .tombstone: "SceneTombstoneItemBlock"
            }
        }
    }

    public var kind: Kind
    public var blockType: Int { kind.rawValue }
    public var extraData: [UInt8] = []
    public var parentId: CrdtId
    public var item: CrdtSequenceItem<SceneItemValue?>
    public var extraValueData: [UInt8] = []

    static func fromStream(_ stream: TaggedBlockReader) throws -> any Block {
        guard let current = stream.currentBlock, let kind = Kind(rawValue: current.blockType) else {
            throw RMSceneError.value("unknown scene type")
        }
        let parentId = try stream.readId(1)
        let itemId = try stream.readId(2)
        let leftId = try stream.readId(3)
        let rightId = try stream.readId(4)
        let deletedLength = try stream.readInt(5)

        var value: SceneItemValue?
        var extraValueData: [UInt8] = []
        if try stream.hasSubblock(6) {
            let info = try stream.readSubblock(6) { info in
                let itemType = try stream.data.readUInt8()
                guard itemType == kind.itemType else {
                    throw RMSceneError.assertion("item type \(itemType) != \(kind.itemType)")
                }
                value = try valueFromStream(kind, stream)
                return info
            }
            // Keep known extra data from within the value subblock.
            extraValueData = info.extraData
        }
        return SceneItemBlock(
            kind: kind,
            parentId: parentId,
            item: CrdtSequenceItem(itemId, leftId, rightId, deletedLength, value),
            extraValueData: extraValueData
        )
    }

    static func valueFromStream(_ kind: Kind, _ stream: TaggedBlockReader) throws -> SceneItemValue? {
        switch kind {
        case .tombstone, .text:
            return nil
        case .glyph:
            return .glyphRange(try glyphRangeFromStream(stream))
        case .group:
            return .groupId(try stream.readId(2))
        case .line:
            return .line(try lineFromStream(stream, version: stream.currentBlock!.currentVersion))
        }
    }
}

func glyphRangeFromStream(_ stream: TaggedBlockReader) throws -> GlyphRange {
    // Since reMarkable software 3.6, the start and length are optional.
    let start = try stream.readIntOptional(2)
    let length = try stream.readIntOptional(3)
    let color = PenColor(rawValue: try stream.readInt(4))
    let text = try stream.readString(5)
    let rectangles = try stream.readSubblock(6) { _ in
        let count = try stream.data.readVarUInt()
        return try (0 ..< count).map { _ in
            Rectangle(
                x: try stream.data.readFloat64(),
                y: try stream.data.readFloat64(),
                w: try stream.data.readFloat64(),
                h: try stream.data.readFloat64()
            )
        }
    }
    let colorRGBA = try stream.readColorOptional(10)
    return GlyphRange(
        start: start,
        // Python's len() counts code points.
        length: length.map(Int.init) ?? text.unicodeScalars.count,
        text: text,
        color: color,
        rectangles: rectangles,
        colorRGBA: colorRGBA
    )
}

// MARK: Text

func textItemFromStream(_ stream: TaggedBlockReader) throws -> CrdtSequenceItem<TextValue> {
    try stream.readSubblock(0) { _ in
        let itemId = try stream.readId(2)
        let leftId = try stream.readId(3)
        let rightId = try stream.readId(4)
        let deletedLength = try stream.readInt(5)
        var value = TextValue.string("")
        if try stream.hasSubblock(6) {
            let (text, fmt) = try stream.readStringWithFormat(6)
            // Formats are stored on empty strings, so it's one or the other.
            value = fmt.map(TextValue.format) ?? .string(text)
        }
        return CrdtSequenceItem(itemId, leftId, rightId, deletedLength, value)
    }
}

func textFormatFromStream(_ stream: TaggedBlockReader) throws -> (CrdtId, LwwValue<ParagraphStyle>) {
    // Character IDs, without the tag that other IDs have.
    let charId = try stream.data.readCrdtId()
    let timestamp = try stream.readId(1)
    let style = try stream.readSubblock(2) { _ in
        let c = try stream.data.readUInt8()
        guard c == 17 else { throw RMSceneError.assertion("text format marker \(c) != 17") }
        let code = try stream.data.readUInt8()
        return ParagraphStyle(rawValue: Int(code)) ?? .plain  // unrecognized: fall back
    }
    return (charId, LwwValue(timestamp, style))
}

public struct RootTextBlock: Block {
    public static let blockType = 0x07
    public var blockType: Int { Self.blockType }
    public var extraData: [UInt8] = []

    public var blockId: CrdtId
    public var value: Text

    static func fromStream(_ stream: TaggedBlockReader) throws -> any Block {
        let blockId = try stream.readId(1)
        guard blockId == CrdtId(0, 0) else { throw RMSceneError.assertion("root text block id") }

        var textItems: [CrdtSequenceItem<TextValue>] = []
        var textFormats: [CrdtId: LwwValue<ParagraphStyle>] = [:]
        try stream.readSubblock(2) { _ in
            // Text items
            try stream.readSubblock(1) { _ in
                try stream.readSubblock(1) { _ in
                    let count = try stream.data.readVarUInt()
                    textItems = try (0 ..< count).map { _ in try textItemFromStream(stream) }
                }
            }
            // Formatting
            try stream.readSubblock(2) { _ in
                try stream.readSubblock(1) { _ in
                    let count = try stream.data.readVarUInt()
                    for _ in 0 ..< count {
                        let (key, value) = try textFormatFromStream(stream)
                        textFormats[key] = value
                    }
                }
            }
        }

        // "pos_x" and "pos_y" from ddvk.
        let (posX, posY) = try stream.readSubblock(3) { _ in
            (try stream.data.readFloat64(), try stream.data.readFloat64())
        }
        // "width" from ddvk.
        let width = Double(try stream.readFloat(4))

        return RootTextBlock(
            blockId: blockId,
            value: Text(
                items: CrdtSequence(textItems),
                styles: textFormats,
                posX: posX,
                posY: posY,
                width: width
            )
        )
    }
}

// MARK: Reading streams of blocks

/// Parse a reMarkable v6 file and return its blocks.
public func readBlocks(_ bytes: [UInt8]) throws -> [any Block] {
    let stream = TaggedBlockReader(bytes)
    try stream.readHeader()
    var blocks: [any Block] = []
    while let block = try readBlock(stream) {
        blocks.append(block)
    }
    return blocks
}

/// Read `blocks` and add their contents to `tree`.
public func buildTree(_ tree: SceneTree, _ blocks: [any Block]) throws {
    for b in blocks {
        try addToTree(tree, b)
    }
}

/// Add one block's contents to `tree`, as rmscene's `build_tree` does for each block.
func addToTree(_ tree: SceneTree, _ b: any Block) throws {
    do {
        switch b {
        case let b as SceneTreeBlock:
            try tree.addNode(b.treeId, parentId: b.parentId)
        case let b as TreeNodeBlock:
            // Expect this node to exist already; this adds information.
            guard let node = tree[b.group.nodeId] else {
                throw RMSceneError.value("Node does not exist for TreeNodeBlock: \(b.group.nodeId)")
            }
            node.label = b.group.label
            node.visible = b.group.visible
            node.anchorId = b.group.anchorId
            node.anchorType = b.group.anchorType
            node.anchorThreshold = b.group.anchorThreshold
            node.anchorOriginX = b.group.anchorOriginX
        case let b as SceneItemBlock:
            let item = b.item
            switch b.kind {
            case .group:
                // Add this entry to the children of parent_id.
                guard case .groupId(let nodeId)? = item.value else { return }
                guard let node = tree[nodeId] else {
                    throw RMSceneError.value("Node does not exist for SceneGroupItemBlock: \(nodeId)")
                }
                try tree.addItem(
                    CrdtSequenceItem(item.itemId, item.leftId, item.rightId, item.deletedLength, .group(node)),
                    parentId: b.parentId
                )
            case .line, .glyph:
                let value: SceneItem? =
                    switch item.value {
                    case .line(let line)?: .line(line)
                    case .glyphRange(let glyph)?: .glyphRange(glyph)
                    default: nil
                    }
                try tree.addItem(
                    CrdtSequenceItem(item.itemId, item.leftId, item.rightId, item.deletedLength, value),
                    parentId: b.parentId
                )
            case .text, .tombstone:
                break
            }
        case let b as ImageFilesBlock:
            for entry in b.entries { tree.imageFiles[entry.key] = entry.fileName.value }
        case let b as SceneImageItemBlock:
            let item = b.item
            try tree.addItem(
                CrdtSequenceItem(
                    item.itemId,
                    item.leftId,
                    item.rightId,
                    item.deletedLength,
                    item.value.map(SceneItem.image)
                ),
                parentId: b.parentId
            )
        case let b as SceneInfo:
            tree.sceneInfo = b
        case let b as RootTextBlock:
            tree.rootText = b.value
        default:
            break
        }
    }
}

/// The result of ``readPage(_:)``.
public struct PageReadResult {
    /// The blocks that were read, up to the first error that stopped the read.
    public var blocks: [any Block]
    /// The scene tree built from the blocks that could be added.
    public var tree: SceneTree
    /// What the reader skipped: blocks it could not read,
    /// tree items whose parent was missing, and a truncated end.
    public var warnings: [String]
}

/// Read a page and keep everything that can be read.
///
/// rePossess departs from rmscene here.
/// rmscene fails the whole page on a truncated file or a scene tree error;
/// this keeps the blocks before a truncation, skips tree items that cannot be added,
/// and lists each problem in `warnings`.
/// A file without the version 6 header gives an empty tree and one warning.
public func readPage(_ bytes: [UInt8]) -> PageReadResult {
    let stream = TaggedBlockReader(bytes)
    var blocks: [any Block] = []
    var warnings: [String] = []
    do {
        try stream.readHeader()
        while let block = try readBlock(stream) {
            blocks.append(block)
        }
    } catch {
        warnings.append("The page stops early at byte \(stream.data.tell()) of \(bytes.count): \(error)")
    }
    let tree = SceneTree()
    for block in blocks {
        if let unreadable = block as? UnreadableBlock {
            warnings.append("Block type \(unreadable.blockType) at byte \(unreadable.info.offset): \(unreadable.error)")
            continue
        }
        do {
            try addToTree(tree, block)
        } catch {
            warnings.append("Skipped a block of type \(block.blockType): \(error)")
        }
    }
    return PageReadResult(blocks: blocks, tree: tree, warnings: warnings)
}

/// Parse a reMarkable v6 file and return its scene tree.
public func readTree(_ bytes: [UInt8]) throws -> SceneTree {
    let tree = SceneTree()
    try buildTree(tree, try readBlocks(bytes))
    return tree
}
