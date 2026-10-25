import Foundation
import RePossessCloud
import RePossessFormat
import RePossessUSB

/// What one refresh did.
public struct RefreshReport: Sendable, Equatable {
    public var source: Source
    /// The documents that the source listed, outside the trash.
    public var listed = 0
    /// The documents downloaded because they were new or changed.
    public var downloaded = 0
    /// The documents whose version matched the library's.
    public var unchanged = 0
    /// The items removed because the source no longer lists them.
    public var removed = 0
    /// Documents that could not be read, with the reason.
    public var failed: [String] = []
    /// Requests sent to the tablet or the cloud.
    public var requests = 0
    /// Bytes downloaded.
    public var bytes = 0
    /// Seconds from start to end.
    public var seconds = 0.0
    /// The error that stopped the refresh before the end, if one did.
    public var stoppedBy: String?

    public init(source: Source) { self.source = source }
}

/// An error that prevents a refresh from starting.
public enum RefreshError: Error, CustomStringConvertible {
    /// Another refresh holds the library's lock.
    case busy

    public var description: String {
        switch self {
        case .busy: "another refresh is running on this library; try again when it ends"
        }
    }
}

extension Library {
    /// Holds the library's refresh lock, across processes, while `body` runs.
    private func withRefreshLock<T>(_ body: () async throws -> T) async throws -> T {
        let path = root.appending(path: "refresh.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw RefreshError.busy }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }

    /// Writes files into a new folder and moves it into place as the document's folder.
    private func replaceFolder(id: String, files: [(name: String, data: Data)]) throws -> DocumentFolder {
        let manager = FileManager.default
        let incoming = documentsURL.appending(path: ".incoming-\(id)-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: incoming) }
        for file in files {
            guard isSafeArchivePath(file.name) else { throw ZipError.unsafePath(file.name) }
            let url = incoming.appending(path: file.name)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
        try manager.createDirectory(at: incoming, withIntermediateDirectories: true)
        let target = documentsURL.appending(path: id, directoryHint: .isDirectory)
        if manager.fileExists(atPath: target.path) {
            _ = try manager.replaceItemAt(target, withItemAt: incoming)
        } else {
            try manager.moveItem(at: incoming, to: target)
        }
        return try folder(for: id)
    }

    private func recordFailure(id: String, name: String, parent: String, source: Source, error: any Error) {
        try? storeItem(
            id: id,
            kind: .document,
            name: name,
            parent: parent,
            trashed: false,
            source: source,
            usbModified: nil,
            cloudHash: nil,
            error: "\(error)"
        )
    }

    // MARK: USB

    /// Refreshes the library from the tablet over USB.
    ///
    /// It lists every folder, then downloads the rmdoc of each document
    /// whose `ModifiedClient` differs from the library's, one request at a time.
    /// After a complete listing, it removes items that the tablet no longer lists.
    /// A timeout stops the refresh: what was downloaded stays, and the report says why it stopped.
    public func refreshUSB(
        client: USBClient = USBClient(),
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> RefreshReport {
        try await withRefreshLock {
            let start = Date()
            var report = RefreshReport(source: .usb)
            let finish: (String?) -> Void = { error in
                try? self.setState(
                    [
                        "usb.last_error": error ?? "",
                        "usb.last_refresh": error == nil ? String(Date().timeIntervalSince1970) : nil,
                    ].compactMapValues { $0 }
                )
            }

            let items: [USBItem]
            do {
                items = try await client.listAll()
            } catch {
                report.requests = await client.requested.count
                finish("\(error)")
                throw error
            }
            let documents = items.filter { !$0.isFolder && isValidItemID($0.id) }
            report.listed = documents.count
            progress("The tablet lists \(documents.count) documents in \(items.count - documents.count) folders.")

            for folder in items where folder.isFolder && isValidItemID(folder.id) {
                try storeItem(
                    id: folder.id,
                    kind: .folder,
                    name: folder.visibleName,
                    parent: folder.parent,
                    trashed: false,
                    source: .usb,
                    usbModified: folder.modifiedClient,
                    cloudHash: nil
                )
            }

            let stored = try versions()
            for (i, item) in documents.enumerated() {
                let known = stored[item.id]
                if let known, known.error == nil, known.usbModified != nil, known.usbModified == item.modifiedClient,
                    FileManager.default.fileExists(atPath: documentsURL.appending(path: item.id).path)
                {
                    report.unchanged += 1
                    continue
                }
                progress("Downloading document \(i + 1) of \(documents.count).")
                let data: Data
                do {
                    data = try await client.rmdoc(id: item.id)
                } catch let error as USBError {
                    if case .http = error {
                        report.failed.append("\(item.id): \(error)")
                        recordFailure(
                            id: item.id,
                            name: item.visibleName,
                            parent: item.parent,
                            source: .usb,
                            error: error
                        )
                        continue
                    }
                    report.stoppedBy = "\(error)"
                    break
                }
                report.bytes += data.count
                do {
                    let archive = try RmdocArchive(data: data)
                    let folder = try replaceFolder(
                        id: item.id,
                        files: archive.files.map { file in
                            var name = file.name
                            if let archiveID = archive.documentID, archiveID != item.id, name.hasPrefix(archiveID) {
                                name = item.id + name.dropFirst(archiveID.count)
                            }
                            return (name, file.data)
                        }
                    )
                    try store(
                        indexDocument(folder),
                        id: item.id,
                        source: .usb,
                        usbModified: item.modifiedClient,
                        cloudHash: nil
                    )
                    report.downloaded += 1
                } catch {
                    report.failed.append("\(item.id): \(error)")
                    recordFailure(id: item.id, name: item.visibleName, parent: item.parent, source: .usb, error: error)
                }
            }
            report.requests = await client.requested.count

            if report.stoppedBy == nil {
                let listed = Set(items.map(\.id))
                let gone = try versions().keys.filter { !listed.contains($0) }
                try remove(ids: gone)
                report.removed = gone.count
            }
            finish(report.stoppedBy)
            report.seconds = Date().timeIntervalSince(start)
            return report
        }
    }

    // MARK: Cloud

    /// Refreshes the library from reMarkable's cloud.
    ///
    /// It reads the root; when the root hash is the one from the last refresh, it stops there.
    /// Otherwise it reads the root index and, for each document whose index hash changed,
    /// the document's index and the files whose hashes differ from the files in the mirror.
    /// It removes items that the root no longer lists, and skips items in the trash.
    public func refreshCloud(
        session: CloudSession = CloudSession(),
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> RefreshReport {
        try await withRefreshLock {
            let start = Date()
            var report = RefreshReport(source: .cloud)
            do {
                try await refreshCloud(session: session, report: &report, progress: progress)
                try setState([
                    "cloud.last_error": report.stoppedBy ?? "",
                    "cloud.last_refresh": String(Date().timeIntervalSince1970),
                ])
                report.seconds = Date().timeIntervalSince(start)
                return report
            } catch {
                try? setState(["cloud.last_error": "\(error)"])
                throw error
            }
        }
    }

    private func refreshCloud(
        session: CloudSession,
        report: inout RefreshReport,
        progress: @Sendable (String) -> Void
    ) async throws {
        let client = try await session.client()
        report.requests += 1
        let root = try await client.root()
        report.requests += 1
        let state = try stateValues()
        let stored = try versions()
        let hasErrors = stored.values.contains { $0.error != nil }
        if root.hash == state["cloud.root_hash"], !hasErrors {
            report.listed = try status().documents
            report.unchanged = report.listed
            progress("The cloud root has not changed since the last refresh.")
            return
        }

        let rootIndex = try await client.index(id: "root", hash: root.hash)
        report.requests += 1
        guard rootIndex.hashMatches else {
            throw CloudError.hashMismatch(expected: root.hash, actual: (try? rootIndex.index.hash()) ?? "")
        }
        let entries = rootIndex.index.entries.filter { isValidItemID($0.id) }
        progress("The cloud root lists \(entries.count) items.")

        for (i, entry) in entries.enumerated() {
            if let known = stored[entry.id], known.cloudHash == entry.hash, known.error == nil {
                if known.kind == ItemKind.document.rawValue { report.unchanged += 1 }
                continue
            }
            progress("Reading item \(i + 1) of \(entries.count).")
            do {
                try await refreshCloudItem(entry, client: client, report: &report)
            } catch let error as CloudError {
                if case .unauthorized = error { throw error }
                report.failed.append("\(entry.id): \(error)")
                recordFailure(id: entry.id, name: "", parent: "", source: .cloud, error: error)
            } catch {
                report.failed.append("\(entry.id): \(error)")
                recordFailure(id: entry.id, name: "", parent: "", source: .cloud, error: error)
            }
        }

        let listed = Set(entries.map(\.id))
        let gone = try versions().keys.filter { !listed.contains($0) }
        try remove(ids: gone)
        report.removed = gone.count
        report.listed = try status().documents
        try setState(["cloud.root_hash": root.hash, "cloud.generation": String(root.generation)])
    }

    private func refreshCloudItem(_ entry: IndexEntry, client: CloudClient, report: inout RefreshReport) async throws {
        let id = entry.id
        let fetched = try await client.index(id: id, hash: entry.hash)
        report.requests += 1
        guard fetched.hashMatches else {
            throw CloudError.hashMismatch(expected: entry.hash, actual: (try? fetched.index.hash()) ?? "")
        }
        let files = fetched.index.entries
        guard let metadataEntry = files.first(where: { $0.id == "\(id).metadata" }) else {
            throw DocumentError.missing("\(id).metadata")
        }
        let metadataData = try await client.file(metadataEntry)
        report.requests += 1
        report.bytes += metadataData.count
        let metadata = try DocumentMetadata(parsing: metadataData)
        if metadata.isTrashed || metadata.kind == .folder {
            try storeItem(
                id: id,
                kind: metadata.kind,
                name: metadata.visibleName,
                parent: metadata.parent,
                trashed: metadata.isTrashed,
                source: .cloud,
                usbModified: nil,
                cloudHash: entry.hash
            )
            if metadata.isTrashed { try? FileManager.default.removeItem(at: documentsURL.appending(path: id)) }
            return
        }

        var downloaded: [(name: String, data: Data)] = [(metadataEntry.id, metadataData)]
        let current = documentsURL.appending(path: id, directoryHint: .isDirectory)
        for file in files where file.id != metadataEntry.id {
            guard isSafeArchivePath(file.id) else { throw ZipError.unsafePath(file.id) }
            let local = current.appending(path: file.id)
            if let data = try? Data(contentsOf: local), ContentHash.sha256Hex(data) == file.hash {
                downloaded.append((file.id, data))
                continue
            }
            let data = try await client.file(file)
            report.requests += 1
            report.bytes += data.count
            downloaded.append((file.id, data))
        }
        let folder = try replaceFolder(id: id, files: downloaded)
        try store(indexDocument(folder), id: id, source: .cloud, usbModified: nil, cloudHash: entry.hash)
        report.downloaded += 1
    }
}
