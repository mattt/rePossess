import CryptoKit
import Darwin
import Foundation
import RePossessLibrary

/// What the helper asks the running app to do.
public enum AppLinkRequest: String, Codable, Sendable {
    /// Refresh over USB, then send the queue of pushes, as the app's own USB refresh does.
    case refreshUSB = "refresh-usb"
    /// Send the queue of pushes by the paths that the app has.
    case sendPushes = "send-pushes"
}

/// The app's answer.
public struct AppLinkResponse: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// The app did the work; `reports` or `pushes` say what happened.
        case done
        /// Another process held the library's refresh lock.
        case busy
        /// The tablet is not on USB.
        case noUSB = "no-usb"
        /// The work failed before it had a report; `message` says why.
        case failed
    }

    public var status: Status
    public var reports: [RefreshReport] = []
    public var pushes: [PushRecord] = []
    public var message: String?

    public init(status: Status, reports: [RefreshReport] = [], pushes: [PushRecord] = [], message: String? = nil) {
        self.status = status
        self.reports = reports
        self.pushes = pushes
        self.message = message
    }
}

/// An error on the link between the helper and the app.
public enum AppLinkError: Error, CustomStringConvertible, Equatable {
    /// No app listens on the library's socket.
    case notRunning
    /// The app did not answer in time.
    case timedOut(seconds: Int)
    /// The connection closed, or the answer could not be read.
    case broken(String)

    public var description: String {
        switch self {
        case .notRunning: "rePossess.app is not running for this library"
        case .timedOut(let seconds): "rePossess.app did not answer within \(seconds) seconds"
        case .broken(let reason): "the connection to rePossess.app failed: \(reason)"
        }
    }
}

/// The link between `repossess mcp` and rePossess.app: a Unix-domain socket for the library.
///
/// macOS can decide a helper's local network access by the app that started it,
/// so a helper that an MCP client starts may be refused the tablet's USB network
/// until the client is allowed (TN3179; Claude Desktop on 2026-10-25).
/// While the app runs, the helper asks it to do the USB work instead.
///
/// A socket in the library folder was chosen over a Darwin notification and XPC.
/// A notification is global and carries no answer, so the helper would have to guess
/// whether an app for this library is listening and poll the library for the result.
/// XPC between two unrelated processes needs a Mach service that launchd registers,
/// such as a launch agent. A connection to the socket succeeds only while the app listens,
/// so it also tells the helper whether the app is running; it carries the report back;
/// and it is local to one library. No sandbox is in the way.
public struct AppLink: Sendable {
    /// The socket's path.
    public let path: String

    /// The longest path that `sockaddr_un` holds, without the final zero byte.
    static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// The socket for a library: `app.sock` in the library folder when the path fits in a socket address,
    /// and otherwise a name from a hash of the folder's path in the user's temporary folder.
    public init(libraryRoot: URL) {
        let root = libraryRoot.resolvingSymlinksInPath().standardizedFileURL
        let inLibrary = root.appending(path: "app.sock").path
        if inLibrary.utf8.count <= Self.maxPathLength {
            path = inLibrary
        } else {
            let digest = SHA256.hash(data: Data(root.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            path = Self.userTemporaryFolder().appending(path: "repossess-\(digest).sock").path
        }
    }

    public init(path: String) { self.path = path }

    /// The user's temporary folder, from the system rather than `TMPDIR`, which a client may change.
    static func userTemporaryFolder() -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            return URL(filePath: String(cString: buffer), directoryHint: .isDirectory)
        }
        return FileManager.default.temporaryDirectory
    }

    func address() throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count <= Self.maxPathLength else { throw AppLinkError.broken("the socket path is too long") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = byte }
            raw[bytes.count] = 0
        }
        return address
    }

    /// Connects to the app, or returns `nil` when no app listens.
    func connect() -> Int32? {
        guard var address = try? address() else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Whether an app listens for this library now.
    public var isAppRunning: Bool {
        guard let fd = connect() else { return false }
        close(fd)
        return true
    }

    /// Sends a request and waits for the answer.
    /// - Throws: ``AppLinkError``.
    public func send(_ request: AppLinkRequest, timeout: TimeInterval) async throws -> AppLinkResponse {
        let link = self
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try link.sendBlocking(request, timeout: timeout) })
            }
        }
    }

    private func sendBlocking(_ request: AppLinkRequest, timeout: TimeInterval) throws -> AppLinkResponse {
        guard let fd = connect() else { throw AppLinkError.notRunning }
        defer { close(fd) }
        var line = try JSONEncoder().encode(["request": request])
        line.append(0x0A)
        try Self.write(line, to: fd)
        var wait = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let data: Data
        do {
            data = try Self.readLine(from: fd)
        } catch AppLinkError.timedOut {
            throw AppLinkError.timedOut(seconds: Int(timeout))
        }
        do {
            return try JSONDecoder().decode(AppLinkResponse.self, from: data)
        } catch {
            throw AppLinkError.broken("the answer could not be read: \(error)")
        }
    }

    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw AppLinkError.broken(String(cString: strerror(errno))) }
                offset += n
            }
        }
    }

    /// Reads up to a newline, at most 16 MB.
    static func readLine(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < 16_000_000 {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { throw AppLinkError.timedOut(seconds: 0) }
            guard n >= 0 else { throw AppLinkError.broken(String(cString: strerror(errno))) }
            guard n > 0 else { break }
            if let end = buffer[0 ..< n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[0 ..< end])
                return data
            }
            data.append(contentsOf: buffer[0 ..< n])
        }
        if data.isEmpty { throw AppLinkError.broken("the app closed the connection without an answer") }
        return data
    }
}

