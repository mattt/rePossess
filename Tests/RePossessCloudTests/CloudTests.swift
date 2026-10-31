import Foundation
import Testing

@testable import RePossessCloud

/// Invented fixtures, written from the formats in rmapi-js `src/raw.ts`.
/// No ID, hash, or name here comes from a real account.
enum Fixtures {
    static let hashA = String(repeating: "a", count: 64)
    static let hashB = String(repeating: "b", count: 64)
    static let hashC = String(repeating: "c", count: 64)
    static let hashD = String(repeating: "d", count: 64)
    static let docOne = "11111111-1111-4111-8111-111111111111"
    static let docTwo = "22222222-2222-4222-8222-222222222222"
    static let page = "33333333-3333-4333-8333-333333333333"

    static let rootV3 = """
        3
        \(hashA):80000000:\(docOne):4:1200
        \(hashB):80000000:\(docTwo):3:900

        """

    static let rootV4 = """
        4
        0:.:2:2100
        \(hashA):0:\(docOne):4:1200
        \(hashB):0:\(docTwo):3:900

        """

    static let documentV4 = """
        4
        0:\(docTwo):3:900
        \(hashC):0:\(docTwo).content:0:400
        \(hashD):0:\(docTwo).metadata:0:300
        \(hashA):0:\(docTwo)/\(page).rm:0:200

        """
}

@Suite struct HashingTests {
    @Test func sha256MatchesKnownVector() {
        #expect(
            ContentHash.sha256Hex(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test func hashValidation() {
        #expect(ContentHash.isValid(Fixtures.hashA))
        #expect(!ContentHash.isValid(Fixtures.hashA.uppercased()))
        #expect(!ContentHash.isValid("abc"))
        #expect(throws: CloudError.self) { try ContentHash.bytes("zz") }
    }
}

@Suite struct IndexTests {
    @Test func parsesSchema3Root() throws {
        let index = try SyncIndex(parsing: Data(Fixtures.rootV3.utf8))
        #expect(index.schema == .v3)
        #expect(index.infoID == nil)
        #expect(index.entries.map(\.id) == [Fixtures.docOne, Fixtures.docTwo])
        #expect(
            index.entries[0]
                == IndexEntry(hash: Fixtures.hashA, kind: .collection, id: Fixtures.docOne, subfiles: 4, size: 1200)
        )
    }

    @Test func parsesSchema4RootAndDocument() throws {
        let root = try SyncIndex(parsing: Data(Fixtures.rootV4.utf8))
        #expect(root.schema == .v4 && root.infoID == "." && root.infoSize == 2100)
        let document = try SyncIndex(parsing: Data(Fixtures.documentV4.utf8))
        #expect(document.infoID == Fixtures.docTwo)
        #expect(document.entries.map(\.id).last == "\(Fixtures.docTwo)/\(Fixtures.page).rm")
    }

    @Test func roundTripsByteForByte() throws {
        for text in [Fixtures.rootV3, Fixtures.rootV4, Fixtures.documentV4] {
            let data = Data(text.utf8)
            #expect(try SyncIndex(parsing: data).serialized() == data)
        }
    }

    @Test(arguments: [
        "", "5\n", "4\n", "4\n0:.:3:10\n\(String(repeating: "a", count: 64)):0:x:0:1\n",
        "4\n1:.:0:0\n", "3\nnot-a-line\n", "3\n\(String(repeating: "a", count: 64)):7:x:0:1\n",
        "3\nshort:0:x:0:1\n",
    ])
    func rejectsMalformedIndexes(_ text: String) {
        #expect(throws: CloudError.self) { try SyncIndex(parsing: Data(text.utf8)) }
    }

    @Test func schema3HashIsHashOfConcatenatedHashes() throws {
        let index = try SyncIndex(parsing: Data(Fixtures.rootV3.utf8))
        var concatenated = Data(repeating: 0xAA, count: 32)
        concatenated.append(Data(repeating: 0xBB, count: 32))
        #expect(try index.hash() == ContentHash.sha256Hex(concatenated))
    }

    @Test func schema4HashIsHashOfBytes() throws {
        let index = try SyncIndex(parsing: Data(Fixtures.rootV4.utf8))
        #expect(try index.hash() == ContentHash.sha256Hex(Data(Fixtures.rootV4.utf8)))
    }
}

@Suite struct TokenAndHostTests {
    @Test func readsClaims() throws {
        let claims = try TokenClaims(jwt: FakeCloud.userToken)
        #expect(claims.tectonic == "eu")
        #expect(claims.scopes == "sync:tortoise")
        #expect(claims.expiration == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(throws: CloudError.malformedToken) { try TokenClaims(jwt: "not a token") }
    }

