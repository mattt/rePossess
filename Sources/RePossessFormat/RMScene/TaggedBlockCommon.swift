// Ported from rmscene's tagged_block_common.py
// (https://github.com/ricklupton/rmscene, v0.8.0).
// rmscene is Copyright (c) 2023 Rick Lupton and is MIT licensed;
// see LICENSE-rmscene in this directory.

import Foundation

/// The header that starts every version 6 `.rm` file.
public let headerV6 = Array("reMarkable .lines file, version=6          ".utf8)

/// Tag type representing the type of following data.
public enum TagType: UInt8, Sendable {
    case id = 0xF
    case length4 = 0xC
    case byte8 = 0x8
    case byte4 = 0x4
    case byte1 = 0x1
}

/// Errors, grouped as rmscene's Python exception types are,
/// because rmscene catches some kinds and not others.
public enum RMSceneError: Error, Equatable, Sendable {
    /// Python `EOFError`.
    case eof
    /// rmscene's `UnexpectedBlockError`: unexpected tag or index in block stream.
    case unexpectedBlock(String)
    /// Python `ValueError`, including enum lookups and UTF-8 decoding.
    case value(String)
    /// rmscene's `BlockOverflowError`: read past end of block.
    case blockOverflow(String)
    /// Python `AssertionError` from an `assert` in rmscene.
    case assertion(String)
}

/// An identifier or timestamp.
public struct CrdtId: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var part1: UInt64
    public var part2: UInt64

    public init(_ part1: UInt64, _ part2: UInt64) {
        self.part1 = part1
        self.part2 = part2
    }

    public static func < (a: CrdtId, b: CrdtId) -> Bool {
        (a.part1, a.part2) < (b.part1, b.part2)
    }

    public var description: String { "\(part1):\(part2)" }
}

/// Read basic values from a reMarkable v6 file stream.
public final class DataStream {
    let bytes: [UInt8]
    var position = 0

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public func tell() -> Int { position }

    func seek(_ offset: Int) { position = offset }

    /// Read the file header.
    public func readHeader() throws {
        let header = try readBytes(headerV6.count)
        if header != headerV6 {
            throw RMSceneError.value("Wrong header")
        }
    }

    /// Check that `index` and `type` are next, without advancing the stream.
    public func checkTag(_ expectedIndex: Int, _ expectedType: TagType) -> Bool {
        let pos = position
        defer { position = pos }
        guard let (index, tagType) = try? readTagValues() else { return false }
        return index == expectedIndex && tagType == expectedType
    }

    /// Read a tag, and rewind and throw if it is not the one expected.
    @discardableResult
    public func readTag(_ expectedIndex: Int, _ expectedType: TagType) throws -> (Int, TagType) {
        let pos = position
        let (index, tagType) = try readTagValues()
        if index != expectedIndex {
            position = pos
            throw RMSceneError.unexpectedBlock(
                "Expected index \(expectedIndex), got \(index), at position \(position)"
            )
        }
        if tagType != expectedType {
            position = pos
            throw RMSceneError.unexpectedBlock(
                "Expected tag type \(expectedType), got \(tagType) at position \(position)"
            )
        }
        return (index, tagType)
    }

    func readTagValues() throws -> (Int, TagType) {
        let x = try readVarUInt()
        let index = Int(truncatingIfNeeded: x >> 4)
        guard let tagType = TagType(rawValue: UInt8(x & 0xF)) else {
            throw RMSceneError.value(
                "Bad tag type 0x\(String(x & 0xF, radix: 16, uppercase: true)) at position \(position)"
            )
        }
        return (index, tagType)
    }

    /// Read `n` bytes, throwing `eof` if there are not enough.
    public func readBytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, position + n <= bytes.count else {
            position = bytes.count  // Python's read consumes what remains
            throw RMSceneError.eof
        }
        defer { position += n }
        return Array(bytes[position ..< position + n])
    }

    private func readLittleEndian<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let b = try readBytes(MemoryLayout<T>.size)
        var value: T = 0
        for (i, byte) in b.enumerated() {
            value |= T(byte) << (8 * i)
        }
        return value
    }

    /// Python's `struct` reads any nonzero byte as `True`.
    public func readBool() throws -> Bool { try readUInt8() != 0 }
    public func readUInt8() throws -> UInt8 { try readBytes(1)[0] }
    public func readUInt16() throws -> UInt16 { try readLittleEndian(UInt16.self) }
    public func readUInt32() throws -> UInt32 { try readLittleEndian(UInt32.self) }
    public func readFloat32() throws -> Float { Float(bitPattern: try readUInt32()) }
    public func readFloat64() throws -> Double {
        Double(bitPattern: try readLittleEndian(UInt64.self))
    }

    /// Read a varuint.
    /// Python's integers have no limit; this throws past 64 bits.
    public func readVarUInt() throws -> UInt64 {
        var shift: UInt64 = 0
        var result: UInt64 = 0
        while true {
            let i = try readUInt8()
            if shift >= 64 && i & 0x7F != 0 {
                throw RMSceneError.value("varuint wider than 64 bits")
            }
            if shift < 64 { result |= UInt64(i & 0x7F) << shift }
            shift += 7
            if i & 0x80 == 0 { break }
        }
        return result
    }

    public func readCrdtId() throws -> CrdtId {
        // Based on ddvk's reader.go
        let part1 = try readUInt8()
        let part2 = try readVarUInt()
        return CrdtId(UInt64(part1), part2)
    }
}

/// Container for a last-write-wins value.
public struct LwwValue<T> {
    public var timestamp: CrdtId
    public var value: T

    public init(_ timestamp: CrdtId, _ value: T) {
        self.timestamp = timestamp
        self.value = value
    }
}

extension LwwValue: Equatable where T: Equatable {}
extension LwwValue: Sendable where T: Sendable {}
