import Foundation

/// The routes of the tablet's USB web interface that rePossess uses.
///
/// On the owner's Paper Pure (software 3.29.0.153), the listing and both downloads work,
/// but `GET /thumbnail/<id>` and `POST /search/<keyword>` hang the interface
/// until the setting is switched off and on (checked on 2026-10-25).
/// So this type has no case for them, and the client can send nothing else.
/// The upload worked on the tablet on 2026-10-25.
public enum USBRoute: Sendable, Equatable, CustomStringConvertible {
    /// `GET /documents/` for the top level, or `GET /documents/<folder-id>`.
    case documents(folder: String?)
    /// `GET /download/<id>/rmdoc`: the document's archive.
    case rmdoc(id: String)
    /// `GET /download/<id>/pdf`: a PDF that the tablet renders.
    case pdf(id: String)
    /// `POST /upload`: a new document from a multipart field named `file`.
    case upload

    /// The path, after checking that any ID has only letters, digits, and hyphens.
    func path() throws -> String {
        switch self {
        case .documents(nil): return "/documents/"
        case .documents(let folder?): return "/documents/\(try Self.checked(folder))"
        case .rmdoc(let id): return "/download/\(try Self.checked(id))/rmdoc"
        case .pdf(let id): return "/download/\(try Self.checked(id))/pdf"
        case .upload: return "/upload"
        }
    }

    private static func checked(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 64,
            id.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D })
        else { throw USBError.invalidID(id) }
        return id
    }

    public var description: String { (try? path()) ?? "an invalid route" }
}

/// One entry of a folder listing.
///
/// The listing's keys are `ID`, `Type`, `fileType`, `ModifiedClient`, `Parent`,
/// `Bookmarked`, `CurrentPage`, and the name twice, as `VisibleName`
/// and the misspelled `VissibleName`.
public struct USBItem: Sendable, Equatable, Decodable {
    public var id: String
    /// `DocumentType` or `CollectionType`.
    public var type: String
    /// `notebook`, `pdf`, or `epub`, for documents.
    public var fileType: String?
    /// The time of the last change on the tablet, as ISO 8601 text.
    public var modifiedClient: String?
    /// The parent folder's ID, or empty for the top level.
    public var parent: String
    public var visibleName: String

    public init(
        id: String,
        type: String,
        fileType: String? = nil,
        modifiedClient: String? = nil,
        parent: String = "",
        visibleName: String
    ) {
        self.id = id
        self.type = type
        self.fileType = fileType
        self.modifiedClient = modifiedClient
        self.parent = parent
        self.visibleName = visibleName
    }

    public var isFolder: Bool { type == "CollectionType" }

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case type = "Type"
        case fileType
        case modifiedClient = "ModifiedClient"
        case parent = "Parent"
        case visibleName = "VisibleName"
        case vissibleName = "VissibleName"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "DocumentType"
        fileType = try c.decodeIfPresent(String.self, forKey: .fileType)
        modifiedClient = try c.decodeIfPresent(String.self, forKey: .modifiedClient)
        parent = try c.decodeIfPresent(String.self, forKey: .parent) ?? ""
        visibleName =
            try c.decodeIfPresent(String.self, forKey: .visibleName)
            ?? c.decodeIfPresent(String.self, forKey: .vissibleName) ?? ""
    }
}

/// An error from the USB web interface.
public enum USBError: Error, Equatable, CustomStringConvertible {
    /// No network interface has an address on the tablet's USB network, `10.11.99.0/24`.
    case notConnected
    /// The tablet refused the connection, so the USB web interface is off.
    case interfaceOff
    /// A request got no answer in time. The interface may be hung.
    case timedOut(route: String, seconds: Int)
    /// An earlier request in this refresh timed out, so the client sends no more requests.
    case stopped
    /// The tablet answered with an error status.
    case http(route: String, status: Int)
    /// The connection closed before the answer, perhaps after the request arrived.
    case connectionLost(String)
    /// The listing was not the JSON that the tablet sends.
    case malformedListing(String)
    /// A document or folder ID had characters other than letters, digits, and hyphens.
    case invalidID(String)
    /// macOS reported the tablet's network as offline while the Mac is on it,
    /// which is how a request fails when macOS does not let the program, or the app that started it,
    /// use the local network (TN3179).
    case localNetworkDenied
    /// Another network failure.
    case network(String)