    @Test func choosesSyncHostFromTectonicClaim() throws {
        #expect(
            CloudHosts.sync(for: try TokenClaims(jwt: FakeCloud.userToken)).absoluteString
                == "https://eu.tectonic.remarkable.com"
        )
        #expect(
            CloudHosts.sync(for: try TokenClaims(jwt: FakeCloud.jwt(["tectonic": "evil.example/x"])))
                == CloudHosts.defaultSync
        )
        #expect(CloudHosts.sync(for: nil) == CloudHosts.defaultSync)
    }

    @Test func allowsOnlyReMarkableHostsOverHTTPS() async {
        #expect(CloudHosts.isAllowed(URL(string: "https://eu.tectonic.remarkable.com/sync/v4/root")!))
        #expect(CloudHosts.isAllowed(URL(string: "https://webapp-prod.cloud.remarkable.engineering/token")!))
        #expect(!CloudHosts.isAllowed(URL(string: "http://eu.tectonic.remarkable.com/")!))
        #expect(!CloudHosts.isAllowed(URL(string: "https://remarkable.com.example.org/")!))
        let request = HTTPRequest(method: "GET", url: URL(string: "https://example.org/")!)
        await #expect(throws: CloudError.hostNotAllowed("example.org")) {
            try await URLSessionTransport().send(request)
        }
    }
}

@Suite struct RequestTests {
    let builder = RequestBuilder()

    @Test func readRequests() throws {
        let renew = builder.renewUserToken(deviceToken: "invented.device.token")
        #expect(renew.method == "POST")
        #expect(renew.url.absoluteString == "https://webapp-prod.cloud.remarkable.engineering/token/json/2/user/new")
        #expect(renew.headers == ["authorization": "Bearer invented.device.token"])

        let root = builder.getRoot(userToken: "t")
        #expect(root.method == "GET" && root.url.absoluteString == "https://eu.tectonic.remarkable.com/sync/v4/root")

        let file = try builder.getFile(hash: Fixtures.hashA, fileName: "root.docSchema", userToken: "t")
        #expect(file.url.path() == "/sync/v3/files/\(Fixtures.hashA)")
        #expect(file.headers["rm-filename"] == "root.docSchema")
        #expect(throws: CloudError.self) { try builder.getFile(hash: "../root", fileName: "x", userToken: "t") }
    }

    @Test func redactedDescriptionHidesToken() throws {
        let request = try builder.getFile(hash: Fixtures.hashA, fileName: "root.docSchema", userToken: "secret.s.s")
        #expect(!request.redactedDescription.contains("secret"))
    }

    @Test func registrationRequest() throws {
        let id = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let request = try builder.registerDevice(code: "abcd2345", deviceID: id)
        #expect(request.method == "POST")
        #expect(
            request.url.absoluteString == "https://webapp-prod.cloud.remarkable.engineering/token/json/2/device/new"
        )
        #expect(request.headers == ["authorization": "Bearer", "content-type": "application/json"])
        let body = try JSONSerialization.jsonObject(with: try #require(request.body)) as? [String: String]
        #expect(body == ["code": "abcd2345", "deviceDesc": "desktop-macos", "deviceID": id.uuidString.lowercased()])
        for code in ["abcd234", "abcd23456", "abcd 234", "abcd234é", ""] {
            #expect(throws: CloudError.invalidCode) { try builder.registerDevice(code: code, deviceID: id) }
        }
    }

    @Test func keychainItemsAreNamedInOnePlace() {
        #expect(DeviceTokenKeychain.services == ["rePossess", "rePossess spike 6"])
        #expect(DeviceTokenKeychain.service == "rePossess")
    }
}

