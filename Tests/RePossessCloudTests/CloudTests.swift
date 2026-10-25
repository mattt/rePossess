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

    @Test func keychainServiceIsNamedInOnePlace() {
        #expect(DeviceTokenKeychain.service == "rePossess spike 6")
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
