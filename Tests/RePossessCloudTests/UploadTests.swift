import Foundation
import Testing

@testable import RePossessCloud

/// Invented inputs for uploads. No ID, hash, or name here comes from a real account.
private enum Upload {
    static let documentID = "55555555-5555-4555-8555-555555555555"
    static let pageID = "66666666-6666-4666-8666-666666666666"
    static let now = Date(timeIntervalSince1970: 1_793_000_000)
    static let pdf = Data("%PDF-1.4\ninvented\n%%EOF\n".utf8)
    static let epub = Data([0x50, 0x4B, 0x03, 0x04] + Array("mimetypeapplication/epub+zip".utf8))

    static func pdfDocument(id: String = documentID, name: String = "rePossess test") throws -> NewDocument {
        try NewDocument.file(.pdf, visibleName: name, data: pdf, documentID: id, pageID: pageID, now: now)
    }

    /// An invented notebook archive's files, with the archive's own document ID.
    static func notebookFiles(archiveID: String) -> [(name: String, data: Data)] {
        [
            ("\(archiveID).content", Data(#"{"fileType":"notebook","formatVersion":2}"#.utf8)),
            ("\(archiveID).metadata", Data(#"{"type":"DocumentType","visibleName":"rePossess test"}"#.utf8)),
            ("\(archiveID)/77777777-7777-4777-8777-777777777777.rm", Data("reMarkable .lines file, version=6".utf8)),
        ]
    }

    static func plan(
        _ document: NewDocument? = nil,
        rootText: String = Fixtures.rootV4,
        schema: Int = 4
    ) throws -> UploadPlan {
        let index = try SyncIndex(parsing: Data(rootText.utf8))
        let root = RootState(hash: try index.hash(), generation: 42, schemaVersion: schema)
        return try UploadPlanner.plan(document ?? pdfDocument(), root: root, rootIndex: index)
    }
}

@Suite struct UploadPlannerTests {
    @Test func producesTheExactPutsForAPDF() throws {
        let plan = try Upload.plan()
        let id = Upload.documentID
        #expect(
            plan.blobPuts.map(\.fileName) == [
                "\(id).content", "\(id).metadata", "\(id).pagedata", "\(id).pdf", "\(id).docSchema", "root.docSchema",
            ]
        )
        for put in plan.filePuts {
            #expect(put.hash == ContentHash.sha256Hex(put.body))
        }
        #expect(plan.filePuts[2].body == Data("\n".utf8))
        #expect(plan.filePuts[3].body == Upload.pdf)
        #expect(plan.baseGeneration == 42)
        let metadata = try JSONSerialization.jsonObject(with: plan.filePuts[1].body) as! [String: Any]
        #expect(metadata["visibleName"] as? String == "rePossess test" && metadata["parent"] as? String == "")
        #expect(metadata["lastModified"] as? String == "1793000000000")
        let content = try JSONSerialization.jsonObject(with: plan.filePuts[0].body) as! [String: Any]
        #expect(content["fileType"] as? String == "pdf" && content["pages"] as? [String] == [Upload.pageID])
        #expect(content["sizeInBytes"] as? String == String(Upload.pdf.count))
    }

    @Test func anEPUBHasTheSameFilesWithItsType() throws {
        let document = try NewDocument.file(
            .epub,
            visibleName: "rePossess test",
            data: Upload.epub,
            documentID: Upload.documentID
        )
        let plan = try Upload.plan(document)
        #expect(plan.filePuts.map(\.fileName).last == "\(Upload.documentID).epub")
        let content = try JSONSerialization.jsonObject(with: plan.filePuts[0].body) as! [String: Any]
        #expect(content["fileType"] as? String == "epub")
        #expect(throws: CloudError.self) {
            try NewDocument.file(.epub, visibleName: "x", data: Upload.pdf, documentID: Upload.documentID)
        }
    }

    @Test func aNotebookUploadsTheArchiveFilesUnderTheNewID() throws {
        let archiveID = "88888888-8888-4888-8888-888888888888"
        let document = try NewDocument.notebook(
            files: Upload.notebookFiles(archiveID: archiveID),
            archiveID: archiveID,
            visibleName: "rePossess test",
            documentID: Upload.documentID
        )
        let plan = try Upload.plan(document)
        let id = Upload.documentID
        #expect(
            plan.filePuts.map(\.fileName) == [
                "\(id).content", "\(id).metadata", "\(id)/77777777-7777-4777-8777-777777777777.rm",
            ]
        )
        #expect(plan.rootEntry.subfiles == 3)
        let index = try SyncIndex(parsing: plan.documentIndexPut.body)
        #expect(index.entries.map(\.id) == plan.filePuts.map(\.fileName).sorted())
        #expect(throws: CloudError.self) {
            try NewDocument.notebook(
                files: [("\(archiveID).content", Data())],
                archiveID: archiveID,
                visibleName: "x",
                documentID: id
            )
        }
    }

