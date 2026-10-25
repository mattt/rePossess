// Ported from rmscene's tagged_block_reader.py
// (https://github.com/ricklupton/rmscene, v0.8.0).
// rmscene is Copyright (c) 2023 Rick Lupton and is MIT licensed;
// see LICENSE-rmscene in this directory.
//
// rePossess departs from rmscene here in one way:
// every optional field check stops at the end of the innermost enclosing
// block or subblock. rmscene checks for an optional tag without regard
// to the block's end, so the next block's length can read as a tag.

import Foundation

/// Base class for block and subblock info.
public class BlockInfo {
    public let offset: Int
    public let size: Int
    public var extraData: [UInt8] = []

    init(offset: Int, size: Int) {
        self.offset = offset
        self.size = size
    }
}

/// Top-level block info.
public final class MainBlockInfo: BlockInfo {
    public let blockType: Int
    public let minVersion: Int
    public let currentVersion: Int

    init(offset: Int, size: Int, blockType: Int, minVersion: Int, currentVersion: Int) {
        self.blockType = blockType
        self.minVersion = minVersion
        self.currentVersion = currentVersion
        super.init(offset: offset, size: size)
    }
}

/// Sub-block info.
public final class SubBlockInfo: BlockInfo {}

/// Read blocks and values from a reMarkable v6 file stream.
public final class TaggedBlockReader {
    public let data: DataStream
    public internal(set) var currentBlock: MainBlockInfo?
    /// The end offsets of the blocks and subblocks being read, innermost last.
    private var ends: [Int] = []

    public init(_ bytes: [UInt8]) {
        self.data = DataStream(bytes)
    }

    public func readHeader() throws { try data.readHeader() }

    // MARK: Read simple values

    public func readId(_ index: Int) throws -> CrdtId {
        try data.readTag(index, .id)
        return try data.readCrdtId()
    }

    public func readBool(_ index: Int) throws -> Bool {
        try data.readTag(index, .byte1)
        return try data.readBool()
    }

    public func readByte(_ index: Int) throws -> UInt8 {
        try data.readTag(index, .byte1)
        return try data.readUInt8()
    }

    public func readInt(_ index: Int) throws -> UInt32 {
        try data.readTag(index, .byte4)
        return try data.readUInt32()
    }

    public func readFloat(_ index: Int) throws -> Float {
        try data.readTag(index, .byte4)
        return try data.readFloat32()
    }

    public func readDouble(_ index: Int) throws -> Double {
        try data.readTag(index, .byte8)
        return try data.readFloat64()
    }

    // MARK: Optional variants

    /// The bytes left in the innermost block or subblock being read.
    public func bytesRemainingInEnclosing() -> Int {
        guard let end = ends.last else { return data.bytes.count - data.tell() }
        return end - data.tell()
    }

    /// Check that a tag with `index` and `type`, and its value, come next
    /// and end within the innermost block or subblock, without advancing the stream.
    ///
    /// This is rePossess's departure from rmscene's `check_tag`.
    public func hasTag(_ index: Int, _ type: TagType) -> Bool {
        let remaining = bytesRemainingInEnclosing()
        guard remaining > 0 else { return false }
        let start = data.tell()
        defer { data.seek(start) }
        guard let (i, t) = try? data.readTagValues(), i == index, t == type else { return false }
        let valueSize: Int =
            switch type {
            case .byte1: 1
            case .byte4, .length4: 4
            case .byte8: 8
            case .id: 2
            }
        return data.tell() - start + valueSize <= remaining
    }

    /// Read an optional tagged integer, or return `nil` when it is not next in this block.
    public func readIntOptional(_ index: Int) throws -> UInt32? {
        guard hasTag(index, .byte4) else { return nil }
        return try readInt(index)
    }

    /// Read a tagged RGBA color packed as a little-endian uint32 (stored BGRA).
    public func readColorOptional(_ index: Int) throws -> RGBA? {
        guard hasTag(index, .byte4) else { return nil }
        let packed = try readInt(index)
        return RGBA(
            r: UInt8((packed >> 16) & 0xFF),
            g: UInt8((packed >> 8) & 0xFF),
            b: UInt8(packed & 0xFF),
            a: UInt8((packed >> 24) & 0xFF)
        )
    }

    // MARK: Blocks

