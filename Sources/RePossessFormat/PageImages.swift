import Foundation

// Images on a notebook page: block types 14 and 15, which rmscene 0.8.0 does not know.
//
// The format was worked out on 2026-10-25 from one page of the owner's library:
// a typed notebook with two PNG images, each a table that reMarkdown drew,
// and the tablet's PDF export of that page.
// The PNG files are in the archive at `<document>/<page>/<file>.png`.
//
// - Block 14 lists the page's image files. Its body is a subblock 1 that holds a count, then for each image
//   a subblock 0 with a 16-byte key, a last-write-wins file name in subblock 1,
//   and a last-write-wins subblock 2 whose value was one byte, tag 1, 0 (meaning unknown).
// - Block 15 is a scene item in a group, like a stroke, with item type 7.
//   Its value has the key as a last-write-wins 16-byte subblock 1, an ID in tag 2 (meaning unknown),
//   the vertices in subblock 3 (a count of floats, then x, y, u, and v for each vertex),
//   and the triangle indices in subblock 4 (a count, then 32-bit indices).
//   The two images were each a rectangle of 4 vertices and 2 triangles.
//
// The tablet's export drew each image at its vertices' x and y,
// in tablet pixels with x from the page's center and y from its top, as strokes are,
// with u and v from 0 to 1 across the PNG from its top left (checked for both images).
// Both images' groups had an anchor that named no character of the text,
// and the export ignored the anchor's x origin.

/// A key that ties an image item to its file: 16 bytes.
public typealias ImageKey = [UInt8]

/// Block type 14: the files of a page's images, by key.
public struct ImageFilesBlock: Block {
    public static let blockType = 0x0E
    public var blockType: Int { Self.blockType }
    public var extraData: [UInt8] = []

    /// One image file.
    public struct Entry: Sendable {
        public var key: ImageKey
        public var fileName: LwwValue<String>
        /// Subblock 2, whose meaning is unknown, as it was read: its timestamp and its value's bytes.
        public var flags: LwwValue<[UInt8]>?

        public init(key: ImageKey, fileName: LwwValue<String>, flags: LwwValue<[UInt8]>? = nil) {
            self.key = key
            self.fileName = fileName
            self.flags = flags
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    static func fromStream(_ stream: TaggedBlockReader) throws -> any Block {
        var entries: [Entry] = []
        try stream.readSubblock(1) { _ in
            let count = try stream.data.readVarUInt()
            for _ in 0 ..< count {
                try stream.readSubblock(0) { _ in
                    let key = try stream.data.readBytes(16)
                    let fileName = try stream.readLwwString(1)
                    var flags: LwwValue<[UInt8]>?
                    if try stream.hasSubblock(2) {
                        flags = try stream.readSubblock(2) { _ in
                            let timestamp = try stream.readId(1)
                            let value = try stream.readSubblock(2) { info in try stream.data.readBytes(info.size) }
                            return LwwValue(timestamp, value)
                        }
                    }
                    entries.append(Entry(key: key, fileName: fileName, flags: flags))
                }
            }
        }
        return ImageFilesBlock(entries: entries)
    }
}

/// One vertex of an image's mesh: a point on the page and a point in the image, from 0 to 1.
public struct ImageVertex: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var u: Float
    public var v: Float

    public init(x: Float, y: Float, u: Float, v: Float) {
        self.x = x
        self.y = y
        self.u = u
        self.v = v
    }
}

/// An image on a page: the key of its file, and the mesh that places it.
public struct ImageItem: Sendable {
    public var key: LwwValue<ImageKey>
    /// The ID in tag 2 of the value, whose meaning is unknown.
    public var unknownId: CrdtId?
    public var vertices: [ImageVertex]
    /// Triangles, three indices into `vertices` each.
    public var indices: [UInt32]

    public init(key: LwwValue<ImageKey>, unknownId: CrdtId? = nil, vertices: [ImageVertex], indices: [UInt32]) {
        self.key = key
        self.unknownId = unknownId
        self.vertices = vertices
        self.indices = indices
    }

    /// The smallest rectangle that holds the vertices, in page pixels from the page's center and top.
    public var bounds: (minX: Float, minY: Float, maxX: Float, maxY: Float)? {
        guard let first = vertices.first else { return nil }
        var b = (minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for v in vertices.dropFirst() {
            b = (min(b.minX, v.x), min(b.minY, v.y), max(b.maxX, v.x), max(b.maxY, v.y))
        }
        return b
    }
}

/// Block type 15: an image item in a group of the scene tree.
public struct SceneImageItemBlock: Block {
    public static let blockType = 0x0F
    /// The item type byte at the start of the value.
    public static let itemType: UInt8 = 0x07
    public var blockType: Int { Self.blockType }
    public var extraData: [UInt8] = []