    @Test func aSchema4AccountGetsSchema4Indexes() throws {
        let plan = try Upload.plan()
        #expect(plan.rootSchema == .v4)
        let document = try SyncIndex(parsing: plan.documentIndexPut.body)
        #expect(document.schema == .v4 && document.infoID == Upload.documentID && document.isSorted)
        let root = try SyncIndex(parsing: plan.rootIndexPut.body)
        #expect(root.schema == .v4 && root.infoID == "." && root.isSorted)
        #expect(root.entries.map(\.id) == [Fixtures.docOne, Fixtures.docTwo, Upload.documentID].sorted())
        #expect(root.infoSize == 2100 + plan.rootEntry.size)
        #expect(plan.newRootHash == ContentHash.sha256Hex(plan.rootIndexPut.body))
    }

    @Test func aSchema3AccountGetsASchema3Root() throws {
        let plan = try Upload.plan(rootText: Fixtures.rootV3, schema: 3)
        #expect(plan.rootSchema == .v3)
        let document = try SyncIndex(parsing: plan.documentIndexPut.body)
        #expect(document.schema == .v3)
        #expect(plan.documentIndexPut.hash == (try document.hash()))
        #expect(plan.documentIndexPut.hash != ContentHash.sha256Hex(plan.documentIndexPut.body))
        let root = try SyncIndex(parsing: plan.rootIndexPut.body)
        #expect(root.schema == .v3 && root.isSorted)
        #expect(root.entries.allSatisfy { $0.kind == .collection })
        #expect(root.entries.count == 3)
        #expect(plan.rootIndexPut.hash == (try root.hash()))
    }

    @Test func sortsANewIDThatIsNotLast() throws {
        // An ID that sorts first; appending without a sort was the bug in ddvk/rmapi issue 75.
        let plan = try Upload.plan(try Upload.pdfDocument(id: "0aaaaaaa-0000-4000-8000-000000000000"))
        let root = try SyncIndex(parsing: plan.rootIndexPut.body)
        #expect(root.entries.first?.id == "0aaaaaaa-0000-4000-8000-000000000000")
    }

