import Foundation

/// An rmdoc archive: the zip file that the tablet's USB interface downloads.
///
/// It holds `<id>.content`, `<id>.metadata`, an optional `<id>.pagedata`,
/// an optional `<id>.pdf` or `<id>.epub`, and `<id>/<page-id>.rm` for each page with marks,
/// sometimes with `<id>/<page-id>-metadata.json` and image files.
public struct RmdocArchive: Sendable {
    /// The files, as named in the archive.
    public var files: [ArchiveFile]

    /// Reads an archive.
    public init(data: Data) throws {
        files = try readZip(data)
    }

    /// The document ID, from the name of the `.metadata` or `.content` file at the top level.
    public var documentID: String? {
        for file in files where !file.name.contains("/") {
            for suffix in [".metadata", ".content"] where file.name.hasSuffix(suffix) {
                let id = String(file.name.dropLast(suffix.count))
                if isValidItemID(id) { return id }
            }
        }
        return nil
    }

    /// Writes the files into a folder, renaming them from the archive's document ID to `id`
    /// when the two differ.
    ///
    /// - Returns: A ``DocumentFolder`` for the written files.
    @discardableResult
    public func unpack(into folder: URL, as id: String) throws -> DocumentFolder {
        guard isValidItemID(id) else { throw DocumentError.invalidID(id) }
        let archiveID = documentID
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            var name = file.name
            if let archiveID, archiveID != id, name.hasPrefix(archiveID) {
                name = id + name.dropFirst(archiveID.count)
            }
            guard isSafeArchivePath(name) else { throw ZipError.unsafePath(name) }
            let url = folder.appending(path: name)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url, options: .atomic)
        }
        return try DocumentFolder(id: id, url: folder)
    }
}
