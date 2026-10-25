import Foundation

/// An in-memory stand-in for reMarkable's cloud, for tests.
///
/// It is internal; tests reach it with `@testable import`.
/// It enforces the behavior that clients reported in 2026:
/// `rm-filename` on every file request (remarkable-mcp issue 101, from 2026-05-18),
/// a bearer token on every request, a CRC-32C and a matching hash on every upload,
/// a root index sorted by ID (ddvk/rmapi issue 75), and a root update only from the current generation.
/// A root update keeps the schema of the root index it names, as spike 6 saw on 2026-10-25.
/// It can add rate-limit headers, wait before it answers, fail file reads on purpose,
/// change the generation before a root update, and lose the answer to a root update.
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

    /// The one-time code that registration accepts.
    static let oneTimeCode = "abcd2345"
    /// Headers added to every response, such as `x-ratelimit-remaining`.
    var extraHeaders: [String: String] = [:]
    /// How long each request takes.
    var latency: Duration = .zero
    /// Statuses to answer the next file reads with, one each, before serving them.
    var fileFailures: [Int] = []
    /// How many root updates find the generation changed by another device first.
    var interveningSyncs = 0
    /// What happens to the next root update's answer.
    var rootUpdateLoss: RootUpdateLoss?
    /// Whether root reads fail after a lost root update, as when the network is down.
    var failRootReadsAfterLoss = false
    private var lostRootUpdate = false
    private var inFlight = 0
    /// The most requests that were in flight at once.
    private(set) var maxInFlight = 0
    /// The bytes in every response body so far.
    private(set) var bytesServed = 0

    /// How a root update's answer goes missing.
    enum RootUpdateLoss {
        /// The server applies the update, and the answer is lost.
        case afterApplying
        /// The request never reaches the server.
        case beforeApplying
        /// The server answers 503 after it applies the update.
        case serverErrorAfterApplying
    }

    init() {}

    func set(interveningSyncs: Int = 0, rootUpdateLoss: RootUpdateLoss? = nil, failRootReadsAfterLoss: Bool = false) {
        self.interveningSyncs = interveningSyncs
        self.rootUpdateLoss = rootUpdateLoss
        self.failRootReadsAfterLoss = failRootReadsAfterLoss
    }

    /// The root index that the root names, parsed.
    func currentRootIndex() throws -> SyncIndex {
        guard let blob = blobs[rootHash] else { return SyncIndex(schema: .v4, infoID: ".", infoSize: 0, entries: []) }
        return try SyncIndex(parsing: blob.data)
    }

    /// The files of a document in the root, by name.
    func documentFiles(id: String) throws -> [String: Data] {
        guard let entry = try currentRootIndex().entries.first(where: { $0.id == id }),
            let index = blobs[entry.hash]
        else { return [:] }
        var files: [String: Data] = [:]
        for file in try SyncIndex(parsing: index.data).entries {
            files[file.id] = blobs[file.hash]?.data
        }
        return files
    }

    /// The writes that the fake received, as method and path.
    var writes: [String] {
        requests.filter { $0.method == "PUT" }.map { "\($0.method) \($0.headers["rm-filename"] ?? "")" }
    }

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

    func clearRequests() {
        requests = []
        maxInFlight = 0
        bytesServed = 0
    }

    func set(extraHeaders: [String: String] = [:], latency: Duration = .zero, fileFailures: [Int] = []) {
        self.extraHeaders = extraHeaders
        self.latency = latency
        self.fileFailures = fileFailures
    }

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
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if latency > .zero { try await Task.sleep(for: latency) }
        if request.method == "PUT", request.url.path() == "/sync/v3/root", let loss = rootUpdateLoss {
            rootUpdateLoss = nil
            switch loss {
            case .beforeApplying:
                lostRootUpdate = true
                throw URLError(.networkConnectionLost)
            case .afterApplying:
                _ = updateRoot(request)
                lostRootUpdate = true
                throw URLError(.networkConnectionLost)
            case .serverErrorAfterApplying:
                _ = updateRoot(request)
                return HTTPResponse(status: 503)
            }
        }
        if lostRootUpdate, failRootReadsAfterLoss, request.url.path() == "/sync/v4/root" {
            throw URLError(.notConnectedToInternet)
        }
        var response = answer(request)
        response.headers.merge(extraHeaders) { current, _ in current }
        bytesServed += response.body.count
        return response
    }

    private func answer(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.url.path()
        let bearer = request.headers["authorization"]
        if request.method == "POST", path == "/token/json/2/device/new" {
            guard bearer == "Bearer", request.headers["content-type"] == "application/json",
                let body = request.body,
                let object = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                object["deviceDesc"] == "desktop-macos",
                let deviceID = object["deviceID"], UUID(uuidString: deviceID) != nil, deviceID == deviceID.lowercased()
            else { return HTTPResponse(status: 400, body: Data("bad registration".utf8)) }
            guard object["code"] == Self.oneTimeCode else {
                return HTTPResponse(status: 400, body: Data("invalid one-time code".utf8))
            }
            return HTTPResponse(status: 200, body: Data(Self.deviceToken.utf8))
        }
        if request.method == "POST", path == "/token/json/2/user/new" {
            guard bearer == "Bearer \(Self.deviceToken)" else { return HTTPResponse(status: 401) }
            return HTTPResponse(status: 200, body: Data(Self.userToken.utf8))
        }
        guard bearer == "Bearer \(Self.userToken)" else { return HTTPResponse(status: 401) }
        if request.method == "PUT", path == "/sync/v3/root" {
            return updateRoot(request)
        }
        if request.method == "PUT", path.hasPrefix("/sync/v3/files/") {
            let hash = String(path.dropFirst("/sync/v3/files/".count))
            guard let name = request.headers["rm-filename"], !name.isEmpty else {
                return HTTPResponse(status: 400, body: Data(#"{"message":"missing rm-filename"}"#.utf8))
            }
            return storeBlob(hash: hash, name: name, request: request)
        }
        guard request.method == "GET" else { return HTTPResponse(status: 405) }
        if path == "/sync/v4/root" {
            let body = #"{"hash":"\#(rootHash)","generation":\#(generation),"schemaVersion":\#(schemaVersion)}"#
            return HTTPResponse(status: 200, body: Data(body.utf8))
        }
        if path.hasPrefix("/sync/v3/files/") {
            if !fileFailures.isEmpty { return HTTPResponse(status: fileFailures.removeFirst()) }
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

    private func storeBlob(hash: String, name: String, request: HTTPRequest) -> HTTPResponse {
        let body = request.body ?? Data()
        guard request.headers["x-goog-hash"] == CRC32C.googHash(body) else {
            return HTTPResponse(status: 400, body: Data(#"{"message":"crc32c mismatch"}"#.utf8))
        }
        var expected = ContentHash.sha256Hex(body)
        if name.hasSuffix(".docSchema") {
            guard let index = try? SyncIndex(parsing: body) else {
                return HTTPResponse(status: 400, body: Data(#"{"message":"invalid index"}"#.utf8))
            }
            if name == "root.docSchema", !index.isSorted {
                return HTTPResponse(status: 400, body: Data(#"{"message":"invalid root schema"}"#.utf8))
            }
            if index.schema == .v3, let v3 = try? index.hash() { expected = v3 }
        }
        guard expected == hash else {
            return HTTPResponse(status: 400, body: Data(#"{"message":"invalid hash"}"#.utf8))
        }
        blobs[hash] = Blob(name: name, data: body)
        return HTTPResponse(status: 200)
    }

    private func updateRoot(_ request: HTTPRequest) -> HTTPResponse {
        if interveningSyncs > 0 {
            interveningSyncs -= 1
            generation += 1
        }
        guard request.headers["content-type"] == "application/json", let body = request.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let hash = json["hash"] as? String,
            let sent = (json["generation"] as? NSNumber)?.int64Value,
            json["broadcast"] is Bool
        else { return HTTPResponse(status: 400) }
        guard sent == generation else {
            return HTTPResponse(status: 412, body: Data(#"{"message":"precondition failed"}"#.utf8 + [0x0A]))
        }
        guard let blob = blobs[hash], blob.name == "root.docSchema", let index = try? SyncIndex(parsing: blob.data)
        else { return HTTPResponse(status: 400) }
        rootHash = hash
        schemaVersion = index.schema.rawValue
        generation += 1
        return HTTPResponse(status: 200, body: Data(#"{"hash":"\#(hash)","generation":\#(generation)}"#.utf8))
    }

    /// Changes one stored blob's bytes without changing its hash, to test hash checks.
    func corrupt(hash: String) {
        blobs[hash]?.data.append(0x00)
    }
}