    public var description: String {
        switch self {
        case .notConnected:
            "the tablet is not connected by USB: no network interface has an address on 10.11.99.0/24"
        case .interfaceOff:
            "the tablet refused the connection; turn on Settings > General settings > Storage > USB web interface"
        case .timedOut(let route, let seconds):
            "the tablet's USB web interface did not answer \(route) within \(seconds) seconds. "
                + "Switch the USB web interface off and on in Settings > General settings > Storage, "
                + "then refresh again. rePossess sent no more requests to the tablet."
        case .stopped:
            "rePossess stopped sending requests to the tablet after a timeout in this refresh. "
                + "Switch the USB web interface off and on, then refresh again."
        case .http(let route, let status): "the tablet answered \(route) with HTTP \(status)"
        case .connectionLost(let message): "the connection to the tablet closed before its answer: \(message)"
        case .malformedListing(let reason): "the tablet's listing could not be read: \(reason)"
        case .invalidID(let id): "not a tablet document ID: \(id)"
        case .localNetworkDenied:
            "macOS reported the tablet's USB network (10.11.99.1) as offline, although the Mac is on it. "
                + "This usually means that the app that started rePossess, such as an MCP client, "
                + "may not use the local network, or that macOS is still asking. "
                + "Open rePossess.app, which refreshes over USB for clients while it runs, "
                + "or allow the app in System Settings > Privacy & Security > Local Network, then try again."
        case .network(let message): "USB request failed: \(message)"
        }
    }
}

/// Sends one request to the tablet.
public protocol USBTransport: Sendable {
    /// Sends a GET request, and returns the status and body, or throws ``USBError``.
    func get(_ url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data)
    /// Sends a POST request with a body, and returns the status and body, or throws ``USBError``.
    func post(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws
        -> (status: Int, body: Data)
}

/// The live transport, with `URLSession`.
public struct URLSessionUSBTransport: USBTransport {
    private let session: URLSession
    private let usbPresent: @Sendable () -> Bool

    public init(usbPresent: @escaping @Sendable () -> Bool = USBNetwork.isPresent) {
        self.usbPresent = usbPresent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        return try await send(request, url: url, timeout: timeout)
    }

    public func post(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws
        -> (status: Int, body: Data)
    {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await send(request, url: url, timeout: timeout)
    }

    private func send(_ request: URLRequest, url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data)
    {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw USBError.network("not an HTTP response") }
            return (http.statusCode, data)
        } catch let error as URLError {
            throw Self.usbError(error, url: url, timeout: timeout, usbPresent: usbPresent())
        }
    }

    /// The ``USBError`` for a URL error.
    ///
    /// A request to the tablet that fails as offline while the Mac is on the tablet's network
    /// is a local network refusal: on 2026-10-25, the helper that Claude Desktop started
    /// failed with "The Internet connection appears to be offline" (NSURLErrorNotConnectedToInternet),
    /// and the system log showed its connection "unsatisfied (Local network prohibited)".
    static func usbError(_ error: URLError, url: URL, timeout: TimeInterval, usbPresent: Bool) -> USBError {
        switch error.code {
        case .timedOut:
            return .timedOut(route: url.path(), seconds: Int(timeout))
        case .cannotConnectToHost:
            return .interfaceOff
        case .networkConnectionLost:
            return .connectionLost(error.localizedDescription)
        case .notConnectedToInternet where usbPresent && url.host()?.hasPrefix("10.11.99.") == true:
            return .localNetworkDenied
        default:
            return .network(error.localizedDescription)
        }
    }
}

