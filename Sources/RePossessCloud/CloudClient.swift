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

/// What a push to the cloud did.
public enum CloudPushOutcome: Sendable, Equatable {
    /// The root lists the document: the root update succeeded, or a read after a lost answer found it.
    case sent(generation: Int64?)
    /// The root update got no answer, and the read of the root that followed failed too,
    /// so whether the document is in the account is unknown.
    case unknown(String)

    /// Whether the root lists the document.
    public var isSent: Bool {
        if case .sent = self { return true }
        return false
    }
}

/// Reads the sync store with a user token, and adds new documents to it.
///
/// It reads the root, indexes, and files.
/// The one write is ``push(_:attempts:progress:)``, which adds a new document;
/// nothing here changes or removes a document.
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

    /// Reads the root and its index, and checks the index's hash.
    public func rootIndex() async throws -> (root: RootState, index: SyncIndex) {
        let root = try await root()
        let fetched = try await index(id: "root", hash: root.hash)
        guard fetched.hashMatches else {
            throw CloudError.hashMismatch(expected: root.hash, actual: (try? fetched.index.hash()) ?? "")
        }
        return (root, fetched.index)
    }

    /// Whether the account's root lists a document.
    public func contains(documentID: String) async throws -> Bool {
        try await rootIndex().index.entries.contains { $0.id == documentID }
    }

    /// Adds a new document to the top level of the account.
    ///
    /// It reads the root, plans the upload in the account's schema, uploads every blob,
    /// and then updates the root with the generation that it read.
    /// When the root changed in between (``CloudError/generationConflict``),
    /// the account is unchanged apart from blobs that no index names,
    /// so it reads the root again and plans again, up to `attempts` times.
    ///
    /// No write is ever sent twice after a lost answer.
    /// When the root update gets no answer, or HTTP 429 or a 5xx status,
    /// it reads the root again and looks for the document's ID,
    /// because the update may have happened (rmapi-js `src/index.ts` lines 776-783).
    /// rePossess chooses the document ID, so a later push of the same document
    /// finds it in the root and stops there.
    ///
    /// - Returns: ``CloudPushOutcome/sent(generation:)`` when the root lists the document,
    ///   or ``CloudPushOutcome/unknown(_:)`` when neither the update nor the check that followed answered.
    /// - Throws: An error when the document was not added: a refused plan, a refused blob,
    ///   a refused root update, a generation conflict on every attempt,
    ///   or ``CloudError/rootUpdateNotApplied(_:)``.
    public func push(
        _ document: NewDocument,
        attempts: Int = 3,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> CloudPushOutcome {
        for attempt in 1 ... max(attempts, 1) {
            let (root, index) = try await rootIndex()
            if index.entries.contains(where: { $0.id == document.documentID }) {
                progress("The cloud root already lists \(document.documentID).")
                return .sent(generation: root.generation)
            }
            let plan = try UploadPlanner.plan(document, root: root, rootIndex: index)
            for put in plan.blobPuts {
                let response = try await transport.send(
                    builder.putFile(hash: put.hash, fileName: put.fileName, body: put.body, userToken: userToken)
                )
                guard (200 ..< 300).contains(response.status) else { throw CloudError.from(response) }
                progress("PUT \(put.fileName), \(put.body.count) bytes: HTTP \(response.status)")
            }
            let request = try builder.putRoot(
                hash: plan.newRootHash,
                generation: plan.baseGeneration,
                userToken: userToken
            )
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch {
                return try await check(document.documentID, after: "\(error)", progress: progress)
            }
            if (200 ..< 300).contains(response.status) {
                progress("PUT /sync/v3/root from generation \(plan.baseGeneration): HTTP \(response.status)")
                let state = try? JSONDecoder().decode(RootState.self, from: response.body)
                return .sent(generation: state?.generation)
            }
            if response.status == 429 || (500 ..< 600).contains(response.status) {
                return try await check(document.documentID, after: "HTTP \(response.status)", progress: progress)
            }
            let error = CloudError.from(response)
            guard error == .generationConflict, attempt < attempts else { throw error }
            progress("The cloud root changed during the upload; planning again.")
        }
        throw CloudError.generationConflict
    }

    /// After a root update without an answer, reads the root and looks for the document.
    private func check(
        _ documentID: String,
        after reason: String,
        progress: @Sendable (String) -> Void
    ) async throws -> CloudPushOutcome {
        progress("The root update got no answer (\(reason)); reading the root to look for \(documentID).")
        let found: Bool
        do {
            found = try await contains(documentID: documentID)
        } catch {
            return .unknown("the root update got no answer (\(reason)), and the root could not be read: \(error)")
        }
        guard found else { throw CloudError.rootUpdateNotApplied(reason) }
        return .sent(generation: nil)
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
