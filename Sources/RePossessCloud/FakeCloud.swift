import Foundation

/// An in-memory stand-in for the read side of reMarkable's cloud, for tests.
///
/// It is internal; tests reach it with `@testable import`.
/// It enforces the behavior that clients reported in 2026:
/// `rm-filename` on every file request (remarkable-mcp issue 101, from 2026-05-18),
/// and a bearer token on every request.
/// It answers only the read requests; any other request gets 405.
actor FakeCloud: HTTPTransport {
    struct Blob {
        var name: String
        var data: Data
    }

    static let deviceToken = jwt(["device-id": "44444444-4444-4444-8444-444444444444", "device-desc": "desktop-macos"])
    static let userToken = jwt(["tectonic": "eu", "scopes": "sync:tortoise", "exp": 1_900_000_000])

    var blobs: [String: Blob] = [:]
    var rootHash = ""
    var generation: Int64 = 1_777_000_000_000_000
    var schemaVersion = 3
    private(set) var requests: [HTTPRequest] = []

    init() {}

    /// Makes an unsigned JWT with the given payload.
    static func jwt(_ payload: [String: Any]) -> String {
        func encode(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(["alg": "HS256", "typ": "JWT"])).\(encode(payload)).c2lnbmF0dXJl"
    }

    func seed(name: String, data: Data, hash: String? = nil) {
        blobs[hash ?? ContentHash.sha256Hex(data)] = Blob(name: name, data: data)
    }

    func clearRequests() { requests = [] }

    /// Seeds a document's files and its index, and returns its root entry.
    func seedDocument(id: String, files: [(String, Data)], schema: SchemaVersion = .v3) throws -> IndexEntry {
        var entries: [IndexEntry] = []
        for (name, data) in files {
            seed(name: name, data: data)
            entries.append(
                IndexEntry(hash: ContentHash.sha256Hex(data), kind: .file, id: name, subfiles: 0, size: data.count)
            )
        }
        let index = SyncIndex.make(id: id, entries: entries, schema: schema)
        let hash = try index.hash()
        seed(name: "\(id).docSchema", data: index.serialized(), hash: hash)
        return IndexEntry(
            hash: hash,
            kind: schema == .v3 ? .collection : .file,
            id: id,
            subfiles: entries.count,
            size: index.totalSize
        )
    }

    /// Seeds a root index from entries and points the root at it, in a new generation.
    func seedRoot(_ entries: [IndexEntry], schema: SchemaVersion = .v3) throws {
        let index = SyncIndex.make(id: "root", entries: entries, schema: schema)
        let hash = try index.hash()
        seed(name: "root.docSchema", data: index.serialized(), hash: hash)
        rootHash = hash
        schemaVersion = schema.rawValue
        generation += 1
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard CloudHosts.isAllowed(request.url) else { throw CloudError.hostNotAllowed(request.url.host() ?? "") }
        let path = request.url.path()
        let bearer = request.headers["authorization"]
        if request.method == "POST", path == "/token/json/2/user/new" {
            guard bearer == "Bearer \(Self.deviceToken)" else { return HTTPResponse(status: 401) }
            return HTTPResponse(status: 200, body: Data(Self.userToken.utf8))
        }
        guard bearer == "Bearer \(Self.userToken)" else { return HTTPResponse(status: 401) }
        guard request.method == "GET" else { return HTTPResponse(status: 405) }
        if path == "/sync/v4/root" {
            let body = #"{"hash":"\#(rootHash)","generation":\#(generation),"schemaVersion":\#(schemaVersion)}"#
            return HTTPResponse(status: 200, body: Data(body.utf8))
        }
        if path.hasPrefix("/sync/v3/files/") {
            let hash = String(path.dropFirst("/sync/v3/files/".count))
            guard let name = request.headers["rm-filename"], !name.isEmpty else {
                return HTTPResponse(status: 400, body: Data(#"{"message":"missing rm-filename"}"#.utf8))
            }
            guard let blob = blobs[hash] else { return HTTPResponse(status: 404) }
            guard blob.name == name else {
                return HTTPResponse(status: 400, body: Data(#"{"message":"filename mismatch"}"#.utf8))
            }
            return HTTPResponse(status: 200, body: blob.data)
        }
        return HTTPResponse(status: 404)
    }

    /// Changes one stored blob's bytes without changing its hash, to test hash checks.
    func corrupt(hash: String) {
        blobs[hash]?.data.append(0x00)
    }
}
