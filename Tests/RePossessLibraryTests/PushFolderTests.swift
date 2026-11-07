import Foundation
import Testing

@testable import RePossessCloud
@testable import RePossessFormat
@testable import RePossessLibrary
@testable import RePossessUSB

/// The metadata of a document or folder that the fake cloud holds.
private func metadata(_ cloud: FakeCloud, id: String) async throws -> [String: Any] {
    let files = try await cloud.documentFiles(id: id)
    let data = try #require(files["\(id).metadata"])
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func rootUpdates(_ cloud: FakeCloud) async -> Int {
    await cloud.requests.filter { $0.method == "PUT" && $0.url.path() == "/sync/v3/root" }.count
}

/// Renames or moves a folder in the fake cloud, as another client would: the folder's entry gets new metadata.
private func changeFolder(_ cloud: FakeCloud, id: String, name: String, parent: String) async throws {
    let json = "{\"visibleName\": \"\(name)\", \"type\": \"CollectionType\", \"parent\": \"\(parent)\"}"
    let entry = try await cloud.seedDocument(
        id: id,
        files: [("\(id).metadata", Data(json.utf8)), ("\(id).content", Data("{}".utf8))]
    )
    let others = try await cloud.currentRootIndex().entries.filter { $0.id != id }
    try await cloud.seedRoot(others + [entry])
}

/// A library that mirrors a fake cloud with one folder, "Garden", and its documents.
private func mirroredGarden() async throws -> (library: Library, cloud: FakeCloud, session: CloudSession) {
    let cloud = FakeCloud()
    _ = try await Shelf.stock(cloud)
    let session = cloudSession(cloud)
    let library = try temporaryLibrary()
    _ = try await library.refreshCloud(session: session)
    await cloud.clearRequests()
    return (library, cloud, session)
}

@Suite struct PushFolderTests {
    @Test func anExistingFolderHoldsTheNewDocument() async throws {
        let (library, cloud, session) = try await mirroredGarden()
        let before = try await cloud.currentRootIndex().entries
        let pdf = makePDF(["Invented page"])
        let record = try library.enqueuePush(kind: .pdf, title: "rePossess test pdf", data: pdf, folder: "Garden")
        #expect(record.folder == "Garden" && record.folderID == Shelf.folder && record.folderIsNew == false)

        let sent = try #require(try await library.sendPushes(paths: PushPaths(usb: nil, cloud: session)).first)
        #expect(sent.status == .sent && sent.via == .cloud && sent.folder == "Garden")

        let after = try await cloud.currentRootIndex().entries
        #expect(after.map(\.id).sorted() == (before.map(\.id) + [record.id]).sorted())
        // Every earlier entry, the folder's included, is unchanged.
        for entry in before { #expect(after.contains(entry)) }
        #expect(try await metadata(cloud, id: record.id)["parent"] as? String == Shelf.folder)
        #expect(await rootUpdates(cloud) == 1)
    }

    @Test func aMissingFolderIsCreatedWithTheDocumentInOneRootUpdate() async throws {
        let cloud = try await emptyCloud()
        let library = try temporaryLibrary()
        let record = try queue(library, folder: "Biology 101")
        #expect(record.folder == "Biology 101" && record.folderIsNew == true)
        let folderID = try #require(record.folderID)
        #expect(folderID != record.id && UUID(uuidString: folderID) != nil)

        let sent = try #require(
            try await library.sendPushes(paths: PushPaths(usb: nil, cloud: cloudSession(cloud))).first
        )
        #expect(sent.status == .sent && sent.via == .cloud)

        #expect(try await cloud.currentRootIndex().entries.map(\.id).sorted() == [folderID, record.id].sorted())
        let folder = try await metadata(cloud, id: folderID)
        #expect(folder["type"] as? String == "CollectionType" && folder["visibleName"] as? String == "Biology 101")
        #expect(folder["parent"] as? String == "")
        #expect(try await metadata(cloud, id: record.id)["parent"] as? String == folderID)
        #expect(await rootUpdates(cloud) == 1)
        #expect(await cloud.schemaVersion == 3)
    }

    @Test func aNotebookKeepsItsFilesAndGainsItsParent() async throws {
        let cloud = try await emptyCloud()
        let library = try temporaryLibrary()
        let record = try queue(library, folder: "Biology 101")
        _ = try await library.sendPushes(paths: PushPaths(usb: nil, cloud: cloudSession(cloud)))
        let files = try await cloud.documentFiles(id: record.id)
        #expect(files.keys.filter { $0.hasSuffix(".rm") }.count == 1)
        let parsed = try DocumentMetadata(parsing: try #require(files["\(record.id).metadata"]))
        #expect(parsed.parent == record.folderID && parsed.visibleName == "rePossess test note")
    }

    @Test func pushesBeforeARefreshShareOneNewFolder() async throws {
        let cloud = try await emptyCloud()
        let library = try temporaryLibrary()
        let first = try queue(library, title: "rePossess test one", folder: "Biology 101")
        let second = try queue(library, title: "rePossess test two", folder: "Biology 101")
        #expect(first.folderID == second.folderID)
        _ = try await library.sendPushes(paths: PushPaths(usb: nil, cloud: cloudSession(cloud)))
        #expect(try await cloud.currentRootIndex().entries.count == 3)

        // A third push after both were sent still finds the folder and does not make another.
        let third = try queue(library, title: "rePossess test three", folder: "Biology 101")
        #expect(third.folderID == first.folderID)
        _ = try await library.sendPushes(paths: PushPaths(usb: nil, cloud: cloudSession(cloud)))
        #expect(try await cloud.currentRootIndex().entries.count == 4)
    }

    @Test(arguments: [("Biology 201", ""), ("Biology 101", "f0000000-0000-4000-8000-0000000000b1")])
    func aCreatedFolderThatChangedIsNotReusedAfterARefresh(name: String, parent: String) async throws {
        let cloud = try await emptyCloud()
        let session = cloudSession(cloud)
        let library = try temporaryLibrary()
        let first = try queue(library, title: "rePossess test one", folder: "Biology 101")
        _ = try await library.sendPushes(paths: PushPaths(usb: nil, cloud: session))
        let oldID = try #require(first.folderID)
        try await changeFolder(cloud, id: oldID, name: name, parent: parent)
        _ = try await library.refreshCloud(session: session)
        let changed = try await cloud.currentRootIndex().entries.first { $0.id == oldID }

        let second = try queue(library, title: "rePossess test two", folder: "Biology 101")
        #expect(second.folderIsNew == true && second.folderID != oldID)
        let sent = try #require(try await library.sendPushes(paths: PushPaths(usb: nil, cloud: session)).first)
        #expect(sent.status == .sent)

        let newID = try #require(second.folderID)
        #expect(try await metadata(cloud, id: newID)["visibleName"] as? String == "Biology 101")
        #expect(try await metadata(cloud, id: newID)["parent"] as? String == "")
        #expect(try await metadata(cloud, id: second.id)["parent"] as? String == newID)
        #expect(try await cloud.currentRootIndex().entries.contains { $0 == changed })
        #expect(try await cloud.documentFiles(id: first.id).isEmpty == false)
    }

    @Test func aFolderChangedBehindAStaleMirrorFailsWithoutWriting() async throws {
        let cloud = try await emptyCloud()
        let session = cloudSession(cloud)
        let library = try temporaryLibrary()
        let first = try queue(library, title: "rePossess test one", folder: "Biology 101")
        _ = try await library.sendPushes(paths: PushPaths(usb: nil, cloud: session))
        let folderID = try #require(first.folderID)

        // The mirror has not refreshed, so the second push still lends the folder's ID.
        let second = try queue(library, title: "rePossess test two", folder: "Biology 101")
        #expect(second.folderID == folderID)
        try await changeFolder(cloud, id: folderID, name: "Biology 201", parent: "")
        await cloud.clearRequests()
        let failed = try #require(try await library.sendPushes(paths: PushPaths(usb: nil, cloud: session)).first)
        #expect(failed.status == .failed && failed.error?.contains("is named \"Biology 201\"") == true)
        #expect(await rootUpdates(cloud) == 0)

        try await changeFolder(cloud, id: folderID, name: "Biology 101", parent: "f0000000-0000-4000-8000-0000000000b1")
        let third = try queue(library, title: "rePossess test three", folder: "Biology 101")
        let moved = try #require(try await library.sendPushes(paths: PushPaths(usb: nil, cloud: session)).first)
        #expect(moved.id == third.id && moved.status == .failed)
        #expect(moved.error?.contains("no longer at the top level") == true)
        #expect(await rootUpdates(cloud) == 0)
    }

    @Test(arguments: ["", "trash"])
    func aLentFolderIDThatTheMirrorHasSeenIsNotLentAgain(parent: String) async throws {
        let library = try temporaryLibrary()
        let first = try queue(library, folder: "Biology 101")
        #expect(try queue(library, folder: "Biology 101").folderID == first.folderID)

        // The cloud lists the ID as a renamed folder, or as one in the trash.
        let cloud = try await emptyCloud()
        try await changeFolder(cloud, id: try #require(first.folderID), name: "Renamed", parent: parent)
        _ = try await library.refreshCloud(session: cloudSession(cloud))
        let later = try queue(library, folder: "Biology 101")
        #expect(later.folderIsNew == true && later.folderID != first.folderID)
    }

    @Test func aPushSentLongAgoStillLendsAnUnseenFolderID() throws {
        let library = try temporaryLibrary()
        let long = Date(timeIntervalSinceNow: -30 * 86400)
        let first = try library.enqueuePush(
            kind: .pdf,
            title: "rePossess test pdf",
            data: makePDF(["Invented page"]),
            folder: "Biology 101",
            now: long
        )
        var sent = try #require(try library.push(id: first.id))
        sent.status = .sent
        sent.sent = long
        try library.save(sent)
        #expect(try library.pushFolder(named: "Biology 101").id == first.folderID)
    }

    @Test func twoEnqueuesForTheSameNewNameGetOneFolderID() async throws {
        let library = try temporaryLibrary()
        let other = try Library(root: library.root)
        let ids = await withTaskGroup(of: String?.self) { group in
            for (index, queue) in [library, other, library, other].enumerated() {
                group.addTask {
                    let id = UUID().uuidString.lowercased()
                    return try? queue.enqueuePush(
                        id: id,
                        kind: .pdf,
                        title: "rePossess test \(index)",
                        data: makePDF(["Invented page"]),
                        folder: "Biology 101"
                    ).folderID
                }
            }
            var ids: [String?] = []
            for await id in group { ids.append(id) }
            return ids
        }
        #expect(ids.count == 4 && ids.allSatisfy { $0 != nil })
        #expect(Set(ids.compactMap { $0 }).count == 1)
        #expect(try library.pushes().count == 4)
    }

    @Test func twoFoldersWithTheNameRefuseThePush() async throws {
        let tablet = FakeTablet()
        await tablet.add(
            USBItem(id: "f0000000-0000-4000-8000-0000000000a1", type: "CollectionType", visibleName: "Math")
        )
        await tablet.add(
            USBItem(id: "f0000000-0000-4000-8000-0000000000a2", type: "CollectionType", visibleName: "Math")
        )
        let library = try temporaryLibrary()
        _ = try await library.refreshUSB(client: USBClient(transport: tablet, checkInterface: { true }))

        let error = try #require(
            throws: PushError.self,
            performing: { _ = try queue(library, folder: "Math") }
        )
        #expect(error.description.contains("2 top-level folders are named \"Math\""))
        #expect(error.description.contains("f0000000-0000-4000-8000-0000000000a1"))
        #expect(error.description.contains("f0000000-0000-4000-8000-0000000000a2"))
        #expect(try library.pushes().isEmpty)
    }

    @Test func aPushWithoutAFolderStaysAtTheTopLevel() async throws {
        let (library, cloud, session) = try await mirroredGarden()
        let before = try await cloud.currentRootIndex().entries
        let record = try queue(library, folder: nil)
        #expect(record.folder == nil && record.folderID == nil && record.folderIsNew == nil)
        let sent = try #require(try await library.sendPushes(paths: PushPaths(usb: nil, cloud: session)).first)
        #expect(sent.status == .sent && sent.folder == nil)
        #expect(try await cloud.currentRootIndex().entries.count == before.count + 1)
        #expect(try await metadata(cloud, id: record.id)["parent"] as? String == "")
    }

    @Test func aPushWithoutAFolderStillGoesOverUSBFirst() async throws {
        let library = try temporaryLibrary()
        let tablet = await uploadingTablet()
        let cloud = try await emptyCloud()
        _ = try queue(library, folder: nil)
        let sent = try #require(
            try await library.sendPushes(
                paths: PushPaths(usb: usbPath(tablet), cloud: cloudSession(cloud)),
                wait: noWait
            ).first
        )
        #expect(sent.via == .usb)
        #expect(await cloud.writes.isEmpty)
    }

    @Test func aFolderPushSkipsUSBAndUsesTheCloud() async throws {
        let library = try temporaryLibrary()
        let tablet = await uploadingTablet()
        let cloud = try await emptyCloud()
        let record = try queue(library, folder: "Biology 101")
        let sent = try #require(
            try await library.sendPushes(
                paths: PushPaths(usb: usbPath(tablet), cloud: cloudSession(cloud)),
                wait: noWait
            ).first
        )
        #expect(sent.via == .cloud && sent.id == record.id)
        #expect(await tablet.paths.isEmpty)
        #expect(await tablet.uploads.isEmpty)
    }

    @Test func aFolderPushWaitsWithoutTheCloud() async throws {
        let library = try temporaryLibrary()
        let tablet = await uploadingTablet()
        let record = try queue(library, folder: "Biology 101")
        let changed = try await library.sendPushes(paths: PushPaths(usb: usbPath(tablet), cloud: nil), wait: noWait)
        let waiting = try #require(changed.first)
        #expect(waiting.status == .pending && waiting.attempts == 0 && waiting.id == record.id)
        #expect(waiting.error?.contains("needs reMarkable's cloud") == true)
        #expect(await tablet.uploads.isEmpty)

        // The push goes out when the cloud is available, and only once.
        let cloud = try await emptyCloud()
        let sent = try #require(
            try await library.sendPushes(paths: PushPaths(usb: nil, cloud: cloudSession(cloud))).first
        )
        #expect(sent.status == .sent && sent.attempts == 1)
        #expect(try await cloud.currentRootIndex().entries.count == 2)
    }

    @Test func aMirroredFolderThatTheCloudLacksFailsWithoutWriting() async throws {
        let tablet = FakeTablet()
        await tablet.add(USBItem(id: Shelf.folder, type: "CollectionType", visibleName: "Garden"))
        let library = try temporaryLibrary()
        _ = try await library.refreshUSB(client: USBClient(transport: tablet, checkInterface: { true }))
        let cloud = try await emptyCloud()
        _ = try queue(library, folder: "Garden")
        let failed = try #require(
            try await library.sendPushes(paths: PushPaths(usb: nil, cloud: cloudSession(cloud))).first
        )
        #expect(failed.status == .failed && failed.error?.contains("not in the cloud root") == true)
        #expect(await cloud.writes.isEmpty)
    }

    @Test func aTrashedFolderIsNotUsed() async throws {
        let cloud = FakeCloud()
        let trashed = #"{"visibleName": "Garden", "type": "CollectionType", "parent": "trash"}"#
        let entry = try await cloud.seedDocument(
            id: Shelf.folder,
            files: [("\(Shelf.folder).metadata", Data(trashed.utf8)), ("\(Shelf.folder).content", Data("{}".utf8))]
        )
        try await cloud.seedRoot([entry])
        // A stale mirror that still lists the folder as live.
        let tablet = FakeTablet()
        await tablet.add(USBItem(id: Shelf.folder, type: "CollectionType", visibleName: "Garden"))
        let library = try temporaryLibrary()
        _ = try await library.refreshUSB(client: USBClient(transport: tablet, checkInterface: { true }))
        _ = try queue(library, folder: "Garden")
        let failed = try #require(
            try await library.sendPushes(paths: PushPaths(usb: nil, cloud: cloudSession(cloud))).first
        )
        #expect(failed.status == .failed && failed.error?.contains("in the trash") == true)
        #expect(await cloud.writes.isEmpty)
    }

    @Test func folderNamesAreChecked() throws {
        let library = try temporaryLibrary()
        for name in ["", "   ", "Math/Algebra", "Line\nbreak"] {
            #expect(throws: PushError.self) { _ = try library.pushFolder(named: name) }
        }
        #expect(try library.pushFolder(named: "  Math  ").name == "Math")
    }

    @Test func aLostRootUpdateIsCheckedAndNotRepeated() async throws {
        let cloud = try await emptyCloud()
        await cloud.set(rootUpdateLoss: .afterApplying)
        let library = try temporaryLibrary()
        let record = try queue(library, folder: "Biology 101")
        let sent = try #require(
            try await library.sendPushes(paths: PushPaths(usb: nil, cloud: cloudSession(cloud))).first
        )
        #expect(sent.status == .sent && sent.id == record.id)
        #expect(await rootUpdates(cloud) == 1)
        #expect(try await cloud.currentRootIndex().entries.count == 2)
    }

    @Test func theQueueKeepsTheFolderAcrossReopening() async throws {
        let library = try temporaryLibrary()
        let record = try queue(library, folder: "Biology 101")
        let reopened = try Library(root: library.root)
        let stored = try #require(try reopened.push(id: record.id))
        #expect(stored.folder == "Biology 101" && stored.folderID == record.folderID && stored.folderIsNew == true)
    }
}

/// Queues an invented Markdown note, with a folder or without one.
private func queue(_ library: Library, title: String = "rePossess test note", folder: String?) throws -> PushRecord {
    let id = UUID().uuidString.lowercased()
    let notebook = try MarkdownNotebook(title: title, markdown: "# Invented\n\n- one\n- two", documentID: id)
    return try library.enqueuePush(
        id: id,
        kind: .notebook,
        title: notebook.title,
        data: notebook.rmdoc,
        pages: notebook.pageCount,
        folder: folder
    )
}
