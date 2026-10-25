import Foundation

/// The routes of the tablet's USB web interface that rePossess uses.
///
/// On Mattt's Paper Pure (software 3.29.0.153), the listing and both downloads work,
/// but `GET /thumbnail/<id>` and `POST /search/<keyword>` hang the interface
/// until the setting is switched off and on (spike 1, 2026-10-25).
/// So this type has no case for them, and the client can send nothing else.
/// Phase 1 reads only, so the upload route is not here either.
public enum USBRoute: Sendable, Equatable, CustomStringConvertible {
    /// `GET /documents/` for the top level, or `GET /documents/<folder-id>`.
    case documents(folder: String?)
    /// `GET /download/<id>/rmdoc`: the document's archive.
    case rmdoc(id: String)
    /// `GET /download/<id>/pdf`: a PDF that the tablet renders.
    case pdf(id: String)

    /// The path, after checking that any ID has only letters, digits, and hyphens.
    func path() throws -> String {
        switch self {
        case .documents(nil): return "/documents/"
        case .documents(let folder?): return "/documents/\(try Self.checked(folder))"
        case .rmdoc(let id): return "/download/\(try Self.checked(id))/rmdoc"
        case .pdf(let id): return "/download/\(try Self.checked(id))/pdf"
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
/// and the misspelled `VissibleName` (spike 1).
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
    /// The listing was not the JSON that the tablet sends.
    case malformedListing(String)
    /// A document or folder ID had characters other than letters, digits, and hyphens.
    case invalidID(String)
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
        case .malformedListing(let reason): "the tablet's listing could not be read: \(reason)"
        case .invalidID(let id): "not a tablet document ID: \(id)"
        case .network(let message): "USB request failed: \(message)"
        }
    }
}

/// Sends one GET request to the tablet.
public protocol USBTransport: Sendable {
    /// Returns the status and body, or throws ``USBError``.
    func get(_ url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data)
}

/// The live transport, with `URLSession`.
public struct URLSessionUSBTransport: USBTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw USBError.network("not an HTTP response") }
            return (http.statusCode, data)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw USBError.timedOut(route: url.path(), seconds: Int(timeout))
            case .cannotConnectToHost:
                throw USBError.interfaceOff
            case .cannotFindHost, .notConnectedToInternet, .networkConnectionLost:
                throw USBError.network(error.localizedDescription)
            default:
                throw USBError.network(error.localizedDescription)
            }
        }
    }
}

/// Reads the tablet's documents over its USB web interface.
///
/// It sends one request at a time, with short timeouts,
/// and after any timeout it sends nothing more, because the interface may be hung
/// and only switching the setting off and on clears it (spike 1).
/// Make a new client for each refresh.
public actor USBClient {
    /// The tablet's address on its USB network.
    public static let defaultHost = URL(string: "http://10.11.99.1")!

    let host: URL
    let transport: any USBTransport
    let listTimeout: TimeInterval
    let downloadTimeout: TimeInterval
    let pdfTimeout: TimeInterval
    let checkInterface: @Sendable () -> Bool
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false
    /// The routes requested, in order, for tests and logs.
    public private(set) var requested: [USBRoute] = []

    /// - Parameters:
    ///   - listTimeout: Seconds for a folder listing, which took 13 ms in spike 1.
    ///   - downloadTimeout: Seconds for an rmdoc download; a 7.2 MB archive took under 1.5 s.
    ///   - pdfTimeout: Seconds for a PDF that the tablet renders; 10 pages took 5.3 s.
    ///   - checkInterface: Whether the Mac is on the tablet's USB network.
    public init(
        host: URL = USBClient.defaultHost,
        transport: any USBTransport = URLSessionUSBTransport(),
        listTimeout: TimeInterval = 10,
        downloadTimeout: TimeInterval = 60,
        pdfTimeout: TimeInterval = 120,
        checkInterface: @escaping @Sendable () -> Bool = USBNetwork.isPresent
    ) {
        self.host = host
        self.transport = transport
        self.listTimeout = listTimeout
        self.downloadTimeout = downloadTimeout
        self.pdfTimeout = pdfTimeout
        self.checkInterface = checkInterface
    }

    /// Lists one folder, or the top level.
    public func list(folder: String? = nil) async throws -> [USBItem] {
        let data = try await send(.documents(folder: folder), timeout: listTimeout)
        do {
            return try JSONDecoder().decode([USBItem].self, from: data)
        } catch {
            // The interface labels its JSON ISO-8859-1 (spike 1); try that if UTF-8 fails.
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

    private func send(_ route: USBRoute, timeout: TimeInterval) async throws -> Data {
        let path = try route.path()
        await acquire()
        defer { release() }
        if stopped { throw USBError.stopped }
        guard checkInterface() else { throw USBError.notConnected }
        requested.append(route)
        do {
            let url = URL(string: path, relativeTo: host)!.absoluteURL
            let (status, body) = try await transport.get(url, timeout: timeout)
            guard (200 ..< 300).contains(status) else { throw USBError.http(route: path, status: status) }
            return body
        } catch let error as USBError {
            if case .timedOut = error { stopped = true }
            throw error
        }
    }

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

/// Finds the tablet's USB network.
public enum USBNetwork {
    /// Whether any network interface has an IPv4 address in `10.11.99.0/24`,
    /// the network that the tablet makes over USB.
    /// The Mac's address on it changes (spike 1 saw `10.11.99.11` and `10.11.99.2`),
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
