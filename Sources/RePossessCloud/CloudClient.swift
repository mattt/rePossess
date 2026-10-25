import Foundation

/// An index downloaded from the server, with the result of its hash check.
public struct FetchedIndex: Sendable, Equatable {
    /// The parsed index.
    public var index: SyncIndex
    /// Whether the index hashes to the hash that named it.
    public var hashMatches: Bool
}

/// Renews user tokens.
public struct CloudAuth: Sendable {
    let transport: any HTTPTransport
    let builder: RequestBuilder

    public init(transport: any HTTPTransport, authHost: URL = CloudHosts.auth) {
        self.transport = transport
        self.builder = RequestBuilder(authHost: authHost)
    }

    /// Exchanges the device token for a user token, which lives only in memory.
    public func renewUserToken(deviceToken: String) async throws -> String {
        let response = try await transport.send(builder.renewUserToken(deviceToken: deviceToken))
        guard (200 ..< 300).contains(response.status) else { throw CloudError.from(response) }
        let token = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.split(separator: ".").count == 3 else { throw CloudError.malformedToken }
        return token
    }
}

/// Reads the sync store with a user token.
///
/// It reads only: the root, indexes, and files.
/// Nothing here writes to the account.
public struct CloudClient: Sendable {
    let transport: any HTTPTransport
    let builder: RequestBuilder
    let userToken: String

    /// Creates a client for the sync host that the user token names, unless `syncHost` overrides it.
    public init(transport: any HTTPTransport, userToken: String, syncHost: URL? = nil) {
        self.transport = transport
        self.userToken = userToken
        let host = syncHost ?? CloudHosts.sync(for: try? TokenClaims(jwt: userToken))
        self.builder = RequestBuilder(syncHost: host)
    }

    /// The sync host in use.
    public var syncHost: URL { builder.syncHost }

    /// Reads the root hash, the generation, and the schema version.
    public func root() async throws -> RootState {
        let response = try await transport.send(builder.getRoot(userToken: userToken))
        guard (200 ..< 300).contains(response.status) else { throw CloudError.from(response) }
        do {
            return try JSONDecoder().decode(RootState.self, from: response.body)
        } catch {
            throw CloudError.malformedResponse("root: \(error)")
        }
    }

    /// Downloads and parses an index.
    ///
    /// - Parameters:
    ///   - id: `root`, or a document ID.
    ///   - hash: The hash of the index.
    public func index(id: String, hash: String) async throws -> FetchedIndex {
        if hash.isEmpty, id == "root" {
            return FetchedIndex(index: SyncIndex(schema: .v4, infoID: ".", infoSize: 0, entries: []), hashMatches: true)
        }
        let data = try await blob(hash: hash, fileName: RequestBuilder.indexFileName(for: id))
        let index = try SyncIndex(parsing: data)
        return FetchedIndex(index: index, hashMatches: (try? index.hash()) == hash)
    }

    /// Downloads a file named in a document's index and checks its hash.
    public func file(_ entry: IndexEntry) async throws -> Data {
        let data = try await blob(hash: entry.hash, fileName: entry.id)
        let actual = ContentHash.sha256Hex(data)
        guard actual == entry.hash else { throw CloudError.hashMismatch(expected: entry.hash, actual: actual) }
        return data
    }

    func blob(hash: String, fileName: String) async throws -> Data {
        let response = try await transport.send(builder.getFile(hash: hash, fileName: fileName, userToken: userToken))
        guard (200 ..< 300).contains(response.status) else { throw CloudError.from(response) }
        return response.body
    }
}

/// Holds the device token's source and renews the user token when it nears its expiry.
///
/// Every request goes through one ``PacedTransport``,
/// so a session has at most ``Pacing/maxConcurrent`` requests in flight
/// and honors the server's rate limits across all of its clients.
public actor CloudSession {
    private let transport: PacedTransport
    private let deviceToken: @Sendable () throws -> String
    private let syncHost: URL?
    private let tokenTimeout: Duration?
    private var userToken: String?
    private var expiry: Date?

    /// - Parameters:
    ///   - transport: Sends the requests; the session paces them.
    ///   - deviceToken: Reads the device token, such as ``DeviceTokenKeychain/read()``.
    ///   - syncHost: Overrides the sync host that the user token names.
    ///   - tokenTimeout: How long to wait for the device token, or `nil` to wait as long as it takes.
    ///     macOS can hold the Keychain read until the user answers a permission dialog;
    ///     a server that no one watches should not wait forever.
    ///   - pacing: The concurrency, retries, and waits of the requests.
    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        deviceToken: @escaping @Sendable () throws -> String = DeviceTokenKeychain.read,
        syncHost: URL? = nil,
        tokenTimeout: Duration? = nil,
        pacing: Pacing = Pacing()
    ) {
        self.transport = PacedTransport(base: transport, pacing: pacing)
        self.deviceToken = deviceToken
        self.syncHost = syncHost
        self.tokenTimeout = tokenTimeout
    }

    /// The requests and bytes that the session has sent and received.
    public func usage() async -> TransportUsage {
        await transport.usage
    }

    /// Reads the device token on another thread, and gives up after `tokenTimeout`.
    /// A read that times out keeps its thread until macOS answers it.
    private func readDeviceToken() async throws -> String {
        guard let tokenTimeout else { return try deviceToken() }
        let read = deviceToken
        return try await withThrowingTaskGroup(of: String.self) { group in
            let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
            Thread.detachNewThread {
                do {
                    continuation.yield(try read())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            group.addTask {
                for try await token in stream { return token }
                throw CloudError.keychainTimedOut
            }
            group.addTask {
                try await Task.sleep(for: tokenTimeout)
                throw CloudError.keychainTimedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// A client with a user token that is valid for at least five more minutes.
    public func client() async throws -> CloudClient {
        if let userToken, let expiry, expiry.timeIntervalSinceNow > 300 {
            return CloudClient(transport: transport, userToken: userToken, syncHost: syncHost)
        }
        let device = try await readDeviceToken()
        let token = try await CloudAuth(transport: transport).renewUserToken(deviceToken: device)
        userToken = token
        // Without an `exp` claim, renew after an hour; the live service hinted 3 hours (spike 6).
        expiry = (try? TokenClaims(jwt: token))?.expiration ?? Date().addingTimeInterval(3600)
        return CloudClient(transport: transport, userToken: token, syncHost: syncHost)
    }
}
