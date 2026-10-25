import Compression
import Foundation

/// One file in a zip archive.
public struct ArchiveFile: Sendable, Equatable {
    /// The path inside the archive, such as `<id>/<page-id>.rm`.
    public var name: String
    /// The uncompressed bytes.
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// An error in a zip archive.
public enum ZipError: Error, Equatable, CustomStringConvertible {
    case notAZip
    case truncated(String)
    case unsupportedMethod(name: String, method: UInt16)
    case zip64(String)
    case badCRC(String)
    case unsafePath(String)
    case inflateFailed(String)

    public var description: String {
        switch self {
        case .notAZip: "not a zip archive: no end of central directory record"
        case .truncated(let what): "the zip archive is truncated: \(what)"
        case .unsupportedMethod(let name, let method): "\(name) uses compression method \(method)"
        case .zip64(let name): "\(name) needs Zip64, which rePossess does not read"
        case .badCRC(let name): "\(name) does not match its CRC-32"
        case .unsafePath(let name): "unsafe path in the archive: \(name)"
        case .inflateFailed(let name): "\(name) could not be inflated"
        }
    }
}

/// Reads the files of a zip archive, such as an rmdoc download.
///
/// The tablet's exports deflate every entry (checked on 2026-10-25 with
/// the Paper Pure, software 3.29.0.153); spike 4's writer stores them.
/// This reads both, from the central directory, and checks each file's CRC-32.
/// It refuses absolute paths and `..` components, because the library unpacks archives to disk.
public func readZip(_ data: Data) throws -> [ArchiveFile] {
    let bytes = [UInt8](data)
    func u16(_ at: Int) throws -> UInt16 {
        guard at >= 0, at + 2 <= bytes.count else { throw ZipError.truncated("field at \(at)") }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }
    func u32(_ at: Int) throws -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { throw ZipError.truncated("field at \(at)") }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16
            | UInt32(bytes[at + 3]) << 24
    }

    // The end of central directory record is at least 22 bytes, followed by a comment of up to 65,535.
    guard bytes.count >= 22 else { throw ZipError.notAZip }
    var eocd = -1
    var i = bytes.count - 22
    let lowest = max(0, bytes.count - 22 - 65_535)
    while i >= lowest {
        if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
            eocd = i
            break
        }
        i -= 1
    }
    guard eocd >= 0 else { throw ZipError.notAZip }
    let count = Int(try u16(eocd + 10))
    let centralOffset = Int(try u32(eocd + 16))

    var files: [ArchiveFile] = []
    var at = centralOffset
    for _ in 0 ..< count {
        guard try u32(at) == 0x0201_4B50 else { throw ZipError.truncated("central directory entry") }
        let method = try u16(at + 10)
        let crc = try u32(at + 16)
        let compressedSize = try u32(at + 20)
        let size = try u32(at + 24)
        let nameLength = Int(try u16(at + 28))
        let extraLength = Int(try u16(at + 30))
        let commentLength = Int(try u16(at + 32))
        let localOffset = try u32(at + 42)
        guard at + 46 + nameLength <= bytes.count else { throw ZipError.truncated("entry name") }
        let name = String(decoding: bytes[(at + 46) ..< (at + 46 + nameLength)], as: UTF8.self)
        at += 46 + nameLength + extraLength + commentLength

        if compressedSize == 0xFFFF_FFFF || size == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
            throw ZipError.zip64(name)
        }
        if name.hasSuffix("/") { continue }  // a directory entry
        guard isSafeArchivePath(name) else { throw ZipError.unsafePath(name) }

        let local = Int(localOffset)
        guard try u32(local) == 0x0403_4B50 else { throw ZipError.truncated("local header of \(name)") }
        let dataStart = local + 30 + Int(try u16(local + 26)) + Int(try u16(local + 28))
        let dataEnd = dataStart + Int(compressedSize)
        guard dataEnd <= bytes.count else { throw ZipError.truncated(name) }
        let stored = Data(bytes[dataStart ..< dataEnd])

        let content: Data
        switch method {
        case 0:
            content = stored
        case 8:
            content = try inflate(stored, size: Int(size), name: name)
        default:
            throw ZipError.unsupportedMethod(name: name, method: method)
        }
        guard crc32(content) == crc else { throw ZipError.badCRC(name) }
        files.append(ArchiveFile(name: name, data: content))
    }
    return files
}