    @Test func refusesBadInputs() throws {
        #expect(throws: CloudError.self) {
            try NewDocument.file(.pdf, visibleName: "x", data: Data("not a pdf".utf8), documentID: Upload.documentID)
        }
        #expect(throws: CloudError.self) { try Upload.pdfDocument(name: "") }
        #expect(throws: CloudError.self) { try Upload.pdfDocument(id: "55555555-5555-4555-8555-55555555555A") }
        #expect(throws: CloudError.self) { try Upload.plan(schema: 5) }
        // A schema 4 index on an account that reports schema 3.
        #expect(throws: CloudError.self) { try Upload.plan(schema: 3) }
        let existing = """
            4
            0:.:1:1
            \(Fixtures.hashA):0:\(Upload.documentID):1:1

            """
        #expect(throws: CloudError.self) { try Upload.plan(rootText: existing) }
    }

    @Test(arguments: [
        // Unsorted.
        "4\n0:.:2:2100\n\(Fixtures.hashB):0:\(Fixtures.docTwo):3:900\n\(Fixtures.hashA):0:\(Fixtures.docOne):4:1200\n",
        // An info size that does not add up.
        "4\n0:.:2:9999\n\(Fixtures.hashA):0:\(Fixtures.docOne):4:1200\n\(Fixtures.hashB):0:\(Fixtures.docTwo):3:900\n",
    ])
    func refusesARootItWouldRewrite(_ rootText: String) {
        #expect(throws: CloudError.self) { try Upload.plan(rootText: rootText) }
    }

    @Test func writeRequests() throws {
        let builder = RequestBuilder(syncHost: URL(string: "https://eu.tectonic.remarkable.com")!)
        let put = try builder.putFile(hash: Fixtures.hashA, fileName: "x.pdf", body: Data("abc".utf8), userToken: "t")
        #expect(put.method == "PUT" && put.url.path() == "/sync/v3/files/\(Fixtures.hashA)")
        #expect(
            put.headers["rm-filename"] == "x.pdf" && put.headers["x-goog-hash"] == CRC32C.googHash(Data("abc".utf8))
        )
        let root = try builder.putRoot(hash: Fixtures.hashB, generation: 7, userToken: "t")
        #expect(root.url.path() == "/sync/v3/root" && root.headers["rm-filename"] == "roothash")
        #expect(
            String(decoding: root.body!, as: UTF8.self)
                == #"{"broadcast":true,"generation":7,"hash":"\#(Fixtures.hashB)"}"#
        )
        // The CRC-32C check value.
        #expect(CRC32C.checksum(Data("123456789".utf8)) == 0xE306_9283)
    }
}

