import Foundation
import RePossessCloud
import RePossessFormat
import RePossessUSB

/// What a push sends.
public enum PushKind: String, Sendable, Codable {
    /// A notebook made from Markdown, as an rmdoc archive.
    case notebook
    case pdf
    case epub

    /// The payload file's extension in the library.
    var fileExtension: String { self == .notebook ? "rmdoc" : rawValue }
}

/// Where a push is.
public enum PushStatus: String, Sendable, Codable {
    /// Waiting for USB or the cloud.
    case pending
    /// Being sent. A push left in this state by a process that stopped is treated as unknown.
    case sending
    /// The last send got no answer, and rePossess has not yet found out whether it arrived.
    /// It checks the next time the same path is available, before it sends again.
    case unknown
    /// The tablet or the cloud has the document.
    case sent
    /// The tablet or the cloud refused it; rePossess does not send it again.
    case failed
}

/// One push in the library's queue.
public struct PushRecord: Sendable, Equatable, Codable {
    /// The push's ID, a lowercase UUID. A cloud push uses it as the document ID.
    public var id: String
    public var kind: PushKind
    public var title: String
    public var bytes: Int
    /// The pages of a notebook.
    public var pages: Int?
    public var created: Date
    public var status: PushStatus
    /// The path of the last send: `usb` or `cloud`.
    public var via: Source?
    public var attempts: Int
    public var lastAttempt: Date?
    public var sent: Date?
    /// The document's ID on the tablet, when rePossess found it.
    public var tabletID: String?
    /// IDs of documents with the same name that the tablet listed before a USB upload.
    public var preexisting: [String]
    /// The last error, if the last send did not succeed.
    public var error: String?
    /// The name of the top-level folder that the push goes into, or `nil` for the top level.
    public var folder: String?
    /// The folder's ID: a folder that the mirror listed, or the ID that rePossess chose for a new one.
    public var folderID: String?
    /// Whether the mirror had no folder with that name, so that the push adds one.
    public var folderIsNew: Bool?
}

/// The top-level folder that a push goes into.
public struct PushFolder: Sendable, Equatable {
    public var name: String
    public var id: String
    /// Whether no folder has the name yet, so that the push adds one.
    public var isNew: Bool
}

/// The paths that a push can take now: a USB client when the tablet is connected,
/// and a cloud session when rePossess is paired.
public struct PushPaths: Sendable {
    public var usb: (@Sendable () -> USBClient)?
    public var cloud: CloudSession?

    public init(usb: (@Sendable () -> USBClient)?, cloud: CloudSession?) {
        self.usb = usb
        self.cloud = cloud
    }

    /// No path: pushes wait in the queue.
    public static let none = PushPaths(usb: nil, cloud: nil)
}

/// Why a push could not be queued.
public struct PushError: Error, CustomStringConvertible, Equatable {
    public var description: String

    public init(_ description: String) { self.description = description }
}

extension Library {
    /// The largest file that a push takes: the USB web interface's limit in reMarkable's support article.
    public static let maxPushBytes = USBUpload.maxBytes

    var pushesURL: URL { root.appending(path: "pushes", directoryHint: .isDirectory) }

    func payloadURL(_ record: PushRecord) -> URL {
        pushesURL.appending(path: "\(record.id).\(record.kind.fileExtension)")
    }

    // MARK: The queue

