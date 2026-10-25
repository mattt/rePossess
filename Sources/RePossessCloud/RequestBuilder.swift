import Foundation

/// The root hash and generation that `GET /sync/v4/root` returns.
public struct RootState: Sendable, Equatable, Codable {
    /// The hash of the root index; empty on a new account (rmfakecloud behavior).
    public var hash: String
    /// The generation, a counter for compare-and-set.
    public var generation: Int64
    /// The schema version of the account's root index, 3 or 4.
    public var schemaVersion: Int?

    public init(hash: String, generation: Int64, schemaVersion: Int? = nil) {
        self.hash = hash
        self.generation = generation
        self.schemaVersion = schemaVersion
    }
}

/// Builds the requests of the sync protocol as plain values.
///
/// Phase 2 registers the device, renews the user token, reads the root, and downloads blobs.
/// The write requests of spike 6 come back in phase 3.
/// Each method cites the rmapi-js line it follows (commit 824f0ad).
public struct RequestBuilder: Sendable {
    /// The host for tokens.
    public var authHost: URL
    /// The host for sync requests.
    public var syncHost: URL

    public init(authHost: URL = CloudHosts.auth, syncHost: URL = CloudHosts.defaultSync) {
        self.authHost = authHost
        self.syncHost = syncHost
    }

    /// The device description that rePossess registers as.
    public static let deviceDescription = "desktop-macos"

    /// Registers a new device with a one-time code; the response body is the device token.
    ///
    /// rmapi-js `src/index.ts` lines 413-442: `POST /token/json/2/device/new`
    /// with an empty bearer and a JSON body of `code`, `deviceDesc`, and `deviceID`.
    /// The `Content-Type` came with rmapi-js commit 39b1daf (2026-09-15).
    public func registerDevice(code: String, deviceID: UUID) throws -> HTTPRequest {
        guard code.count == 8, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw CloudError.invalidCode
        }
        let body = [
            "code": code,
            "deviceDesc": Self.deviceDescription,
            "deviceID": deviceID.uuidString.lowercased(),
        ]
        return HTTPRequest(
            method: "POST",
            url: authHost.appending(path: "token/json/2/device/new"),
            headers: ["Authorization": "Bearer", "Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        )
    }

    /// Exchanges the device token for a user token; the response body is the user token.
    ///
    /// rmapi-js `src/index.ts` lines 2649-2665: `POST /token/json/2/user/new`
    /// with the device token as bearer and no body.
    public func renewUserToken(deviceToken: String) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            url: authHost.appending(path: "token/json/2/user/new"),
            headers: ["Authorization": "Bearer \(deviceToken)"]
        )
    }

    /// Reads the root hash, generation, and schema version.
    ///
    /// rmapi-js `src/raw.ts` lines 1014-1028: `GET /sync/v4/root`.
    public func getRoot(userToken: String) -> HTTPRequest {
        HTTPRequest(
            method: "GET",
            url: syncHost.appending(path: "sync/v4/root"),
            headers: ["Authorization": "Bearer \(userToken)"]
        )
    }

    /// Downloads a blob by hash.
    ///
    /// rmapi-js `src/raw.ts` lines 1030-1042: `GET /sync/v3/files/<hash>`
    /// with `rm-filename` set to the file's name, such as `root.docSchema`,
    /// `<docid>.docSchema`, or `<docid>.pdf`. The server validates the header since
    /// 2026-05-18 (rmapi-js commit 73d474a; remarkable-mcp issue 101).
    public func getFile(hash: String, fileName: String, userToken: String) throws -> HTTPRequest {
        guard ContentHash.isValid(hash) else { throw CloudError.invalidHash(hash) }
        return HTTPRequest(
            method: "GET",
            url: syncHost.appending(path: "sync/v3/files/\(hash)"),
            headers: ["Authorization": "Bearer \(userToken)", "rm-filename": fileName]
        )
    }

    /// The file name that `rm-filename` carries for an index blob.
    public static func indexFileName(for id: String) -> String {
        "\(id).docSchema"
    }
}