/// The app's side of the link: listens on the library's socket and answers each request with `handler`.
public final class AppLinkServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AppLinkRequest) async -> AppLinkResponse

    public let link: AppLink
    private let handler: Handler
    private let queue = DispatchQueue(label: "co.dododo.repossess.app-link")
    private var fd: Int32 = -1
    private var source: (any DispatchSourceRead)?

    public init(link: AppLink, handler: @escaping Handler) {
        self.link = link
        self.handler = handler
    }

    /// Starts listening. A socket file that no app answers on is left from an app that stopped, and is replaced.
    /// - Throws: ``AppLinkError`` when another app listens for this library, or the socket cannot be made.
    public func start() throws {
        try queue.sync {
            guard source == nil else { return }
            if link.isAppRunning { throw AppLinkError.broken("another rePossess.app listens for this library") }
            unlink(link.path)
            var address = try link.address()
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw AppLinkError.broken(String(cString: strerror(errno))) }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(link.path, 0o600) == 0, listen(fd, 8) == 0 else {
                let reason = String(cString: strerror(errno))
                close(fd)
                throw AppLinkError.broken(reason)
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            self.fd = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll() }
            source.resume()
            self.source = source
        }
    }

    /// Stops listening and removes the socket file.
    public func stop() {
        queue.sync {
            guard let source else { return }
            source.cancel()
            self.source = nil
            close(fd)
            fd = -1
            unlink(link.path)
        }
    }

    private func acceptAll() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        // Only processes of this user may ask; the socket's mode is 0600 too.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
            close(client)
            return
        }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        // A connection that sends nothing is a check whether the app runs.
        guard let line = try? AppLink.readLine(from: client),
            let request = try? JSONDecoder().decode([String: AppLinkRequest].self, from: line)["request"]
        else {
            close(client)
            return
        }
        let handler = handler
        Task {
            let response = await handler(request)
            var data = (try? JSONEncoder().encode(response)) ?? Data()
            data.append(0x0A)
            try? AppLink.write(data, to: client)
            close(client)
        }
    }
}

extension AppLink {
    /// The USB step of a refresh through the running app, or `nil` when no app listens for the library.
    ///
    /// The app refreshes over USB and sends the queue, as its own USB refresh does, and answers with its report.
    /// When the answer does not come within `timeout` seconds, the library's USB record decides:
    /// a success or an error recorded after the request counts as the app's result.
    public func refreshUSB(
        library: Library,
        timeout: TimeInterval = 300,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> RefreshReport? {
        guard isAppRunning else { return nil }
        progress("rePossess.app is running, so it refreshes over USB for this client.")
        let started = Date()
        let response: AppLinkResponse
        do {
            response = try await send(.refreshUSB, timeout: timeout)
        } catch AppLinkError.notRunning {
            return nil
        } catch {
            let status = try library.status()
            var report = RefreshReport(source: .usb)
            report.byApp = true
            if let at = status.lastErrorAt[.usb], at >= started {
                report.stoppedBy = status.lastError[.usb] ?? "\(error)"
                return report
            }
            if let at = status.lastRefresh[.usb], at >= started { return report }
            throw error
        }
        var report: RefreshReport
        switch response.status {
        case .done:
            report = response.reports.first { $0.source == .usb } ?? RefreshReport(source: .usb)
        case .busy:
            throw RefreshError.busy
        case .noUSB:
            report = RefreshReport(source: .usb)
            report.stoppedBy = response.message ?? "rePossess.app does not see the tablet on USB"
        case .failed:
            report = RefreshReport(source: .usb)
            report.stoppedBy = response.message ?? "rePossess.app could not refresh over USB"
        }
        report.byApp = true
        return report
    }

    /// Sends the queue through the running app, or returns `nil` when no app listens or the app has no USB.
    /// - Throws: ``RefreshError/busy`` when another process holds the library's lock.
    public func sendPushes(timeout: TimeInterval = 300) async throws -> [PushRecord]? {
        guard isAppRunning else { return nil }
        let response: AppLinkResponse
        do {
            response = try await send(.sendPushes, timeout: timeout)
        } catch AppLinkError.notRunning {
            return nil
        }
        switch response.status {
        case .done: return response.pushes
        case .busy: throw RefreshError.busy
        case .noUSB: return nil
        case .failed: throw PushError(response.message ?? "rePossess.app could not send the queue")
        }
    }
}