@Suite struct KeychainTests {
    @Test func readsThePairedItemFirstAndFallsBackToTheLegacyItem() throws {
        let both = FakeKeychain(["rePossess": "new.device.token", "rePossess spike 6": "old.device.token"])
        #expect(try DeviceTokenKeychain.read(from: both) == ("new.device.token", "rePossess"))
        #expect(both.reads == ["rePossess"])

        let legacy = FakeKeychain(["rePossess spike 6": "old.device.token"])
        #expect(try DeviceTokenKeychain.read(from: legacy) == ("old.device.token", "rePossess spike 6"))
        #expect(legacy.reads == ["rePossess", "rePossess spike 6"])

        #expect(throws: CloudError.notPaired(service: "rePossess")) {
            try DeviceTokenKeychain.read(from: FakeKeychain())
        }
    }

    @Test func findsThePairedItemWithoutReadingASecret() {
        let legacy = FakeKeychain(["rePossess spike 6": "old.device.token"])
        #expect(DeviceTokenKeychain.pairedService(in: legacy) == "rePossess spike 6")
        #expect(DeviceTokenKeychain.pairedService(in: FakeKeychain()) == nil)
        #expect(legacy.reads.isEmpty)
    }
}

@Suite struct PairingTests {
    @Test func pairsAsADesktopMacAndStoresTheToken() async throws {
        let cloud = FakeCloud()
        let keychain = FakeKeychain()
        let id = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let result = try await Pairing(transport: cloud, store: keychain).pair(code: "  abcd2345\n", deviceID: id)
        #expect(result == Pairing.Result(service: "rePossess", deviceID: id.uuidString.lowercased(), olderService: nil))
        #expect(keychain.contents == ["rePossess": FakeCloud.deviceToken])
        let requests = await cloud.requests
        #expect(requests.map { $0.url.path() } == ["/token/json/2/device/new"])
        // The new token works for the read path.
        let session = CloudSession(
            transport: cloud,
            deviceToken: { try DeviceTokenKeychain.read(from: keychain).token }
        )
        _ = try await session.client()
    }

    @Test func reportsAnOlderItemThatStays() async throws {
        let keychain = FakeKeychain(["rePossess spike 6": "old.device.token"])
        let result = try await Pairing(transport: FakeCloud(), store: keychain).pair(code: FakeCloud.oneTimeCode)
        #expect(result.olderService == "rePossess spike 6")
        #expect(try DeviceTokenKeychain.read(from: keychain).service == "rePossess")
    }

    @Test func refusesBeforeAnyRequest() async throws {
        let cloud = FakeCloud()
        let empty = FakeKeychain()
        await #expect(throws: CloudError.invalidCode) {
            try await Pairing(transport: cloud, store: empty).pair(code: "abc")
        }
        let paired = FakeKeychain(["rePossess": "new.device.token"])
        await #expect(throws: CloudError.alreadyPaired(service: "rePossess")) {
            try await Pairing(transport: cloud, store: paired).pair(code: FakeCloud.oneTimeCode)
        }
        #expect(await cloud.requests.isEmpty)
        #expect(paired.contents == ["rePossess": "new.device.token"] && empty.contents.isEmpty)
    }

    @Test func aRefusedCodeStoresNothing() async throws {
        let keychain = FakeKeychain()
        await #expect(throws: CloudError.registrationRefused(status: 400, message: "invalid one-time code")) {
            try await Pairing(transport: FakeCloud(), store: keychain).pair(code: "zzzz9999")
        }
        #expect(keychain.contents.isEmpty)
        #expect(
            CloudError.registrationRefused(status: 400, message: "x").description
                .contains("my.remarkable.com/device/desktop/connect")
        )
    }

    @Test func unpairDeletesEveryItemAndSendsNothing() async throws {
        let cloud = FakeCloud()
        let keychain = FakeKeychain(["rePossess": "new.device.token", "rePossess spike 6": "old.device.token"])
        let pairing = Pairing(transport: cloud, store: keychain)
        let deleted = try pairing.unpair()
        #expect(deleted == ["rePossess", "rePossess spike 6"])
        #expect(keychain.contents.isEmpty && keychain.reads.isEmpty)
        #expect(await cloud.requests.isEmpty)
        let message = Pairing.unpairMessage(deleted: deleted)
        #expect(message.contains("\"rePossess\" and \"rePossess spike 6\"") && message.contains("my.remarkable.com"))
        #expect(try pairing.unpair().isEmpty)
        #expect(Pairing.unpairMessage(deleted: []).hasPrefix("There was no device token"))
    }
}

/// Records the waits that a ``Pacing`` asks for, without sleeping.
actor WaitRecorder {
    private(set) var waits: [Duration] = []
    func record(_ duration: Duration) { waits.append(duration) }

    nonisolated func pacing(maxConcurrent: Int = 4) -> Pacing {
        Pacing(maxConcurrent: maxConcurrent, sleep: { await self.record($0) })
    }
}

