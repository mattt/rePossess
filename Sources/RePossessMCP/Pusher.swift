import Foundation
import RePossessCloud
import RePossessFormat
import RePossessLibrary
import RePossessUSB

/// What a push did, as `push_markdown`, `push_file`, and the commands report it.
public struct PushResult: Codable, Sendable, Equatable {
    public let push_id: String
    public let title: String
    /// `notebook`, `pdf`, or `epub`.
    public let kind: String
    /// `sent`, `queued`, `unknown`, or `failed`.
    public let status: String
    /// `usb` or `cloud`: the path of the last send, if there was one.
    public let via: String?
    /// The document's ID on the tablet, when rePossess knows it.
    public let tablet_id: String?
    public let pages: Int?
    public let bytes: Int
    public let message: String

    init(_ record: PushRecord, busy: Bool = false) {
        push_id = record.id
        title = record.title
        kind = record.kind.rawValue
        via = record.via?.rawValue
        tablet_id = record.tabletID
        pages = record.pages
        bytes = record.bytes
        let path = record.via == .cloud ? "reMarkable's cloud" : "USB"
        switch record.status {
        case .sent:
            status = "sent"
            message =
                record.via == .cloud
                ? "Sent through reMarkable's cloud as a new document, \"\(record.title)\", at the top level "
                    + "of the library. The tablet shows it after it syncs."
                : "Sent over USB as a new document, \"\(record.title)\", at the top level of the tablet's library."
        case .pending:
            status = "queued"
            let why =
                busy
                ? "a refresh or another push is using the tablet now"
                : (record.error.map { "it could not be sent now (\($0))" }
                    ?? "neither USB nor reMarkable's cloud is available now")
            message =
                "Queued, because \(why). rePossess sends it at the next refresh or push. Do not push it again."
        case .unknown, .sending:
            status = "unknown"
            message =
                "Sent over \(path), but the answer was lost, so whether it arrived is unknown. "
                + "Before it sends it again, rePossess checks whether it arrived, at the next refresh or push. "
                + "Do not push it again."
        case .failed:
            status = "failed"
            message = "\(record.error ?? "It was refused."). rePossess will not send it again."
        }
    }
}

/// Queues pushes and sends them, for the MCP tools and the commands.
public struct Pusher: Sendable {
    public let library: Library
    /// The paths that are available now.
    let paths: @Sendable () -> PushPaths
    /// Downloads an https URL, with a limit in bytes.
    let fetch: @Sendable (URL, Int) async throws -> Data
    let progress: @Sendable (String) -> Void
    /// Sends the queue through rePossess.app, or returns `nil` when the app is not running;
    /// see ``AppLink/sendPushes(timeout:)``. It is tried when the tablet is on USB.
    let byApp: (@Sendable () async throws -> [PushRecord]?)?

    public init(
        library: Library,
        paths: @escaping @Sendable () -> PushPaths,
        fetch: @escaping @Sendable (URL, Int) async throws -> Data = downloadHTTPS,
        byApp: (@Sendable () async throws -> [PushRecord]?)? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.library = library
        self.paths = paths
        self.fetch = fetch
        self.byApp = byApp
        self.progress = progress
    }

    /// The paths that are available: USB when the tablet's USB network is present,
    /// and the cloud when a device token is in the Keychain (checked without reading it).
    public static func availablePaths(session: CloudSession) -> @Sendable () -> PushPaths {
        let makeUSB: @Sendable () -> USBClient = { USBClient() }
        return {
            PushPaths(
                usb: USBNetwork.isPresent() ? makeUSB : nil,
                cloud: DeviceTokenKeychain.exists() ? session : nil
            )
        }
    }

    /// Makes a notebook from Markdown, queues it, and sends what waits.
    public func pushMarkdown(title: String, markdown: String, paginate: Bool) async throws -> PushResult {
        let id = UUID().uuidString.lowercased()
        let notebook = try MarkdownNotebook(title: title, markdown: markdown, paginate: paginate, documentID: id)
        let record = try library.enqueuePush(
            id: id,
            kind: .notebook,
            title: notebook.title,
            data: notebook.rmdoc,
            pages: notebook.pageCount
        )
        return try await send(record)
    }