/// Whether a path from an archive is relative and has no `..` component.
public func isSafeArchivePath(_ name: String) -> Bool {
    guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
    return !name.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
}

/// Inflates raw DEFLATE data (RFC 1951) with the Compression framework,
/// whose `COMPRESSION_ZLIB` reads raw DEFLATE without a zlib header.
func inflate(_ data: Data, size: Int, name: String) throws -> Data {
    if size == 0 { return Data() }
    var output = Data(count: size)
    let written = output.withUnsafeMutableBytes { out in
        data.withUnsafeBytes { input in
            compression_decode_buffer(
                out.bindMemory(to: UInt8.self).baseAddress!,
                size,
                input.bindMemory(to: UInt8.self).baseAddress!,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
    }
    guard written == size else { throw ZipError.inflateFailed(name) }
    return output
}

/// A zip archive with stored entries, no directory entries, and no extra fields,
/// as spike 4's notebook writer makes them.
func storedZip(_ files: [ArchiveFile], modified: Date) -> Data {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: modified)
    let dosTime = UInt16(c.hour! << 11 | c.minute! << 5 | c.second! / 2)
    let dosDate = UInt16((c.year! - 1980) << 9 | c.month! << 5 | c.day!)

    var out: [UInt8] = []
    var central: [UInt8] = []
    func u16(_ v: UInt16, _ to: inout [UInt8]) { to += [UInt8(v & 0xFF), UInt8(v >> 8)] }
    func u32(_ v: UInt32, _ to: inout [UInt8]) {
        to += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
    }

    for file in files {
        let name = Array(file.name.utf8)
        let crc = crc32(file.data)
        let size = UInt32(file.data.count)
        let offset = UInt32(out.count)
        let flags: UInt16 = file.name.allSatisfy(\.isASCII) ? 0 : 0x0800

        u32(0x0403_4B50, &out)
        u16(10, &out)  // version needed: stored
        u16(flags, &out)
        u16(0, &out)  // method: stored
        u16(dosTime, &out)
        u16(dosDate, &out)
        u32(crc, &out)
        u32(size, &out)
        u32(size, &out)
        u16(UInt16(name.count), &out)
        u16(0, &out)
        out += name
        out += file.data

        u32(0x0201_4B50, &central)
        u16(20, &central)  // made by: MS-DOS, zip 2.0
        u16(10, &central)
        u16(flags, &central)
        u16(0, &central)
        u16(dosTime, &central)
        u16(dosDate, &central)
        u32(crc, &central)
        u32(size, &central)
        u32(size, &central)
        u16(UInt16(name.count), &central)
        u16(0, &central)  // extra
        u16(0, &central)  // comment
        u16(0, &central)  // disk
        u16(0, &central)  // internal attributes
        u32(0, &central)  // external attributes
        u32(offset, &central)
        central += name
    }

    let centralOffset = UInt32(out.count)
    out += central
    u32(0x0605_4B50, &out)
    u16(0, &out)
    u16(0, &out)
    u16(UInt16(files.count), &out)
    u16(UInt16(files.count), &out)
    u32(UInt32(central.count), &out)
    u32(centralOffset, &out)
    u16(0, &out)
    return Data(out)
}

private let crcTable: [UInt32] = (0 ..< 256).map { n in
    var c = UInt32(n)
    for _ in 0 ..< 8 {
        c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
    }
    return c
}

/// The zip CRC-32 (IEEE polynomial, reflected).
public func crc32<D: Sequence>(_ data: D) -> UInt32 where D.Element == UInt8 {
    var c: UInt32 = 0xFFFF_FFFF
    for byte in data {
        c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
    }
    return c ^ 0xFFFF_FFFF
}