@Suite struct CloudPushTests {
    /// A fake cloud with two invented documents in a root of the given schema.
    func stockedCloud(schema: SchemaVersion = .v3) async throws -> FakeCloud {
        let cloud = FakeCloud()
        var entries: [IndexEntry] = []
        for id in [Fixtures.docOne, Fixtures.docTwo] {
            entries.append(
                try await cloud.seedDocument(
                    id: id,
                    files: [
                        ("\(id).metadata", Data(#"{"visibleName":"Invented","type":"DocumentType","parent":""}"#.utf8)),
                        ("\(id).content", Data(#"{"fileType":"notebook"}"#.utf8)),
                    ],
                    schema: schema
                )
            )
        }
        try await cloud.seedRoot(entries, schema: schema)
        await cloud.clearRequests()
        return cloud
    }

    func client(_ cloud: FakeCloud) -> CloudClient {
        CloudClient(transport: PacedTransport(base: cloud), userToken: FakeCloud.userToken)
    }

    @Test func pushesANotebookAndKeepsASchema3AccountOnSchema3() async throws {
        let cloud = try await stockedCloud(schema: .v3)
        let archiveID = "88888888-8888-4888-8888-888888888888"
        let document = try NewDocument.notebook(
            files: Upload.notebookFiles(archiveID: archiveID),
            archiveID: archiveID,
            visibleName: "rePossess test",
            documentID: Upload.documentID
        )
        let outcome = try await client(cloud).push(document)
        guard case .sent(let generation?) = outcome else {
            Issue.record("expected sent with a generation, got \(outcome)")
            return
        }
        #expect(generation == (await cloud.generation))
        #expect(await cloud.schemaVersion == 3)
        let root = try await cloud.currentRootIndex()
        #expect(root.schema == .v3 && root.isSorted && root.entries.count == 3)
        let files = try await cloud.documentFiles(id: Upload.documentID)
        #expect(Set(files.keys) == Set(document.files.map(\.name)))
        #expect(
            await cloud.writes == [
                "PUT \(Upload.documentID).content", "PUT \(Upload.documentID).metadata",
                "PUT \(Upload.documentID)/77777777-7777-4777-8777-777777777777.rm",
                "PUT \(Upload.documentID).docSchema", "PUT root.docSchema", "PUT roothash",
            ]
        )
        // The documents that were there stay.
        #expect(try await cloud.documentFiles(id: Fixtures.docOne).count == 2)
    }

    @Test func pushesAPDFToASchema4Account() async throws {
        let cloud = try await stockedCloud(schema: .v4)
        let outcome = try await client(cloud).push(try Upload.pdfDocument())
        #expect(outcome.isSent)
        #expect(await cloud.schemaVersion == 4)
        #expect(try await cloud.documentFiles(id: Upload.documentID)["\(Upload.documentID).pdf"] == Upload.pdf)
    }

    @Test func replansAfterAGenerationConflict() async throws {
        let cloud = try await stockedCloud()
        await cloud.set(interveningSyncs: 1)
        let outcome = try await client(cloud).push(try Upload.pdfDocument())
        guard case .sent = outcome else {
            Issue.record("expected sent, got \(outcome)")
            return
        }
        #expect(await cloud.writes.filter { $0 == "PUT roothash" }.count == 2)
        #expect(try await cloud.currentRootIndex().entries.count == 3)
    }

    @Test func givesUpAfterAConflictOnEveryAttempt() async throws {
        let cloud = try await stockedCloud()
        await cloud.set(interveningSyncs: 3)
        await #expect(throws: CloudError.generationConflict) {
            try await client(cloud).push(try Upload.pdfDocument(), attempts: 3)
        }
        #expect(try await cloud.currentRootIndex().entries.count == 2)
    }

    @Test func aLostAnswerAfterTheUpdateIsFoundByReadingTheRoot() async throws {
        let cloud = try await stockedCloud()
        await cloud.set(rootUpdateLoss: .afterApplying)
        let outcome = try await client(cloud).push(try Upload.pdfDocument())
        #expect(outcome == .sent(generation: nil))
        // One root update only: the check read the root instead of sending it again.
        #expect(await cloud.writes.filter { $0 == "PUT roothash" }.count == 1)
        #expect(try await cloud.currentRootIndex().entries.contains { $0.id == Upload.documentID })
    }

    @Test func aServerErrorAfterTheUpdateIsCheckedTheSameWay() async throws {
        let cloud = try await stockedCloud()
        await cloud.set(rootUpdateLoss: .serverErrorAfterApplying)
        #expect(try await client(cloud).push(try Upload.pdfDocument()) == .sent(generation: nil))
        #expect(await cloud.writes.filter { $0 == "PUT roothash" }.count == 1)
    }

    @Test func aLostUpdateThatDidNotHappenIsNotSent() async throws {
        let cloud = try await stockedCloud()
        await cloud.set(rootUpdateLoss: .beforeApplying)
        await #expect(throws: CloudError.self) { try await client(cloud).push(try Upload.pdfDocument()) }
        #expect(await cloud.writes.filter { $0 == "PUT roothash" }.count == 1)
        // A later push of the same document sends it.
        #expect(try await client(cloud).push(try Upload.pdfDocument()).isSent)
        #expect(try await cloud.currentRootIndex().entries.contains { $0.id == Upload.documentID })
    }

    @Test func aLostUpdateWithoutAReadableRootIsUnknown() async throws {
        let cloud = try await stockedCloud()
        await cloud.set(rootUpdateLoss: .afterApplying, failRootReadsAfterLoss: true)
        let outcome = try await client(cloud).push(try Upload.pdfDocument())
        guard case .unknown(let reason) = outcome else {
            Issue.record("expected unknown, got \(outcome)")
            return
        }
        #expect(reason.contains("could not be read"))
    }

    @Test func aDocumentAlreadyInTheRootIsNotSentAgain() async throws {
        let cloud = try await stockedCloud()
        _ = try await client(cloud).push(try Upload.pdfDocument())
        await cloud.clearRequests()
        #expect(try await client(cloud).push(try Upload.pdfDocument()).isSent)
        #expect(await cloud.writes.isEmpty)
    }

    @Test func aRefusedBlobLeavesTheRootAlone() async throws {
        let cloud = try await stockedCloud()
        var document = try Upload.pdfDocument()
        // The fake refuses a blob named as an index that does not parse as one.
        document.files.append(("\(Upload.documentID).docSchema", Data("not an index".utf8)))
        await #expect(throws: CloudError.self) { try await client(cloud).push(document) }
        #expect(await cloud.writes.contains("PUT roothash") == false)
        #expect(try await cloud.currentRootIndex().entries.count == 2)
    }
}
