import CryptoKit
import Foundation

/// Content hashes for the sync store.
public enum ContentHash {
    /// Returns the SHA-256 digest of the data as 64 lowercase hex digits.
    ///
    /// Every blob is stored under this hash (rmapi-js `src/raw.ts` lines 870-877).
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns whether a string is 64 lowercase hex digits (rmapi-js `src/raw.ts` line 22).
    public static func isValid(_ hash: String) -> Bool {
        hash.utf8.count == 64
            && hash.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// Returns the 32 bytes that a hex hash encodes.
    static func bytes(_ hash: String) throws -> [UInt8] {
        guard isValid(hash) else { throw CloudError.invalidHash(hash) }
        var result: [UInt8] = []
        result.reserveCapacity(32)
        var iterator = hash.utf8.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            result.append(nibble(high) << 4 | nibble(low))
        }
        return result
    }

    private static func nibble(_ c: UInt8) -> UInt8 {
        c <= 0x39 ? c - 0x30 : c - 0x61 + 10
    }
}

/// The CRC-32C (Castagnoli) checksum, which the store checks on upload.
public enum CRC32C {
    private static let table: [UInt32] = (0 ..< 256).map { index in
        var crc = UInt32(index)
        for _ in 0 ..< 8 {
            crc = crc & 1 == 1 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1
        }
        return crc
    }

    /// Returns the checksum of the data.
    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Returns the value of the `x-goog-hash` header for an upload:
    /// `crc32c=` and the base64 of the checksum's four big-endian bytes
    /// (rmapi-js `src/raw.ts` lines 1273-1281).
    public static func googHash(_ data: Data) -> String {
        let crc = checksum(data)
        let bytes = Data([UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
        return "crc32c=" + bytes.base64EncodedString()
    }
}