    /// Finds the top-level folder with a name, or plans a new one. It changes nothing.
    ///
    /// Names match without regard to case, and a name with `/` is refused.
    ///
    /// - One top-level folder in the mirror with exactly that name is used, even when other folders
    ///   differ from it only in case: the exact spelling picks one.
    /// - Two or more folders with exactly that name are an error that lists them.
    /// - No exact match and one or more folders that differ only in case are an error that names them,
    ///   so that rePossess does not make a near-duplicate such as "pa 518" next to "PA 518".
    ///   The caller can push to the existing spelling.
    /// - No match at all means a new folder, whose ID is chosen now. An earlier push that has not failed
    ///   and that planned a new folder with the same name lends its folder ID, so that pushes
    ///   made before the next refresh share one new folder. An earlier push that planned a name
    ///   which differs only in case is an error too. An ID is lent only while the mirror has not seen it:
    ///   once the mirror has listed that ID, even if a later refresh removed it,
    ///   the folder may have been renamed, moved, or deleted, so the name gets a new folder.
    ///
    /// The mirror's trash is not searched, and nested folders do not match.
    public func pushFolder(named name: String) throws -> PushFolder {
        let name = try Self.checkedFolderName(name)
        if let existing = try mirroredFolder(named: name) { return existing }
        return PushFolder(name: name, id: try lentFolderID(named: name) { try database.query($0, $1) }, isNew: true)
    }

