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
