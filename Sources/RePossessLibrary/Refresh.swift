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
    /// The documents whose copy in the mirror is newer than the source's, and so were kept.
    public var keptNewer = 0
    /// Documents that could not be read, with the reason.
    public var failed: [String] = []
    /// Requests sent to the tablet or the cloud, including retries.
    public var requests = 0
    /// Bytes received from the tablet or the cloud, in response bodies.
    public var bytes = 0
    /// Files downloaded from the cloud, apart from indexes.
    public var filesDownloaded = 0
    /// Files that the cloud lists with the same hash as the mirror's copy, which were not downloaded.
    public var filesReused = 0
    /// The size of the reused files.
    public var bytesReused = 0
    /// The tablet's PDF exports downloaded, for documents with typed text.
    public var exportsDownloaded = 0
    /// The exports that the tablet did not give or that could not be read.
    public var exportsFailed = 0
    /// Requests sent again after HTTP 429 or a 5xx status.
    public var retries = 0
    /// Pauses for the cloud's rate limits.
    public var waits = 0
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
    /// Refreshes and pushes share it, so that one process at a time talks to the tablet and the cloud.
    func withRefreshLock<T>(_ body: () async throws -> T) async throws -> T {
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
        try? markFailed(id: id, name: name, parent: parent, source: source, error: "\(error)")
    }

    /// Records a refresh that finished: its time, and no error.
    func recordRefreshSuccess(_ source: Source, at date: Date = Date()) throws {
        try setState([
            "\(source.rawValue).last_refresh": String(date.timeIntervalSince1970),
            "\(source.rawValue).last_error": "",
            "\(source.rawValue).last_error_at": "",
        ])
    }

    /// Records a refresh that failed or stopped early, and keeps the time of the last success.
    func recordRefreshFailure(_ source: Source, _ message: String, at date: Date = Date()) throws {
        try setState([
            "\(source.rawValue).last_error": message,
            "\(source.rawValue).last_error_at": String(date.timeIntervalSince1970),
        ])
    }

    // MARK: USB

    /// Refreshes the library from the tablet over USB.
    ///
    /// It lists every folder, then downloads the rmdoc of each document
    /// whose `ModifiedClient` differs from the library's, one request at a time.
    /// After a complete listing, it removes items that the tablet no longer lists.
    /// A timeout stops the refresh: what was downloaded stays, and the report says why it stopped.
    ///
    /// With `exports`, it then downloads the tablet's own PDF of each document with typed text
    /// whose export is missing or older than the mirror's copy (see ``TabletExport``).
    /// That covers every document whose typed text changed, and also documents
    /// whose only change was ink, because an anchored stroke moves with the text.
    public func refreshUSB(
        client: USBClient = USBClient(),
        exports: Bool = true,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> RefreshReport {
        try await withRefreshLock {
            let start = Date()
            var report = RefreshReport(source: .usb)
            // Phase 1 built this state with `compactMapValues`, which kept a `nil` as `.some(nil)`
            // and so wrote NULL over the time of the last success whenever a refresh failed.
            let finish: (String?) -> Void = { error in
                if let error {
                    try? self.recordRefreshFailure(.usb, error)
                } else {
                    try? self.recordRefreshSuccess(.usb)
                }
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
                    try forgetExport(id: item.id)
                    report.downloaded += 1
                } catch {
                    report.failed.append("\(item.id): \(error)")
                    recordFailure(id: item.id, name: item.visibleName, parent: item.parent, source: .usb, error: error)
                }
            }
            if exports, report.stoppedBy == nil {
                let wanted = try documentsNeedingExports(among: Set(documents.map(\.id)))
                for (i, id) in wanted.enumerated() {
                    progress("Downloading the tablet's PDF of document \(i + 1) of \(wanted.count).")
                    do {
                        let data = try await client.pdf(id: id)
                        report.bytes += data.count
                        try storeExport(id: id, data: data)
                        report.exportsDownloaded += 1
                    } catch let error as USBError {
                        if case .http = error {
                            report.exportsFailed += 1
                            continue
                        }
                        report.stoppedBy = "\(error)"
                        break
                    } catch {
                        report.exportsFailed += 1
                    }
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

    /// How many items a cloud refresh reads at once.
    /// The session's transport bounds the requests in flight, whatever this is.
    static let cloudItemWindow = 4

    /// Refreshes the library from reMarkable's cloud.
    ///
    /// It reads the root; when the root hash is the one from the last refresh, it stops there.
    /// Otherwise it reads the root index and, for each item whose index hash changed,
    /// the item's index, its metadata, and the files whose hashes differ from the files in the mirror.
    /// It reads several items at once, and the session's transport paces the requests.
    ///
    /// When the mirror's copy of a document is newer than the cloud's, by `lastModified`,
    /// the refresh keeps the mirror's copy.
    /// The cloud can be behind the tablet: on 2026-10-25 it held June versions of two documents
    /// that the tablet had changed in September and October.
    /// It removes items that the root no longer lists, if the cloud listed them before;
    /// an item that only USB has seen may not have reached the cloud yet.
    /// It skips items in the trash.
    public func refreshCloud(
        session: CloudSession = CloudSession(),
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> RefreshReport {
        try await withRefreshLock {
            let start = Date()
            let before = await session.usage()
            var report = RefreshReport(source: .cloud)
            do {
                try await refreshCloud(session: session, report: &report, progress: progress)
            } catch {
                try? recordRefreshFailure(.cloud, "\(error)")
                throw error
            }
            let usage = await session.usage() - before
            report.requests = usage.requests
            report.bytes = usage.bytes
            report.retries = usage.retries
            report.waits = usage.waits
            try recordRefreshSuccess(.cloud)
            report.seconds = Date().timeIntervalSince(start)
            return report
        }
    }

    private func refreshCloud(
        session: CloudSession,
        report: inout RefreshReport,
        progress: @Sendable (String) -> Void
    ) async throws {
        let client = try await session.client()
        let root = try await client.root()
        let state = try stateValues()
        let stored = try versions()
        let hasErrors = stored.values.contains { $0.error != nil }
        if root.hash == state["cloud.root_hash"], !hasErrors {
            report.listed = stored.values.filter { $0.isVisibleDocument && $0.cloudHash != nil }.count
            report.unchanged = report.listed
            progress("The cloud root has not changed since the last refresh.")
            return
        }

        let rootIndex = try await client.index(id: "root", hash: root.hash)
        guard rootIndex.hashMatches else {
            throw CloudError.hashMismatch(expected: root.hash, actual: (try? rootIndex.index.hash()) ?? "")
        }
        let entries = rootIndex.index.entries.filter { isValidItemID($0.id) }
        progress("The cloud root lists \(entries.count) items.")

        var pending: [(entry: IndexEntry, canKeep: Bool)] = []
        for entry in entries {
            if let known = stored[entry.id], known.cloudHash == entry.hash, known.error == nil {
                if known.isVisibleDocument { report.unchanged += 1 }
                continue
            }
            let known = stored[entry.id]
            pending.append((entry, known != nil && known?.error == nil))
        }

        var next = pending.makeIterator()
        var done = 0
        try await withThrowingTaskGroup(of: CloudItemResult.self) { group in
            for _ in 0 ..< Self.cloudItemWindow {
                guard let item = next.next() else { break }
                group.addTask { try await self.fetchCloudItem(item.entry, canKeep: item.canKeep, client: client) }
            }
            while let result = try await group.next() {
                done += 1
                progress("Read item \(done) of \(pending.count).")
                apply(result, to: &report)
                if let item = next.next() {
                    group.addTask { try await self.fetchCloudItem(item.entry, canKeep: item.canKeep, client: client) }
                }
            }
        }

        let listed = Set(entries.map(\.id))
        let gone = try versions().filter { id, version in
            !listed.contains(id) && (version.cloudHash != nil || version.source == .cloud)
        }.map(\.key)
        try remove(ids: gone)
        report.removed = gone.count
        report.listed = try versions().filter { listed.contains($0.key) && $0.value.isVisibleDocument }.count
        try setState(["cloud.root_hash": root.hash, "cloud.generation": String(root.generation)])
    }

    /// What reading one root entry found. Child tasks read; the refresh writes, one result at a time.
    enum CloudItemResult: Sendable {
        /// A folder, or an item in the trash: the metadata is all the library keeps.
        case metadataOnly(IndexEntry, DocumentMetadata)
        /// The mirror's copy is newer than the cloud's.
        case keptNewer(IndexEntry)
        /// A document's files, with counts of the files downloaded and reused.
        case document(IndexEntry, files: [MirrorFile], downloaded: Int, reused: Int, reusedBytes: Int)
        case failed(IndexEntry, any Error)

        var entry: IndexEntry {
            switch self {
            case .metadataOnly(let entry, _), .keptNewer(let entry), .document(let entry, _, _, _, _),
                .failed(let entry, _):
                entry
            }
        }
    }

    struct MirrorFile: Sendable {
        var name: String
        var data: Data
    }

    /// Reads one root entry: its index, its metadata, and the files that the mirror lacks.
    /// A rejected token stops the whole refresh; any other error fails only this item.
    private func fetchCloudItem(_ entry: IndexEntry, canKeep: Bool, client: CloudClient) async throws
        -> CloudItemResult
    {
        do {
            return try await readCloudItem(entry, canKeep: canKeep, client: client)
        } catch let error as CloudError {
            if case .unauthorized = error { throw error }
            return .failed(entry, error)
        } catch {
            return .failed(entry, error)
        }
    }

    private func readCloudItem(_ entry: IndexEntry, canKeep: Bool, client: CloudClient) async throws
        -> CloudItemResult
    {
        let id = entry.id
        let fetched = try await client.index(id: id, hash: entry.hash)
        guard fetched.hashMatches else {
            throw CloudError.hashMismatch(expected: entry.hash, actual: (try? fetched.index.hash()) ?? "")
        }
        let files = fetched.index.entries
        guard let metadataEntry = files.first(where: { $0.id == "\(id).metadata" }) else {
            throw DocumentError.missing("\(id).metadata")
        }
        let metadataData = try await client.file(metadataEntry)
        let metadata = try DocumentMetadata(parsing: metadataData)
        let current = documentsURL.appending(path: id, directoryHint: .isDirectory)
        if canKeep, let cloudTime = metadata.lastModified,
            let localData = try? Data(contentsOf: current.appending(path: "\(id).metadata")),
            let localTime = (try? DocumentMetadata(parsing: localData))?.lastModified,
            localTime > cloudTime
        {
            return .keptNewer(entry)
        }
        if metadata.isTrashed || metadata.kind == .folder {
            return .metadataOnly(entry, metadata)
        }

        let others = files.filter { $0.id != metadataEntry.id }
        for file in others {
            guard isSafeArchivePath(file.id) else { throw ZipError.unsafePath(file.id) }
        }
        var result = [MirrorFile(name: metadataEntry.id, data: metadataData)]
        var downloaded = 1
        var reused = 0
        var reusedBytes = 0
        try await withThrowingTaskGroup(of: (file: MirrorFile, reused: Bool).self) { group in
            for file in others {
                group.addTask {
                    let local = current.appending(path: file.id)
                    if let data = try? Data(contentsOf: local), ContentHash.sha256Hex(data) == file.hash {
                        return (MirrorFile(name: file.id, data: data), true)
                    }
                    return (MirrorFile(name: file.id, data: try await client.file(file)), false)
                }
            }
            for try await item in group {
                result.append(item.file)
                if item.reused {
                    reused += 1
                    reusedBytes += item.file.data.count
                } else {
                    downloaded += 1
                }
            }
        }
        return .document(entry, files: result, downloaded: downloaded, reused: reused, reusedBytes: reusedBytes)
    }

    /// Writes what one root entry's read found to the mirror and the index.
    private func apply(_ result: CloudItemResult, to report: inout RefreshReport) {
        let id = result.entry.id
        do {
            switch result {
            case .metadataOnly(let entry, let metadata):
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
                report.filesDownloaded += 1
                if metadata.isTrashed { try? FileManager.default.removeItem(at: documentsURL.appending(path: id)) }
            case .keptNewer(let entry):
                try setCloudHash(entry.hash, id: id)
                report.keptNewer += 1
                report.filesDownloaded += 1
            case .document(let entry, let files, let downloaded, let reused, let reusedBytes):
                let folder = try replaceFolder(id: id, files: files.map { ($0.name, $0.data) })
                try store(indexDocument(folder), id: id, source: .cloud, usbModified: nil, cloudHash: entry.hash)
                report.downloaded += 1
                report.filesDownloaded += downloaded
                report.filesReused += reused
                report.bytesReused += reusedBytes
            case .failed(_, let error):
                throw error
            }
        } catch {
            report.failed.append("\(id): \(error)")
            recordFailure(id: id, name: "", parent: "", source: .cloud, error: error)
        }
    }
}