    /// Reads a PDF or an EPUB from a path or an https URL, queues it, and sends what waits.
    public func pushFile(path: String?, url: String?, title: String?) async throws -> PushResult {
        let data: Data
        let defaultTitle: String
        switch (path, url) {
        case (let path?, nil):
            let fileURL = URL(filePath: (path as NSString).expandingTildeInPath)
            data = try Self.readFile(fileURL)
            defaultTitle = fileURL.deletingPathExtension().lastPathComponent
        case (nil, let text?):
            guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host() != nil else {
                throw PushError("url must be an https URL")
            }
            data = try await fetch(url, Library.maxPushBytes)
            let stem = url.deletingPathExtension().lastPathComponent
            defaultTitle = stem.isEmpty || stem == "/" ? (url.host() ?? "Untitled") : stem
        default:
            throw PushError("Give exactly one of path or url.")
        }
        let kind = try Self.kind(of: data)
        let record = try library.enqueuePush(kind: kind, title: title ?? defaultTitle, data: data)
        return try await send(record)
    }

    /// Sends what waits in the queue, and returns the state of one push.
    func send(_ record: PushRecord) async throws -> PushResult {
        let paths = paths()
        if let byApp, paths.usb != nil {
            do {
                if try await byApp() != nil {
                    progress("rePossess.app sent the queue for this client.")
                    return PushResult(try library.push(id: record.id) ?? record)
                }
            } catch is RefreshError {
                return PushResult(try library.push(id: record.id) ?? record, busy: true)
            } catch {
                // The app took the request but did not answer; it may still be sending, so this process does not.
                progress("rePossess.app did not finish sending the queue: \(error)")
                return PushResult(try library.push(id: record.id) ?? record)
            }
        }
        do {
            _ = try await library.sendPushes(paths: paths, progress: progress)
        } catch is RefreshError {
            return PushResult(try library.push(id: record.id) ?? record, busy: true)
        } catch {
            progress("The queue could not be sent: \(error)")
        }
        return PushResult(try library.push(id: record.id) ?? record)
    }

    /// Reads a regular file of at most ``Library/maxPushBytes``.
    static func readFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw PushError("\(url.path) is not a file") }
        if let size = values.fileSize, size > Library.maxPushBytes {
            throw PushError("the file has \(size) bytes; the limit is \(Library.maxPushBytes)")
        }
        return try Data(contentsOf: url)
    }

    /// PDF or EPUB, from the file's first bytes.
    static func kind(of data: Data) throws -> PushKind {
        if data.starts(with: Data("%PDF-".utf8)) { return .pdf }
        // An EPUB is a zip file whose first entry is `mimetype`, stored, with `application/epub+zip`.
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]), data.count >= 58,
            String(decoding: data[30 ..< 58], as: UTF8.self) == "mimetypeapplication/epub+zip"
        {
            return .epub
        }
        throw PushError("push_file sends PDF and EPUB files, and this file is neither")
    }
}

/// Downloads an https URL with `URLSession`, and refuses a redirect to anything but https
/// and a body larger than `limit` bytes.
@Sendable public func downloadHTTPS(_ url: URL, limit: Int) async throws -> Data {
    guard url.scheme?.lowercased() == "https" else { throw PushError("url must be an https URL") }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 300
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let (bytes, response) = try await session.bytes(from: url, delegate: HTTPSOnlyRedirects())
    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
        throw PushError("the download answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    if http.expectedContentLength > Int64(limit) {
        throw PushError("the file has \(http.expectedContentLength) bytes; the limit is \(limit)")
    }
    var data = Data()
    for try await byte in bytes {
        data.append(byte)
        if data.count > limit { throw PushError("the file is larger than the limit of \(limit) bytes") }
    }
    return data
}

/// Follows a redirect only to another https URL.
private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
}