/// Reads the tablet's documents over its USB web interface.
///
/// It sends one request at a time, with short timeouts,
/// and after any timeout it sends nothing more, because the interface may be hung
/// and only switching the setting off and on clears it.
/// Make a new client for each refresh.
public actor USBClient {
    /// The tablet's address on its USB network.
    public static let defaultHost = URL(string: "http://10.11.99.1")!

    let host: URL
    let transport: any USBTransport
    let listTimeout: TimeInterval
    let downloadTimeout: TimeInterval
    let pdfTimeout: TimeInterval
    let uploadTimeout: TimeInterval
    let checkInterface: @Sendable () -> Bool
    let wait: @Sendable (Duration) async -> Void
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false
    /// The routes requested, in order, for tests and logs.
    public private(set) var requested: [USBRoute] = []

    /// - Parameters:
    ///   - listTimeout: Seconds for a folder listing, which took 13 ms on the tablet.
    ///   - downloadTimeout: Seconds for an rmdoc download; a 7.2 MB archive took under 1.5 s.
    ///   - pdfTimeout: Seconds for a PDF that the tablet renders; 10 pages took 5.3 s.
    ///   - uploadTimeout: Seconds for an upload; uploads of up to 29 KB took 0.03 to 0.25 s on the tablet.
    ///   - checkInterface: Whether the Mac is on the tablet's USB network.
    ///   - wait: Waits before a request is sent again after ``USBError/localNetworkDenied``.
    public init(
        host: URL = USBClient.defaultHost,
        transport: any USBTransport = URLSessionUSBTransport(),
        listTimeout: TimeInterval = 10,
        downloadTimeout: TimeInterval = 60,
        pdfTimeout: TimeInterval = 120,
        uploadTimeout: TimeInterval = 120,
        checkInterface: @escaping @Sendable () -> Bool = USBNetwork.isPresent,
        wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.wait = wait
        self.host = host
        self.transport = transport
        self.listTimeout = listTimeout
        self.downloadTimeout = downloadTimeout
        self.pdfTimeout = pdfTimeout
        self.uploadTimeout = uploadTimeout
        self.checkInterface = checkInterface
    }

    /// Lists one folder, or the top level.
    public func list(folder: String? = nil) async throws -> [USBItem] {
        let data = try await send(.documents(folder: folder), timeout: listTimeout)
        do {
            return try JSONDecoder().decode([USBItem].self, from: data)
        } catch {
            // The interface labels its JSON ISO-8859-1; try that if UTF-8 fails.
            if let text = String(data: data, encoding: .isoLatin1),
                let items = try? JSONDecoder().decode([USBItem].self, from: Data(text.utf8))
            {
                return items
            }
            throw USBError.malformedListing("\(error)")
        }
    }

    /// Lists every folder, one request at a time, from the top level down.
    public func listAll() async throws -> [USBItem] {
        var items: [USBItem] = []
        var folders: [String?] = [nil]
        var seen: Set<String> = []
        while !folders.isEmpty {
            let folder = folders.removeFirst()
            for item in try await list(folder: folder) where !seen.contains(item.id) {
                seen.insert(item.id)
                items.append(item)
                if item.isFolder { folders.append(item.id) }
            }
        }
        return items
    }

    /// Downloads a document's rmdoc archive.
    public func rmdoc(id: String) async throws -> Data {
        try await send(.rmdoc(id: id), timeout: downloadTimeout)
    }

    /// Downloads the PDF that the tablet renders for a document.
    public func pdf(id: String) async throws -> Data {
        try await send(.pdf(id: id), timeout: pdfTimeout)
    }

    /// Uploads one file, which the tablet adds as a new document at the top level.
    ///
    /// The answer has no document ID: the tablet assigns new document and page IDs,
    /// so a caller finds the document by listing the folder.
    /// The tablet answered HTTP 201 and `{"status":"Upload successful"}`,
    /// and a PDF named `repossess-test.pdf` became a document named "repossess-test".
    /// An rmdoc takes the name in its `.metadata` instead.
    public func upload(_ file: USBUpload) async throws {
        let (body, contentType) = file.multipart()
        _ = try await send(.upload, timeout: uploadTimeout, body: body, contentType: contentType)
    }

    private func send(_ route: USBRoute, timeout: TimeInterval, body: Data? = nil, contentType: String = "")
        async throws -> Data
    {
        let path = try route.path()
        await acquire()
        defer { release() }
        if stopped { throw USBError.stopped }
        guard checkInterface() else { throw USBError.notConnected }
        let url = URL(string: path, relativeTo: host)!.absoluteURL
        var attempt = 0
        while true {
            requested.append(route)
            do {
                let (status, body) =
                    if let body {
                        try await transport.post(url, body: body, contentType: contentType, timeout: timeout)
                    } else {
                        try await transport.get(url, timeout: timeout)
                    }
                guard (200 ..< 300).contains(status) else { throw USBError.http(route: path, status: status) }
                return body
            } catch USBError.localNetworkDenied where attempt < Self.localNetworkRetries.count {
                // macOS may refuse the first request while it asks whether the app may use the local network
                // (TN3179). The connection never opened, so nothing reached the tablet, and sending again is safe.
                await wait(Self.localNetworkRetries[attempt])
                attempt += 1
            } catch let error as USBError {
                if case .timedOut = error { stopped = true }
                throw error
            }
        }
    }

    /// The waits before each new try after macOS refused the local network:
    /// long enough for the owner to answer macOS's question, short enough for a client's call.
    static let localNetworkRetries: [Duration] = [.seconds(3), .seconds(5)]

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// A file to upload over USB.
public struct USBUpload: Sendable, Equatable {
    /// The kinds of file that the support article lists for the USB web interface.
    public enum Kind: String, Sendable, Equatable {
        case pdf, epub, rmdoc

        /// The part's content type. curl sent `application/pdf` for a test PDF
        /// and `application/octet-stream` for test rmdoc files, and the tablet accepted both.
        /// `application/epub+zip` for EPUB is unchecked.
        public var contentType: String {
            switch self {
            case .pdf: "application/pdf"
            case .epub: "application/epub+zip"
            case .rmdoc: "application/octet-stream"
            }
        }
    }

    /// The upload limit in reMarkable's support article (unchecked on the tablet).
    public static let maxBytes = 100_000_000

    public var kind: Kind
    /// The name of the document that the upload should make.
    public var title: String
    public var data: Data

    public init(kind: Kind, title: String, data: Data) {
        self.kind = kind
        self.title = title
        self.data = data
    }

    /// The part's file name: the title with the kind's extension.
    /// Quotes, slashes, backslashes, and control characters become hyphens,
    /// so that the multipart header stays well formed.
    public var fileName: String { "\(fileStem).\(kind.rawValue)" }

    /// The name that the tablet gives a PDF or an EPUB: the file name without its extension
    /// (checked for one PDF with an ASCII name).
    public var fileStem: String {
        String(
            String.UnicodeScalarView(
                title.unicodeScalars.map { scalar in
                    "\"\\/".unicodeScalars.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
                        ? "-" : scalar
                }
            )
        )
    }

    /// The names under which the upload may appear in a listing.
    public var expectedNames: Set<String> { [title, fileStem] }

    /// The multipart body with one field, `file`, and its content type.
    func multipart(boundary: String = "repossess-\(UUID().uuidString)") -> (body: Data, contentType: String) {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(kind.contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }
}

/// Finds the tablet's USB network.
public enum USBNetwork {
    /// Whether any network interface has an IPv4 address in `10.11.99.0/24`,
    /// the network that the tablet makes over USB.
    /// The Mac's address on it changes (checks saw `10.11.99.11` and `10.11.99.2`),
    /// so this checks the network, not one address.
    @Sendable public static func isPresent() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                if ip >> 8 == 0x0A0B63 { return true }  // 10.11.99.x
            }
            pointer = entry.pointee.ifa_next
        }
        return false
    }
}