/// Answers every request with the same status, and counts them.
actor Refusing: HTTPTransport {
    let status: Int
    private(set) var count = 0
    init(status: Int) { self.status = status }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        count += 1
        return HTTPResponse(status: status)
    }
}

@Suite struct PacingTests {
    /// Seeds one document with `count` files and returns its index entries.
    func seedFiles(_ cloud: FakeCloud, count: Int) async throws -> [IndexEntry] {
        let files = (0 ..< count).map { ("\(Fixtures.docOne)/p\($0).rm", Data("invented page \($0)".utf8)) }
        let entry = try await cloud.seedDocument(id: Fixtures.docOne, files: files)
        try await cloud.seedRoot([entry])
        let client = try await CloudSession(transport: cloud, deviceToken: { FakeCloud.deviceToken }).client()
        return try await client.index(id: Fixtures.docOne, hash: entry.hash).index.entries
    }

    @Test func boundsTheRequestsInFlight() async throws {
        let cloud = FakeCloud()
        let entries = try await seedFiles(cloud, count: 12)
        await cloud.set(latency: .milliseconds(20))
        await cloud.clearRequests()
        let session = CloudSession(transport: cloud, deviceToken: { FakeCloud.deviceToken })
        let client = try await session.client()
        try await withThrowingTaskGroup(of: Data.self) { group in
            for entry in entries { group.addTask { try await client.file(entry) } }
            for try await _ in group {}
        }
        let most = await cloud.maxInFlight
        #expect(most > 1 && most <= 4)
        let usage = await session.usage()
        #expect(usage.requests == 13)  // the user token and 12 files
        #expect(usage.bytes == (await cloud.bytesServed))
    }

    @Test func waitsWhenTheLimitIsSpent() async throws {
        let cloud = FakeCloud()
        let entries = try await seedFiles(cloud, count: 2)
        await cloud.set(extraHeaders: [
            "x-ratelimit-limit": "30", "x-ratelimit-remaining": "0", "x-ratelimit-reset": "2",
        ])
        let recorder = WaitRecorder()
        let session = CloudSession(transport: cloud, deviceToken: { FakeCloud.deviceToken }, pacing: recorder.pacing())
        let client = try await session.client()
        _ = try await client.file(entries[0])
        _ = try await client.file(entries[1])
        // The token response spent the token limit, and each file response spent the file limit.
        // The last pause starts in its own task after the response, so wait for it to record.
        for _ in 0 ..< 100 where await recorder.waits.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await recorder.waits == [.seconds(2), .seconds(2), .seconds(2)])
        #expect(await session.usage().waits == 3)
    }

    @Test func retriesAReadAfter429And5xx() async throws {
        let cloud = FakeCloud()
        let entries = try await seedFiles(cloud, count: 1)
        await cloud.set(fileFailures: [429, 503])
        let recorder = WaitRecorder()
        let session = CloudSession(transport: cloud, deviceToken: { FakeCloud.deviceToken }, pacing: recorder.pacing())
        let client = try await session.client()
        #expect(try await client.file(entries[0]) == Data("invented page 0".utf8))
        #expect(await recorder.waits == [.seconds(1), .seconds(2)])
        #expect(await session.usage().retries == 2)

        await cloud.set(extraHeaders: ["retry-after": "5"], fileFailures: [429])
        _ = try await client.file(entries[0])
        #expect(await recorder.waits.last == .seconds(5))
    }

    @Test func backsOffAndGivesUp() async throws {
        let transport = Refusing(status: 429)
        let recorder = WaitRecorder()
        let paced = PacedTransport(base: transport, pacing: recorder.pacing())
        let get = HTTPRequest(method: "GET", url: URL(string: "https://eu.tectonic.remarkable.com/sync/v4/root")!)
        #expect(try await paced.send(get).status == 429)
        #expect(await transport.count == 4)  // the request and three retries
        #expect(await recorder.waits == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test func neverSendsAWriteAgain() async throws {
        let transport = Refusing(status: 503)
        let paced = PacedTransport(base: transport, pacing: WaitRecorder().pacing())
        let post = HTTPRequest(
            method: "POST",
            url: URL(string: "https://webapp-prod.cloud.remarkable.engineering/token/json/2/user/new")!
        )
        #expect(try await paced.send(post).status == 503)
        #expect(await transport.count == 1)
    }

    @Test func readsTheRateLimitHeaders() {
        let limit = RateLimit(headers: [
            "x-ratelimit-limit": "48000", "x-ratelimit-remaining": "95998", "x-ratelimit-reset": "1",
            "retry-after": "2.5",
        ])
        #expect(limit.limit == 48000 && limit.remaining == 95998)
        #expect(limit.reset == .seconds(1) && limit.retryAfter == .milliseconds(2500))
        #expect(RateLimit(headers: ["x-ratelimit-reset": "soon"]).reset == nil)
        let file = URL(string: "https://eu.tectonic.remarkable.com/sync/v3/files/\(Fixtures.hashA)")!
        let other = URL(string: "https://eu.tectonic.remarkable.com/sync/v3/files/\(Fixtures.hashB)")!
        #expect(PacedTransport.limitKey(for: file) == PacedTransport.limitKey(for: other))
        #expect(PacedTransport.limitKey(for: file) == "eu.tectonic.remarkable.com/sync/v3/files")
    }
}