    /// Read a top-level block header, run `body`, and check the length read.
    /// `body` gets `nil` when no block remains.
    public func readBlock<T>(_ body: (MainBlockInfo?) throws -> T) throws -> T {
        if currentBlock != nil {
            throw RMSceneError.unexpectedBlock("Already in a block")
        }
        let blockLength: UInt32
        do {
            blockLength = try data.readUInt32()
        } catch RMSceneError.eof {
            return try body(nil)  // no more blocks to read
        }
        let unknown = try data.readUInt8()
        let minVersion = try data.readUInt8()
        let currentVersion = try data.readUInt8()
        let blockType = try data.readUInt8()
        guard unknown == 0, minVersion <= currentVersion else {
            throw RMSceneError.assertion("Bad block header")
        }
        let info = MainBlockInfo(
            offset: data.tell(),
            size: Int(blockLength),
            blockType: Int(blockType),
            minVersion: Int(minVersion),
            currentVersion: Int(currentVersion)
        )
        currentBlock = info
        ends.append(info.offset + info.size)
        defer {
            ends.removeLast()
            currentBlock = nil
        }
        let result = try body(info)
        try checkPosition(info)
        return result
    }

    public func bytesRemainingInBlock() throws -> Int {
        guard let block = currentBlock else { throw RMSceneError.value("Not in a block") }
        return block.offset + block.size - data.tell()
    }

    /// Read a subblock length, run `body`, and check the length read.
    public func readSubblock<T>(_ index: Int, _ body: (SubBlockInfo) throws -> T) throws -> T {
        try data.readTag(index, .length4)
        let length = try data.readUInt32()
        let subblock = SubBlockInfo(offset: data.tell(), size: Int(length))
        ends.append(subblock.offset + subblock.size)
        defer { ends.removeLast() }
        let result = try body(subblock)
        try checkPosition(subblock)
        return result
    }

    @discardableResult
    public func readSubblock(_ index: Int) throws -> SubBlockInfo {
        try readSubblock(index) { $0 }
    }

    /// Check if a subblock with the given index is next in the enclosing block.
    public func hasSubblock(_ index: Int) throws -> Bool {
        // At the end of the block, the next block's length could match the tag.
        hasTag(index, .length4)
    }

    func checkPosition(_ info: BlockInfo) throws {
        let end = info.offset + info.size
        let i1 = data.tell()
        if i1 > end {
            throw RMSceneError.blockOverflow(
                "Block starting at \(info.offset), length \(info.size), read up to \(i1)"
            )
        }
        if i1 < end {
            // Some data has not been read: keep the rest.
            info.extraData = try data.readBytes(end - i1)
        }
    }

    // MARK: Higher level constructs

    public func readLwwBool(_ index: Int) throws -> LwwValue<Bool> {
        try readSubblock(index) { _ in LwwValue(try readId(1), try readBool(2)) }
    }

    public func readLwwByte(_ index: Int) throws -> LwwValue<UInt8> {
        try readSubblock(index) { _ in LwwValue(try readId(1), try readByte(2)) }
    }

    public func readLwwFloat(_ index: Int) throws -> LwwValue<Float> {
        try readSubblock(index) { _ in LwwValue(try readId(1), try readFloat(2)) }
    }

    public func readLwwId(_ index: Int) throws -> LwwValue<CrdtId> {
        try readSubblock(index) { _ in LwwValue(try readId(1), try readId(2)) }
    }

    public func readLwwString(_ index: Int) throws -> LwwValue<String> {
        try readSubblock(index) { _ in LwwValue(try readId(1), try readString(2)) }
    }

    private func readStringBody(_ info: SubBlockInfo) throws -> String {
        let stringLength = try data.readVarUInt()
        let isASCII = try data.readBool()
        guard isASCII, stringLength + 2 <= UInt64(info.size) else {
            throw RMSceneError.assertion("Bad string header")
        }
        let b = try data.readBytes(Int(stringLength))
        guard let string = String(validating: b, as: UTF8.self) else {
            throw RMSceneError.value("String is not UTF-8")
        }
        return string
    }

    /// Read a standard string block.
    public func readString(_ index: Int) throws -> String {
        try readSubblock(index) { try readStringBody($0) }
    }

    /// Read a string block with formatting.
    public func readStringWithFormat(_ index: Int) throws -> (String, UInt32?) {
        try readSubblock(index) { info in
            let string = try readStringBody(info)
            let fmt = hasTag(2, .byte4) ? try readInt(2) : nil
            return (string, fmt)
        }
    }

    /// Read a subblock containing two uint32.
    public func readIntPair(_ index: Int) throws -> (UInt32, UInt32) {
        try readSubblock(index) { _ in (try data.readUInt32(), try data.readUInt32()) }
    }
}
