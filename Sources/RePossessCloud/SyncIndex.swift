import Foundation

/// The schema version of an index file.
public enum SchemaVersion: Int, Sendable, Equatable {
    /// Schema 3: no info line; a document's hash is the hash of its file hashes.
    case v3 = 3
    /// Schema 4: an info line; every index's hash is the hash of its bytes.
    case v4 = 4
}

/// One line of an index: a file of a document, or a document in the root.
///
/// The line is `hash:type:id:subfiles:size`
/// (rmapi-js `src/raw.ts` lines 887-908).
public struct IndexEntry: Sendable, Equatable {
    /// The value of the type field.
    public enum Kind: String, Sendable, Equatable {
        /// `0`: a file, or any entry in a schema 4 index.
        case file = "0"
        /// `80000000`: a document or folder in a schema 3 root index.
        case collection = "80000000"
    }

    /// The SHA-256 hash of the file, or of the document's index.
    public var hash: String
    /// The type field.
    public var kind: Kind
    /// The file name, such as `<docid>.pdf`, or the document ID in the root.
    public var id: String
    /// The number of files in a document; 0 for a file.
    public var subfiles: Int
    /// The size in bytes, or the sum of a document's file sizes.
    public var size: Int

    /// Creates an entry.
    public init(hash: String, kind: Kind, id: String, subfiles: Int, size: Int) {
        self.hash = hash
        self.kind = kind
        self.id = id
        self.subfiles = subfiles
        self.size = size
    }

    init(line: Substring) throws {
        let fields = line.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 5,
            let kind = Kind(rawValue: String(fields[1])),
            let subfiles = Int(fields[3]),
            let size = Int(fields[4]),
            !fields[2].isEmpty
        else { throw CloudError.malformedIndex("bad entry line '\(line)'") }
        guard ContentHash.isValid(String(fields[0])) else {
            throw CloudError.invalidHash(String(fields[0]))
        }
        self.init(hash: String(fields[0]), kind: kind, id: String(fields[2]), subfiles: subfiles, size: size)
    }
}

/// An index file: the root index, or a document's index.
///
/// The server stores each index as a blob named `<id>.docSchema`,
/// or `root.docSchema` for the root.
public struct SyncIndex: Sendable, Equatable {
    /// The schema version, from the first line.
    public var schema: SchemaVersion
    /// The ID from the schema 4 info line: `.` for the root, or the document ID.
    public var infoID: String?
    /// The total size from the schema 4 info line.
    public var infoSize: Int?
    /// The entries, in file order.
    public var entries: [IndexEntry]

    /// Creates an index from its parts, without sorting.
    public init(schema: SchemaVersion, infoID: String? = nil, infoSize: Int? = nil, entries: [IndexEntry]) {
        self.schema = schema
        self.infoID = infoID
        self.infoSize = infoSize
        self.entries = entries
    }

    /// Parses an index file (rmapi-js `src/raw.ts` lines 1092-1122).
    public init(parsing data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CloudError.malformedIndex("not UTF-8")
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        guard let first = lines.first else { throw CloudError.malformedIndex("empty") }
        switch first {
        case "3":
            self.init(schema: .v3, entries: try lines.dropFirst().map(IndexEntry.init(line:)))
        case "4":
            guard lines.count >= 2 else { throw CloudError.malformedIndex("missing info line") }
            let info = lines[1].split(separator: ":", omittingEmptySubsequences: false)
            guard info.count == 4, info[0] == "0", let count = Int(info[2]), let size = Int(info[3]) else {
                throw CloudError.malformedIndex("bad info line '\(lines[1])'")
            }
            let entries = try lines.dropFirst(2).map(IndexEntry.init(line:))
            guard entries.count == count else {
                throw CloudError.malformedIndex("info line counts \(count) entries, found \(entries.count)")
            }
            self.init(schema: .v4, infoID: String(info[1]), infoSize: size, entries: entries)
        default:
            throw CloudError.malformedIndex("unsupported schema '\(first)'")
        }
    }

    /// Makes an index to upload. Phase 3 uploads; phase 1 uses this only in tests.
    ///
    /// It sorts the entries by the bytes of their IDs,
    /// which the server requires of the root since 2026-08-17 (ddvk/rmapi issue 75).
    /// rmapi-js sorts with `localeCompare` (`src/raw.ts` line 1459);
    /// ddvk/rmapi sorts by Go string order, which is byte order.
    /// The two agree on lowercase UUIDs and on the file names seen so far.
    /// In schema 4, every entry's type is `0` and an info line gives the count and total size
    /// (rmapi-js `src/raw.ts` lines 1462-1470).
    ///
    /// - Parameters:
    ///   - id: The document ID, or `root` for the root index.
    ///   - entries: The entries, in any order.
    ///   - schema: The schema to write.
    static func make(id: String, entries: [IndexEntry], schema: SchemaVersion) -> SyncIndex {
        let sorted = entries.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
        switch schema {
        case .v3:
            return SyncIndex(schema: .v3, entries: sorted)
        case .v4:
            let normalized = sorted.map { entry -> IndexEntry in
                var entry = entry
                entry.kind = .file
                return entry
            }
            return SyncIndex(
                schema: .v4,
                infoID: id == "root" ? "." : id,
                infoSize: sorted.reduce(0) { $0 + $1.size },
                entries: normalized
            )
        }
    }

    /// The bytes of the index file, with a newline after every line.
    public func serialized() -> Data {
        var text = "\(schema.rawValue)\n"
        if schema == .v4 {
            text += "0:\(infoID ?? "."):\(entries.count):\(infoSize ?? 0)\n"
        }
        for entry in entries {
            text += "\(entry.hash):\(entry.kind.rawValue):\(entry.id):\(entry.subfiles):\(entry.size)\n"
        }
        return Data(text.utf8)
    }

    /// The hash under which the server stores this index.
    ///
    /// Schema 4: the SHA-256 of the file's bytes.
    /// Schema 3: the SHA-256 of the entries' 32-byte hashes, concatenated in order
    /// (rmapi-js `src/raw.ts` lines 1474-1487).
    public func hash() throws -> String {
        switch schema {
        case .v4:
            return ContentHash.sha256Hex(serialized())
        case .v3:
            var buffer = Data()
            for entry in entries {
                buffer.append(contentsOf: try ContentHash.bytes(entry.hash))
            }
            return ContentHash.sha256Hex(buffer)
        }
    }

    /// Whether the entries are in byte order of their IDs.
    public var isSorted: Bool {
        zip(entries, entries.dropFirst()).allSatisfy { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
    }

    /// The total size of the entries.
    public var totalSize: Int { entries.reduce(0) { $0 + $1.size } }
}