@Suite struct ClientTests {
    @Test func readsRootIndexesAndFiles() async throws {
        let cloud = FakeCloud()
        let files: [(String, Data)] = [
            ("\(Fixtures.docOne).content", Data(#"{"fileType":"notebook"}"#.utf8)),
            ("\(Fixtures.docOne).metadata", Data(#"{"visibleName":"Invented"}"#.utf8)),
        ]
        let entry = try await cloud.seedDocument(id: Fixtures.docOne, files: files)
        try await cloud.seedRoot([entry])

        let session = CloudSession(transport: cloud, deviceToken: { FakeCloud.deviceToken })
        let client = try await session.client()
        let root = try await client.root()
        #expect(root.schemaVersion == 3)
        let rootIndex = try await client.index(id: "root", hash: root.hash)
        #expect(rootIndex.hashMatches)
        #expect(rootIndex.index.entries.map(\.id) == [Fixtures.docOne])
        let documentIndex = try await client.index(id: Fixtures.docOne, hash: rootIndex.index.entries[0].hash)
        #expect(documentIndex.hashMatches)
        let metadata = try #require(documentIndex.index.entries.first { $0.id.hasSuffix(".metadata") })
        #expect(try await client.file(metadata) == files[1].1)

        // The session renews the user token once and reuses it.
        _ = try await session.client()
        #expect(await cloud.requests.filter { $0.url.path().hasSuffix("/user/new") }.count == 1)
        // Every request is a read.
        #expect(await cloud.requests.allSatisfy { $0.method == "GET" || $0.url.path().hasSuffix("/user/new") })
    }

    @Test func detectsACorruptFile() async throws {
        let cloud = FakeCloud()
        let data = Data("invented".utf8)
        let entry = try await cloud.seedDocument(id: Fixtures.docOne, files: [("\(Fixtures.docOne).pdf", data)])
        try await cloud.seedRoot([entry])
        let client = try await CloudSession(transport: cloud, deviceToken: { FakeCloud.deviceToken }).client()
        let index = try await client.index(id: Fixtures.docOne, hash: entry.hash)
        await cloud.corrupt(hash: index.index.entries[0].hash)
        await #expect(throws: CloudError.self) { try await client.file(index.index.entries[0]) }
    }

    @Test func rejectedDeviceTokenIsUnauthorized() async throws {
        let session = CloudSession(transport: FakeCloud(), deviceToken: { "wrong.device.token" })
        await #expect(throws: CloudError.unauthorized(status: 401)) { try await session.client() }
        let unpaired = CloudSession(transport: FakeCloud(), deviceToken: { throw CloudError.notPaired(service: "x") })
        await #expect(throws: CloudError.notPaired(service: "x")) { try await unpaired.client() }
    }

    @Test func aSlowKeychainReadTimesOut() async throws {
        let session = CloudSession(
            transport: FakeCloud(),
            deviceToken: {
                Thread.sleep(forTimeInterval: 2)
                return FakeCloud.deviceToken
            },
            tokenTimeout: .milliseconds(100)
        )
        let start = ContinuousClock.now
        await #expect(throws: CloudError.keychainTimedOut) { try await session.client() }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(CloudError.keychainTimedOut.description.contains("Always Allow"))
        let quick = CloudSession(
            transport: FakeCloud(),
            deviceToken: { FakeCloud.deviceToken },
            tokenTimeout: .seconds(5)
        )
        _ = try await quick.client()
    }
}