    public var parentId: CrdtId
    public var item: CrdtSequenceItem<ImageItem?>

    public init(parentId: CrdtId, item: CrdtSequenceItem<ImageItem?>) {
        self.parentId = parentId
        self.item = item
    }

    static func fromStream(_ stream: TaggedBlockReader) throws -> any Block {
        let parentId = try stream.readId(1)
        let itemId = try stream.readId(2)
        let leftId = try stream.readId(3)
        let rightId = try stream.readId(4)
        let deletedLength = try stream.readInt(5)
        var value: ImageItem?
        if try stream.hasSubblock(6) {
            value = try stream.readSubblock(6) { _ in
                let itemType = try stream.data.readUInt8()
                guard itemType == Self.itemType else {
                    throw RMSceneError.assertion("item type \(itemType) != \(Self.itemType)")
                }
                return try imageFromStream(stream)
            }
        }
        return SceneImageItemBlock(
            parentId: parentId,
            item: CrdtSequenceItem(itemId, leftId, rightId, deletedLength, value)
        )
    }

    static func imageFromStream(_ stream: TaggedBlockReader) throws -> ImageItem {
        let key = try stream.readSubblock(1) { _ in
            let timestamp = try stream.readId(1)
            let bytes = try stream.readSubblock(2) { info in try stream.data.readBytes(info.size) }
            return LwwValue(timestamp, bytes)
        }
        let unknownId = stream.hasTag(2, .id) ? try stream.readId(2) : nil
        let vertices = try stream.readSubblock(3) { _ in
            let count = Int(try stream.data.readVarUInt())
            guard count % 4 == 0 else { throw RMSceneError.value("\(count) vertex values are not x, y, u, v") }
            return try (0 ..< count / 4).map { _ in
                ImageVertex(
                    x: try stream.data.readFloat32(),
                    y: try stream.data.readFloat32(),
                    u: try stream.data.readFloat32(),
                    v: try stream.data.readFloat32()
                )
            }
        }
        let indices = try stream.readSubblock(4) { _ in
            let count = Int(try stream.data.readVarUInt())
            return try (0 ..< count).map { _ in try stream.data.readUInt32() }
        }
        return ImageItem(key: key, unknownId: unknownId, vertices: vertices, indices: indices)
    }
}

// MARK: Writing, for invented test pages

extension ImageFilesBlock: WritableBlock {
    public func versionInfo() -> (UInt8, UInt8) { (3, 3) }  // as the owner's page had them

    public func toStream(_ writer: TaggedBlockWriter) throws {
        try writer.writeSubblock(1) {
            writer.data.writeVarUInt(UInt64(entries.count))
            for entry in entries {
                try writer.writeSubblock(0) {
                    writer.data.writeBytes(entry.key)
                    try writer.writeLwwString(1, entry.fileName)
                    if let flags = entry.flags {
                        try writer.writeSubblock(2) {
                            try writer.writeId(1, flags.timestamp)
                            writer.writeSubblock(2) { writer.data.writeBytes(flags.value) }
                        }
                    }
                }
            }
        }
    }
}

extension SceneImageItemBlock: WritableBlock {
    public func versionInfo() -> (UInt8, UInt8) { (2, 2) }  // as the owner's page had them

    public func toStream(_ writer: TaggedBlockWriter) throws {
        try writer.writeId(1, parentId)
        try writer.writeId(2, item.itemId)
        try writer.writeId(3, item.leftId)
        try writer.writeId(4, item.rightId)
        writer.writeInt(5, item.deletedLength)
        guard let image = item.value else { return }
        try writer.writeSubblock(6) {
            writer.data.writeUInt8(Self.itemType)
            try writer.writeSubblock(1) {
                try writer.writeId(1, image.key.timestamp)
                writer.writeSubblock(2) { writer.data.writeBytes(image.key.value) }
            }
            if let id = image.unknownId { try writer.writeId(2, id) }
            writer.writeSubblock(3) {
                writer.data.writeVarUInt(UInt64(image.vertices.count * 4))
                for v in image.vertices {
                    writer.data.writeFloat32(v.x)
                    writer.data.writeFloat32(v.y)
                    writer.data.writeFloat32(v.u)
                    writer.data.writeFloat32(v.v)
                }
            }
            writer.writeSubblock(4) {
                writer.data.writeVarUInt(UInt64(image.indices.count))
                for index in image.indices { writer.data.writeUInt32(index) }
            }
        }
    }
}
