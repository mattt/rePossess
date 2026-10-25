// Ported from rmscene's tagged_block_writer.py and the writing half of
// tagged_block_common.py (https://github.com/ricklupton/rmscene, v0.8.0).
// rmscene is Copyright (c) 2023 Rick Lupton and is MIT licensed;
// see LICENSE-rmscene in this directory.
//
// Added for spike 4 (notebook writer).

import Foundation

/// Write basic values to a reMarkable v6 file stream.
public final class DataWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    /// Write the file header.
    public func writeHeader() {
        bytes += headerV6
    }

    /// Write a tag.
    public func writeTag(_ index: Int, _ tagType: TagType) {
        writeVarUInt(UInt64(index) << 4 | UInt64(tagType.rawValue))
    }

    public func writeBytes<C: Collection>(_ b: C) where C.Element == UInt8 {
        bytes += b
    }

    private func writeLittleEndian<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes += $0 }
    }

    public func writeBool(_ value: Bool) { bytes.append(value ? 1 : 0) }
    public func writeUInt8(_ value: UInt8) { bytes.append(value) }
    public func writeUInt16(_ value: UInt16) { writeLittleEndian(value) }
    public func writeUInt32(_ value: UInt32) { writeLittleEndian(value) }
    public func writeFloat32(_ value: Float) { writeLittleEndian(value.bitPattern) }
    public func writeFloat64(_ value: Double) { writeLittleEndian(value.bitPattern) }

    /// Write a varuint.
    public func writeVarUInt(_ value: UInt64) {
        var value = value
        while true {
            let toWrite = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 {
                bytes.append(toWrite | 0x80)
            } else {
                bytes.append(toWrite)
                break
            }
        }
    }

    /// Write a `CrdtId`.
    public func writeCrdtId(_ value: CrdtId) throws {
        // Based on ddvk's reader.go
        guard value.part1 < 1 << 8 else {
            throw RMSceneError.value("CrdtId too large: \(value)")
        }
        writeUInt8(UInt8(value.part1))
        writeVarUInt(value.part2)
    }
}

/// Write blocks and values to a reMarkable v6 file stream.
public final class TaggedBlockWriter {
    public private(set) var data = DataWriter()
    private var inBlock = false

    public init() {}

    /// The bytes written so far.
    public var bytes: [UInt8] { data.bytes }

    /// Write the file header.
    /// This should be the first call when starting to write a new file.
    public func writeHeader() {
        data.writeHeader()
    }

    // MARK: Simple values

    /// Write a tagged CRDT ID.
    public func writeId(_ index: Int, _ value: CrdtId) throws {
        data.writeTag(index, .id)
        try data.writeCrdtId(value)
    }

    /// Write a tagged bool.
    public func writeBool(_ index: Int, _ value: Bool) {
        data.writeTag(index, .byte1)
        data.writeBool(value)
    }

    /// Write a tagged byte as an unsigned integer.
    public func writeByte(_ index: Int, _ value: UInt8) {
        data.writeTag(index, .byte1)
        data.writeUInt8(value)
    }

    /// Write a tagged 4-byte unsigned integer.
    public func writeInt(_ index: Int, _ value: UInt32) {
        data.writeTag(index, .byte4)
        data.writeUInt32(value)
    }

    /// Write a tagged 4-byte float.
    public func writeFloat(_ index: Int, _ value: Float) {
        data.writeTag(index, .byte4)
        data.writeFloat32(value)
    }

    /// Write a tagged RGBA color packed as a little-endian uint32 (stored BGRA).
    public func writeColor(_ index: Int, _ value: RGBA) {
        writeInt(index, UInt32(value.b) | UInt32(value.g) << 8 | UInt32(value.r) << 16 | UInt32(value.a) << 24)
    }

    /// Write a tagged 8-byte double.
    public func writeDouble(_ index: Int, _ value: Double) {
        data.writeTag(index, .byte8)
        data.writeFloat64(value)
    }

    // MARK: Blocks

    /// Write a top-level block header and its content.
    ///
    /// Writes inside `body` are gathered, so that the block's length
    /// can be written before them.
    public func writeBlock(
        _ blockType: Int,
        minVersion: UInt8,
        currentVersion: UInt8,
        _ body: () throws -> Void
    ) throws {
        if inBlock {
            throw RMSceneError.unexpectedBlock("Already in a block")
        }
        let previous = data
        let blockData = DataWriter()
        data = blockData
        inBlock = true
        defer {
            data = previous
            inBlock = false
        }
        try body()

        previous.writeUInt32(UInt32(blockData.bytes.count))
        previous.writeUInt8(0)
        previous.writeUInt8(minVersion)
        previous.writeUInt8(currentVersion)
        previous.writeUInt8(UInt8(blockType))
        previous.writeBytes(blockData.bytes)
    }

    /// Write a subblock tag and length, then its content.
    ///
    /// Writes inside `body` are gathered, so that the subblock's length
    /// can be written before them.
    public func writeSubblock(_ index: Int, _ body: () throws -> Void) rethrows {
        let previous = data
        let subblockData = DataWriter()
        data = subblockData
        defer { data = previous }
        try body()

        previous.writeTag(index, .length4)
        previous.writeUInt32(UInt32(subblockData.bytes.count))
        previous.writeBytes(subblockData.bytes)
    }

    // MARK: Higher-level constructs

    /// Write a LWW bool.
    public func writeLwwBool(_ index: Int, _ value: LwwValue<Bool>) throws {
        try writeSubblock(index) {
            try writeId(1, value.timestamp)
            writeBool(2, value.value)
        }
    }

    /// Write a LWW byte.
    public func writeLwwByte(_ index: Int, _ value: LwwValue<UInt8>) throws {
        try writeSubblock(index) {
            try writeId(1, value.timestamp)
            writeByte(2, value.value)
        }
    }

    /// Write a LWW float.
    public func writeLwwFloat(_ index: Int, _ value: LwwValue<Float>) throws {
        try writeSubblock(index) {
            try writeId(1, value.timestamp)
            writeFloat(2, value.value)
        }
    }

    /// Write a LWW ID.
    public func writeLwwId(_ index: Int, _ value: LwwValue<CrdtId>) throws {
        try writeSubblock(index) {
            // rmscene: "XXX ddvk has these the other way round?"
            try writeId(1, value.timestamp)
            try writeId(2, value.value)
        }
    }

    /// Write a LWW string.
    public func writeLwwString(_ index: Int, _ value: LwwValue<String>) throws {
        try writeSubblock(index) {
            try writeId(1, value.timestamp)
            writeString(2, value.value)
        }
    }

    /// Write a standard string block.
    public func writeString(_ index: Int, _ value: String) {
        writeSubblock(index) {
            let b = Array(value.utf8)
            data.writeVarUInt(UInt64(b.count))
            data.writeBool(true)  // rmscene: "XXX not sure if this is right meaning?"
            data.writeBytes(b)
        }
    }

    /// Write a string block with formatting.
    public func writeStringWithFormat(_ index: Int, _ text: String, _ fmt: UInt32) {
        writeSubblock(index) {
            let b = Array(text.utf8)
            data.writeVarUInt(UInt64(b.count))
            data.writeBool(true)
            data.writeBytes(b)
            writeInt(2, fmt)
        }
    }

    /// Write a subblock containing two uint32.
    public func writeIntPair(_ index: Int, _ value: (UInt32, UInt32)) {
        writeSubblock(index) {
            data.writeUInt32(value.0)
            data.writeUInt32(value.1)
        }
    }
}