    private static func checkedFolderName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw PushError("the folder name is empty") }
        guard name.count <= MarkdownNotebook.maxTitleLength else {
            throw PushError(
                "the folder name has \(name.count) characters; the limit is \(MarkdownNotebook.maxTitleLength)"
            )
        }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PushError("the folder name has a control character or a line break")
        }
        guard !name.contains("/") else {
            throw PushError("a folder name cannot contain /; a push goes into one top-level folder, not a path")
        }
        return name
    }

    /// Whether two folder names are the same without regard to case.
    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }

    /// The one top-level folder in the mirror that a name picks, or `nil` when no folder has the name
    /// in any case. See ``pushFolder(named:)`` for the rules.
    func mirroredFolder(named name: String) throws -> PushFolder? {
        let similar = try folders().filter { $0.parent.isEmpty && Self.sameName($0.name, name) }
        let exact = similar.filter { $0.name == name }
        func list(_ folders: [LibraryItem]) -> String {
            folders.map { folder in
                "\"\(folder.name)\" (ID \(folder.id)"
                    + (folder.modified.map { ", changed \($0.formatted(.iso8601))" } ?? "") + ")"
            }.joined(separator: "; ")
        }
        if exact.count > 1 {
            throw PushError(
                "\(exact.count) top-level folders are named \"\(name)\": \(list(exact)). "
                    + "rePossess does not choose between them; rename one on the tablet, or use another name"
            )
        }
        if let only = exact.first { return PushFolder(name: name, id: only.id, isNew: false) }
        if !similar.isEmpty {
            throw PushError(
                "no top-level folder is named \"\(name)\", but \(list(similar)) differs only in case. "
                    + "rePossess does not make a near-duplicate; push to the existing name, or use another name"
            )
        }
        return nil
    }

    /// The folder ID of the oldest push that planned a new folder with the name,
    /// if the mirror has not seen that ID; otherwise a new ID.
    /// A push that planned a name which differs only in case is an error.
    /// `run` runs the SQL, so that a caller can run it inside a transaction.
    private func lentFolderID(named name: String, run: (String, [SQLValue]) throws -> [[SQLValue]]) throws -> String {
        let earlier = try run(
            """
            SELECT folder, folder_id FROM pushes
            WHERE folder_new = 1 AND status != 'failed' AND folder IS NOT NULL AND folder_id IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM items WHERE items.id = pushes.folder_id)
              AND NOT EXISTS (SELECT 1 FROM seen_folders WHERE seen_folders.id = pushes.folder_id)
            ORDER BY created, id
            """,
            []
        ).compactMap { row -> (name: String, id: String)? in
            guard let name = row[0].string, let id = row[1].string else { return nil }
            return (name, id)
        }
        if let match = earlier.first(where: { $0.name == name }) { return match.id }
        if let near = earlier.first(where: { Self.sameName($0.name, name) }) {
            throw PushError(
                "an earlier push is about to make a folder named \"\(near.name)\", which differs from \"\(name)\" "
                    + "only in case. rePossess does not make a near-duplicate; "
                    + "push to \"\(near.name)\", or use another name"
            )
        }
        return UUID().uuidString.lowercased()
    }

    /// Adds a push to the queue, with its payload in the library's `pushes/` folder.
    ///
    /// The folder lookup and the insert run in one immediate transaction,
    /// so that two processes that queue pushes for the same new folder get the same folder ID.
    ///
    /// - Parameters:
    ///   - id: The push's ID; a notebook's archive must use it as its document ID.
    ///   - folder: The name of a top-level folder; see ``pushFolder(named:)``.
    ///     A push with a folder goes only through the cloud, because the USB web interface
    ///     cannot choose a folder or make one.
    public func enqueuePush(
        id: String = UUID().uuidString.lowercased(),
        kind: PushKind,
        title: String,
        data: Data,
        pages: Int? = nil,
        folder: String? = nil,
        now: Date = Date()
    ) throws -> PushRecord {
        guard data.count <= Self.maxPushBytes else {
            throw PushError("the file has \(data.count) bytes; the limit is \(Self.maxPushBytes)")
        }
        let folderName = try folder.map(Self.checkedFolderName)
        let existing = try folderName.flatMap(mirroredFolder(named:))
        var record = PushRecord(
            id: id,
            kind: kind,
            title: try MarkdownNotebook.checkedTitle(title),
            bytes: data.count,
            pages: pages,
            created: now,
            status: .pending,
            attempts: 0,
            preexisting: []
        )
        try FileManager.default.createDirectory(at: pushesURL, withIntermediateDirectories: true)
        try data.write(to: payloadURL(record), options: .atomic)
        do {
            try database.transaction { transaction in
                if let folderName {
                    let target =
                        try existing
                        ?? PushFolder(
                            name: folderName,
                            id: lentFolderID(named: folderName) { try transaction.query($0, $1) },
                            isNew: true
                        )
                    record.folder = target.name
                    record.folderID = target.id
                    record.folderIsNew = target.isNew
                    afterFolderLookup.withLock { $0 }?()
                }
                try transaction.query(
                    """
                    INSERT INTO pushes (id, kind, title, payload, bytes, pages, created, status, folder, folder_id, folder_new)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)
                    """,
                    [
                        .text(id), .text(kind.rawValue), .text(record.title),
                        .text(payloadURL(record).lastPathComponent),
                        SQLValue(data.count), SQLValue(pages), SQLValue(now),
                        SQLValue(record.folder), SQLValue(record.folderID),
                        SQLValue(record.folderIsNew.map { $0 ? 1 : 0 }),
                    ]
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: payloadURL(record))
            throw error
        }
        return record
    }

    /// Version 5: the folder of a push. A column that exists already is left alone,
    /// so that a library whose version number went back still opens.
    func migrateToVersion5() throws {
        let existing = Set(try database.query("PRAGMA table_info(pushes)").compactMap { $0[1].string })
        let additions = [("folder", "TEXT"), ("folder_id", "TEXT"), ("folder_new", "INTEGER")]
            .filter { !existing.contains($0.0) }
            .map { "ALTER TABLE pushes ADD COLUMN \($0.0) \($0.1);" }
        try database.execute("BEGIN; \(additions.joined(separator: " ")) PRAGMA user_version = 5; COMMIT;")
    }

    /// Version 6: the IDs of every folder the mirror has listed, which outlive the folder's row,
    /// so that a folder that a refresh removed after a permanent delete does not lend its ID again.
    func migrateToVersion6() throws {
        try database.execute(
            """
            BEGIN;
            CREATE TABLE IF NOT EXISTS seen_folders (id TEXT PRIMARY KEY);
            INSERT OR IGNORE INTO seen_folders (id) SELECT id FROM items WHERE kind = 'CollectionType';
            PRAGMA user_version = 6;
            COMMIT;
            """
        )
    }

    private static let pushColumns = """
        id, kind, title, bytes, pages, created, status, via, attempts, last_attempt, sent, tablet_id, preexisting, error,
        folder, folder_id, folder_new
        """

    private func pushRecord(_ row: [SQLValue]) -> PushRecord {
        PushRecord(
            id: row[0].string ?? "",
            kind: PushKind(rawValue: row[1].string ?? "") ?? .pdf,
            title: row[2].string ?? "",
            bytes: row[3].int ?? 0,
            pages: row[4].int,
            created: Date(timeIntervalSince1970: row[5].double ?? 0),
            status: PushStatus(rawValue: row[6].string ?? "") ?? .unknown,
            via: row[7].string.flatMap(Source.init(rawValue:)),
            attempts: row[8].int ?? 0,
            lastAttempt: row[9].double.map(Date.init(timeIntervalSince1970:)),
            sent: row[10].double.map(Date.init(timeIntervalSince1970:)),
            tabletID: row[11].string,
            preexisting: decodeJSON(row[12].string) ?? [],
            error: row[13].string,
            folder: row[14].string,
            folderID: row[15].string,
            folderIsNew: row[16].int.map { $0 != 0 }
        )
    }

    /// Every push, oldest first.
    public func pushes() throws -> [PushRecord] {
        try database.query("SELECT \(Self.pushColumns) FROM pushes ORDER BY created, id").map(pushRecord)
    }

    /// One push, or `nil`.
    public func push(id: String) throws -> PushRecord? {
        try database.query("SELECT \(Self.pushColumns) FROM pushes WHERE id = ?", [.text(id)]).first.map(pushRecord)
    }

    /// The number of pushes in each status.
    public func pushCounts() throws -> [PushStatus: Int] {
        var counts: [PushStatus: Int] = [:]
        for row in try database.query("SELECT status, count(*) FROM pushes GROUP BY status") {
            if let status = row[0].string.flatMap(PushStatus.init(rawValue:)) { counts[status] = row[1].int ?? 0 }
        }
        return counts
    }

    /// Removes a push that has not been sent, with its payload.
    /// A push whose outcome is unknown may already be on the tablet; removing it stops rePossess from checking.
    public func dropPush(id: String) throws -> PushRecord {
        guard let record = try push(id: id) else { throw PushError("no push has the id \(id)") }
        guard record.status != .sent, record.status != .sending else {
            throw PushError(
                "the push \(id) is \(record.status.rawValue); only a push that has not been sent can be dropped"
            )
        }
        try database.query("DELETE FROM pushes WHERE id = ?", [.text(id)])
        try? FileManager.default.removeItem(at: payloadURL(record))
        return record
    }

    /// Writes a push's state.
    func save(_ record: PushRecord) throws {
        try database.query(
            """
            UPDATE pushes SET status = ?, via = ?, attempts = ?, last_attempt = ?, sent = ?, tablet_id = ?,
              preexisting = ?, error = ?
            WHERE id = ?
            """,
            [
                .text(record.status.rawValue), SQLValue(record.via?.rawValue), SQLValue(record.attempts),
                SQLValue(record.lastAttempt), SQLValue(record.sent), SQLValue(record.tabletID),
                .text(encodeJSON(record.preexisting)), SQLValue(record.error), .text(record.id),
            ]
        )
        if record.status == .sent { try? FileManager.default.removeItem(at: payloadURL(record)) }
    }

    // MARK: Sending

    /// Sends the pushes that wait, oldest first, by the paths that are available.
    ///
    /// - USB comes first when the tablet is connected, then the cloud when rePossess is paired.
    ///   A push that USB did not take, for a reason that shows it did not arrive, goes to the cloud.
    /// - A push whose last send got no answer is checked before anything else, on the same path:
    ///   over USB, rePossess lists every folder and looks for a new document with the push's name,
    ///   changed after the send; through the cloud, it reads the root and looks for the push's ID.
    ///   Only when the check finds nothing does it send the push again.
    /// - A push with a folder skips USB, which cannot choose or make a folder, and goes through the cloud.
    ///   Without the cloud it stays pending, with an error that says why.
    /// - A refusal (HTTP 4xx, or a plan that the cloud root does not allow) marks the push failed.
    ///
    /// It holds the library's refresh lock, so that two processes never send the same push.
    /// - Returns: The pushes that this call changed, in their new state.
    /// - Throws: ``RefreshError/busy`` when a refresh or another send holds the lock.
    public func sendPushes(
        paths: PushPaths,
        wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> [PushRecord] {
        try await withRefreshLock {
            try database.query("UPDATE pushes SET status = 'unknown' WHERE status = 'sending'")
            let queue = try pushes().filter { $0.status == .pending || $0.status == .unknown }
            guard !queue.isEmpty else { return [] }
            var sender = PushSender(library: self, paths: paths, wait: wait, progress: progress)
            var changed: [PushRecord] = []
            for record in queue {
                if let result = try await sender.send(record) { changed.append(result) }
            }
            return changed
        }
    }
}

/// Sends the pushes of one ``Library/sendPushes(paths:wait:progress:)`` call.
private struct PushSender {
    let library: Library
    let paths: PushPaths
    let wait: @Sendable (Duration) async -> Void
    let progress: @Sendable (String) -> Void
    private var usbClient: USBClient?
    /// Set after a USB timeout: the interface may be hung, so this call sends nothing more over USB.
    private var usbStopped = false

    init(
        library: Library,
        paths: PushPaths,
        wait: @escaping @Sendable (Duration) async -> Void,
        progress: @escaping @Sendable (String) -> Void
    ) {
        self.library = library
        self.paths = paths
        self.wait = wait
        self.progress = progress
    }

    private mutating func usb() -> USBClient? {
        guard !usbStopped, let make = paths.usb else { return nil }
        if usbClient == nil { usbClient = make() }
        return usbClient
    }

    private mutating func noteUSBError(_ error: any Error) {
        if case .timedOut = error as? USBError { usbStopped = true }
        if case .stopped = error as? USBError { usbStopped = true }
    }

    /// Sends or checks one push. Returns its new state, or `nil` when nothing changed.
    mutating func send(_ original: PushRecord) async throws -> PushRecord? {
        var record = original
        if record.status == .unknown {
            switch try await check(record) {
            case .found(let tabletID):
                return try record.sentNow(via: record.via ?? .usb, library: library, tabletID: tabletID)
            case .absent:
                record.status = .pending
                record.error = "Not found on the \(record.via == .cloud ? "cloud" : "tablet") after an unanswered send"
                try library.save(record)
            case .unavailable:
                return nil
            }
        }
        let payload: Data
        do {
            payload = try Data(contentsOf: library.payloadURL(record))
        } catch {
            record.status = .failed
            record.error = "The payload file is missing: \(error)"
            try library.save(record)
            return record
        }
        // The USB web interface has one upload route, `POST /upload`, with no field for a parent folder
        // and no route that makes a folder, so a push with a folder takes the cloud or waits.
        if record.folder == nil, let usb = usb() {
            if let done = try await sendUSB(record, payload: payload, client: usb) { return done }
            record = try library.push(id: record.id) ?? record
        }
        if let session = paths.cloud {
            return try await sendCloud(record, payload: payload, session: session)
        }
        if record.folder != nil, record.error != Self.folderNeedsCloud {
            record.error = Self.folderNeedsCloud
            try library.save(record)
        }
        return record == original ? nil : record
    }

    /// Why a push with a folder waits when the cloud is not available.
    static let folderNeedsCloud =
        "a push into a folder needs reMarkable's cloud, because the USB web interface cannot choose or make a folder"

    /// What a check of an unanswered send found.
    private enum CheckResult {
        case found(tabletID: String?)
        case absent
        /// The send's path is not available now, or the check failed.
        case unavailable
    }

    /// Whether an unanswered send arrived, checked on the path that sent it.
    private mutating func check(_ record: PushRecord) async throws -> CheckResult {
        switch record.via {
        case .usb?:
            guard let usb = usb() else { return .unavailable }
            progress("Looking on the tablet for \"\(record.title)\", whose upload got no answer.")
            do {
                let items = try await usb.listAll()
                guard let id = Self.match(record, in: items, since: record.lastAttempt) else { return .absent }
                return .found(tabletID: id)
            } catch {
                noteUSBError(error)
                return .unavailable
            }
        case .cloud?:
            guard let session = paths.cloud else { return .unavailable }
            progress("Looking in the cloud for \"\(record.title)\", whose root update got no answer.")
            do {
                return try await session.client().contains(documentID: record.id)
                    ? .found(tabletID: record.id) : .absent
            } catch {
                return .unavailable
            }
        case nil:
            return .absent
        }
    }

    /// The newest document that a USB upload made: one with the push's name,
    /// not listed before the upload, and changed no earlier than ten minutes before the send,
    /// which allows for a difference between the tablet's clock and the Mac's.
    static func match(_ record: PushRecord, in items: [USBItem], since: Date?) -> String? {
        let names =
            record.kind == .notebook
            ? [record.title] : USBUpload(kind: .pdf, title: record.title, data: Data()).expectedNames
        let candidates = items.filter { item in
            guard !item.isFolder, names.contains(item.visibleName), !record.preexisting.contains(item.id) else {
                return false
            }
            guard let since, let modified = item.modifiedClient.flatMap(parseTabletDate) else { return true }
            return modified >= since.addingTimeInterval(-600)
        }
        return candidates.max { ($0.modifiedClient ?? "") < ($1.modifiedClient ?? "") }?.id
    }

    /// Sends a push over USB. Returns its new state when USB settled it,
    /// or `nil` when USB did not take it and the cloud may.
    private mutating func sendUSB(_ original: PushRecord, payload: Data, client: USBClient) async throws
        -> PushRecord?
    {
        var record = original
        let kind: USBUpload.Kind =
            switch record.kind {
            case .notebook: .rmdoc
            case .pdf: .pdf
            case .epub: .epub
            }
        let upload = USBUpload(kind: kind, title: record.title, data: payload)
        progress("Sending \"\(record.title)\" over USB.")
        do {
            // Listing the top level just before the upload makes it the folder that the interface
            // last listed, which one source says is where an upload goes (unchecked; tests saw the top level).
            let before = try await client.list()
            let names = record.kind == .notebook ? [record.title] : upload.expectedNames
            record.preexisting = before.filter { names.contains($0.visibleName) }.map(\.id)
        } catch {
            noteUSBError(error)
            record.error = "USB: \(error)"
            try library.save(record)
            return nil
        }
        record.status = .sending
        record.via = .usb
        record.attempts += 1
        record.lastAttempt = Date()
        try library.save(record)
        do {
            try await client.upload(upload)
        } catch let error as USBError {
            noteUSBError(error)
            switch error {
            case .notConnected, .interfaceOff, .stopped, .invalidID:
                record.status = .pending
                record.error = "USB: \(error)"
                try library.save(record)
                return nil
            case .http(_, let status) where (400 ..< 500).contains(status):
                record.status = .failed
                record.error = "The tablet refused the upload: \(error)"
                try library.save(record)
                return record
            default:
                record.status = .unknown
                record.error =
                    "The upload got no answer (\(error)). rePossess looks for it on the tablet before it sends it again."
                try library.save(record)
                return record
            }
        }
        // The tablet answers without the new document's ID; find it in the listing.
        await wait(.seconds(1))
        var tabletID: String?
        if let items = try? await client.list() {
            tabletID = Self.match(record, in: items, since: nil)
        }
        return try record.sentNow(via: .usb, library: library, tabletID: tabletID)
    }

    /// Sends a push through the cloud and returns its new state.
    private func sendCloud(_ original: PushRecord, payload: Data, session: CloudSession) async throws -> PushRecord {
        var record = original
        // A folder that the mirror lists now may have been made after the push was queued.
        // The push planned a new folder, so it is refused rather than moved to the other folder:
        // the document's files already name the planned folder as their parent.
        if record.folderIsNew == true, let name = record.folder, let id = record.folderID {
            let problem: String?
            do {
                if let other = try library.mirroredFolder(named: name), other.id != id {
                    problem =
                        "the library lists a top-level folder named \"\(name)\" (ID \(other.id)) "
                        + "that did not exist when the push was queued"
                } else {
                    problem = nil
                }
            } catch let error as PushError {
                problem = "\(error)"
            }
            if let problem {
                record.status = .failed
                record.error = "Refused, because \(problem); " + CloudClient.afterRefusal
                try library.save(record)
                return record
            }
        }
        progress("Sending \"\(record.title)\" through the cloud.")
        record.status = .sending
        record.via = .cloud
        record.attempts += 1
        record.lastAttempt = Date()
        try library.save(record)
        do {
            let document = try Self.document(record, payload: payload)
            let folder = try Self.newFolder(record)
            let client = try await session.client()
            let known = try library.cloudHashes()
            switch try await client.push(
                document,
                folder: folder,
                parentName: record.folder,
                knownEntries: known,
                progress: progress
            ) {
            case .sent:
                return try record.sentNow(via: .cloud, library: library, tabletID: record.id)
            case .unknown(let reason):
                record.status = .unknown
                record.error = "\(reason). rePossess looks for it in the cloud before it sends it again."
            }
        } catch let error as CloudError {
            switch error {
            case .invalidUpload:
                record.status = .failed
                record.error = "The cloud upload was refused: \(error)"
            case .http(let status, _) where (400 ..< 500).contains(status) && ![404, 408, 409, 429].contains(status):
                record.status = .failed
                record.error = "The cloud refused the upload: \(error)"
            default:
                record.status = .pending
                record.error = "Cloud: \(error)"
            }
        } catch {
            record.status = .pending
            record.error = "Cloud: \(error)"
        }
        try library.save(record)
        return record
    }

    /// The new folder that a cloud push adds with its document, or `nil`.
    static func newFolder(_ record: PushRecord) throws -> NewFolder? {
        guard record.folderIsNew == true, let name = record.folder, let id = record.folderID else { return nil }
        return try NewFolder.make(visibleName: name, folderID: id)
    }

    /// The document that a cloud push adds, with the push's ID as its document ID.
    static func document(_ record: PushRecord, payload: Data) throws -> NewDocument {
        let parent = record.folderID ?? ""
        switch record.kind {
        case .notebook:
            let archive = try RmdocArchive(data: payload)
            guard let archiveID = archive.documentID else {
                throw CloudError.invalidUpload("the notebook archive has no .metadata or .content")
            }
            return try NewDocument.notebook(
                files: archive.files.map { ($0.name, $0.data) },
                archiveID: archiveID,
                visibleName: record.title,
                documentID: record.id,
                parent: parent
            )
        case .pdf:
            return try NewDocument.file(
                .pdf,
                visibleName: record.title,
                data: payload,
                documentID: record.id,
                parent: parent
            )
        case .epub:
            return try NewDocument.file(
                .epub,
                visibleName: record.title,
                data: payload,
                documentID: record.id,
                parent: parent
            )
        }
    }
}

extension PushRecord {
    /// Marks the push sent, saves it, and returns it.
    fileprivate func sentNow(via source: Source, library: Library, tabletID: String?) throws -> PushRecord {
        var record = self
        record.status = .sent
        record.via = source
        record.sent = Date()
        record.tabletID = tabletID
        record.error = nil
        try library.save(record)
        return record
    }
}

/// Reads the tablet's `ModifiedClient`, such as `2026-10-25T07:00:00.000Z`.
func parseTabletDate(_ text: String) -> Date? {
    if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
        return date
    }
    if let date = try? Date(text, strategy: .iso8601) { return date }
    return nil
}
