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

    /// Adds a push to the queue, with its payload in the library's `pushes/` folder.
    ///
    /// - Parameters:
    ///   - id: The push's ID; a notebook's archive must use it as its document ID.
    public func enqueuePush(
        id: String = UUID().uuidString.lowercased(),
        kind: PushKind,
        title: String,
        data: Data,
        pages: Int? = nil,
        now: Date = Date()
    ) throws -> PushRecord {
        guard data.count <= Self.maxPushBytes else {
            throw PushError("the file has \(data.count) bytes; the limit is \(Self.maxPushBytes)")
        }
        let record = PushRecord(
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
        try database.query(
            """
            INSERT INTO pushes (id, kind, title, payload, bytes, pages, created, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'pending')
            """,
            [
                .text(id), .text(kind.rawValue), .text(record.title), .text(payloadURL(record).lastPathComponent),
                SQLValue(data.count), SQLValue(pages), SQLValue(now),
            ]
        )
        return record
    }

    private static let pushColumns = """
        id, kind, title, bytes, pages, created, status, via, attempts, last_attempt, sent, tablet_id, preexisting, error
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
            error: row[13].string
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
        if let usb = usb() {
            if let done = try await sendUSB(record, payload: payload, client: usb) { return done }
            record = try library.push(id: record.id) ?? record
        }
        if let session = paths.cloud {
            return try await sendCloud(record, payload: payload, session: session)
        }
        return record == original ? nil : record
    }

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
        progress("Sending \"\(record.title)\" through the cloud.")
        record.status = .sending
        record.via = .cloud
        record.attempts += 1
        record.lastAttempt = Date()
        try library.save(record)
        do {
            let document = try Self.document(record, payload: payload)
            let client = try await session.client()
            switch try await client.push(document, progress: progress) {
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

    /// The document that a cloud push adds, with the push's ID as its document ID.
    static func document(_ record: PushRecord, payload: Data) throws -> NewDocument {
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
                documentID: record.id
            )
        case .pdf:
            return try NewDocument.file(.pdf, visibleName: record.title, data: payload, documentID: record.id)
        case .epub:
            return try NewDocument.file(.epub, visibleName: record.title, data: payload, documentID: record.id)
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
