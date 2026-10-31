import Foundation
import Testing

@testable import RePossessCloud
@testable import RePossessFormat
@testable import RePossessLibrary
@testable import RePossessUSB

/// A fake tablet that names an uploaded rmdoc from its metadata, as the Paper Pure does.
func uploadingTablet() async -> FakeTablet {
    let tablet = FakeTablet()
    await tablet.set(nameForUpload: { fileName, data in
        if fileName.hasSuffix(".rmdoc"), let archive = try? RmdocArchive(data: data),
            let file = archive.files.first(where: { $0.name.hasSuffix(".metadata") }),
            let metadata = try? DocumentMetadata(parsing: file.data)
        {
            return metadata.visibleName
        }
        return (fileName as NSString).deletingPathExtension
    })
    return tablet
}

/// An empty fake cloud with a schema 3 root.
func emptyCloud() async throws -> FakeCloud {
    let cloud = FakeCloud()
    try await cloud.seedRoot([], schema: .v3)
    return cloud
}

func cloudSession(_ cloud: FakeCloud) -> CloudSession {
    CloudSession(transport: cloud, deviceToken: { FakeCloud.deviceToken })
}

func usbPath(_ tablet: FakeTablet) -> @Sendable () -> USBClient {
    { USBClient(transport: tablet, checkInterface: { true }) }
}

let noWait: @Sendable (Duration) async -> Void = { _ in }

/// Queues an invented Markdown note and returns its record.
func queueNote(_ library: Library, title: String = "rePossess test note") throws -> PushRecord {
    let id = UUID().uuidString.lowercased()
    let notebook = try MarkdownNotebook(title: title, markdown: "# Invented\n\n- one\n- two", documentID: id)
    return try library.enqueuePush(
        id: id,
        kind: .notebook,
        title: notebook.title,
        data: notebook.rmdoc,
        pages: notebook.pageCount
    )
}

@Suite struct PushQueueTests {
    @Test func waitsWithoutAPathAndKeepsItsPayload() async throws {
        let library = try temporaryLibrary()
        let record = try queueNote(library)
        #expect(try await library.sendPushes(paths: .none).isEmpty)
        let stored = try #require(try library.push(id: record.id))
        #expect(stored.status == .pending && stored.attempts == 0 && stored.kind == .notebook && stored.pages == 1)
        #expect(FileManager.default.fileExists(atPath: library.payloadURL(stored).path))
        #expect(try library.pushCounts() == [.pending: 1])
    }

    @Test func goesOverUSBFirstAndFindsTheTabletsID() async throws {
        let library = try temporaryLibrary()
        let tablet = await uploadingTablet()
        let cloud = try await emptyCloud()
        let record = try queueNote(library)
        let changed = try await library.sendPushes(
            paths: PushPaths(usb: usbPath(tablet), cloud: cloudSession(cloud)),
            wait: noWait
        )
        let sent = try #require(changed.first)
        #expect(sent.id == record.id && sent.status == .sent && sent.via == .usb && sent.attempts == 1)
        let item = try #require(await tablet.items.first)
        #expect(item.visibleName == "rePossess test note" && sent.tabletID == item.id && item.id != record.id)
        #expect(await tablet.paths == ["/documents/", "POST /upload", "/documents/"])
        #expect(await cloud.writes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.payloadURL(sent).path))
        // Nothing is left to send.
        #expect(try await library.sendPushes(paths: PushPaths(usb: usbPath(tablet), cloud: nil)).isEmpty)
    }

    @Test func goesThroughTheCloudWithoutUSB() async throws {
        let library = try temporaryLibrary()
        let cloud = try await emptyCloud()
        let pdf = makePDF(["Invented page"])
        let record = try library.enqueuePush(kind: .pdf, title: "rePossess test pdf", data: pdf)
        let sent = try #require(
            try await library.sendPushes(paths: PushPaths(usb: nil, cloud: cloudSession(cloud))).first
        )
        #expect(sent.status == .sent && sent.via == .cloud && sent.tabletID == record.id)
        #expect(await cloud.schemaVersion == 3)
        let files = try await cloud.documentFiles(id: record.id)
        #expect(files["\(record.id).pdf"] == pdf)
        let metadata = try DocumentMetadata(parsing: try #require(files["\(record.id).metadata"]))
        #expect(metadata.visibleName == "rePossess test pdf")
    }

    @Test func aNotebookThroughTheCloudKeepsItsPages() async throws {
        let library = try temporaryLibrary()
        let cloud = try await emptyCloud()
        let record = try queueNote(library)
        _ = try await library.sendPushes(paths: PushPaths(usb: nil, cloud: cloudSession(cloud)))
        let files = try await cloud.documentFiles(id: record.id)
        #expect(files.keys.filter { $0.hasSuffix(".rm") }.count == 1)
        #expect(files["\(record.id).content"] != nil)
    }

    @Test func fallsBackToTheCloudWhenUSBDidNotTakeIt() async throws {
        let library = try temporaryLibrary()
        let cloud = try await emptyCloud()
        let record = try queueNote(library)
        let offline = USBClient(transport: FakeTablet(), checkInterface: { false })
        let sent = try #require(
            try await library.sendPushes(paths: PushPaths(usb: { offline }, cloud: cloudSession(cloud))).first
        )
        #expect(sent.status == .sent && sent.via == .cloud)
        #expect(try await cloud.currentRootIndex().entries.map(\.id) == [record.id])
    }

    @Test func aUSBTimeoutIsCheckedBeforeAnotherSend() async throws {
        let library = try temporaryLibrary()
        let tablet = await uploadingTablet()
        let cloud = try await emptyCloud()
        await tablet.set(uploadBehavior: .acceptThenTimeOut)
        let record = try queueNote(library)
        let paths = PushPaths(usb: usbPath(tablet), cloud: cloudSession(cloud))
        let first = try #require(try await library.sendPushes(paths: paths, wait: noWait).first)
        #expect(first.status == .unknown && first.via == .usb)
        // Not sent through the cloud as well: that would make a second copy.
        #expect(await cloud.writes.isEmpty)

        await tablet.set(uploadBehavior: .accept)
        let second = try #require(try await library.sendPushes(paths: paths, wait: noWait).first)
        #expect(second.status == .sent && second.via == .usb && second.attempts == 1)
        #expect(second.tabletID == (await tablet.items.first?.id))
        #expect(await tablet.uploads.count == 1)
        #expect(record.id == second.id)
    }

    @Test func aUSBUploadThatDidNotArriveIsSentAgain() async throws {
        let library = try temporaryLibrary()
        let tablet = await uploadingTablet()
        await tablet.set(uploadBehavior: .timeOut)
        _ = try queueNote(library)
        let paths = PushPaths(usb: usbPath(tablet), cloud: nil)
        #expect(try await library.sendPushes(paths: paths, wait: noWait).first?.status == .unknown)
        await tablet.set(uploadBehavior: .accept)
        let sent = try #require(try await library.sendPushes(paths: paths, wait: noWait).first)
        #expect(sent.status == .sent && sent.attempts == 2)
        #expect(await tablet.items.count == 1)
    }

    @Test func anUnknownUSBSendWaitsForUSB() async throws {
        let library = try temporaryLibrary()
        let tablet = await uploadingTablet()
        let cloud = try await emptyCloud()
        await tablet.set(uploadBehavior: .acceptThenTimeOut)
        let record = try queueNote(library)
        _ = try await library.sendPushes(paths: PushPaths(usb: usbPath(tablet), cloud: nil), wait: noWait)
        // Only the cloud is available: the push stays unknown, and the cloud gets nothing.
        #expect(try await library.sendPushes(paths: PushPaths(usb: nil, cloud: cloudSession(cloud))).isEmpty)
        #expect(try library.push(id: record.id)?.status == .unknown)
        #expect(await cloud.writes.isEmpty)
    }

    @Test func aSameNamedDocumentFromBeforeIsNotAMatch() async throws {
        let library = try temporaryLibrary()
        let tablet = await uploadingTablet()
        await tablet.add(
            USBItem(
                id: "a0000000-0000-4000-8000-000000000001",
                type: "DocumentType",
                modifiedClient: "2026-10-25T07:00:00.000Z",
                visibleName: "rePossess test note"
            )
        )
        await tablet.set(uploadBehavior: .timeOut)
        _ = try queueNote(library)
        let paths = PushPaths(usb: usbPath(tablet), cloud: nil)
        let unknown = try #require(try await library.sendPushes(paths: paths, wait: noWait).first)
        #expect(unknown.preexisting == ["a0000000-0000-4000-8000-000000000001"])
        await tablet.set(uploadBehavior: .accept)
        let sent = try #require(try await library.sendPushes(paths: paths, wait: noWait).first)
        #expect(sent.status == .sent && sent.tabletID != "a0000000-0000-4000-8000-000000000001")
        #expect(await tablet.uploads.count == 2)
    }

    @Test func aRefusalFailsThePushForGood() async throws {
        let library = try temporaryLibrary()
        let tablet = await uploadingTablet()
        await tablet.set(uploadBehavior: .status(415))
        _ = try queueNote(library)
        let paths = PushPaths(usb: usbPath(tablet), cloud: nil)
        let failed = try #require(try await library.sendPushes(paths: paths, wait: noWait).first)
        #expect(failed.status == .failed && failed.error?.contains("415") == true)
        #expect(try await library.sendPushes(paths: paths, wait: noWait).isEmpty)
        #expect(try library.dropPush(id: failed.id).id == failed.id)
        #expect(try library.pushes().isEmpty)
    }

    @Test func aLostCloudUpdateIsFoundByItsID() async throws {
        let library = try temporaryLibrary()
        let cloud = try await emptyCloud()
        await cloud.set(rootUpdateLoss: .afterApplying, failRootReadsAfterLoss: true)
        let record = try queueNote(library)
        let paths = PushPaths(usb: nil, cloud: cloudSession(cloud))
        let unknown = try #require(try await library.sendPushes(paths: paths).first)
        #expect(unknown.status == .unknown && unknown.via == .cloud)

        await cloud.set(failRootReadsAfterLoss: false)
        let sent = try #require(try await library.sendPushes(paths: paths).first)
        #expect(sent.status == .sent && sent.via == .cloud && sent.tabletID == record.id)
        #expect(await cloud.writes.filter { $0 == "PUT roothash" }.count == 1)
    }

    @Test func aPushLeftSendingIsCheckedFirst() async throws {
        let library = try temporaryLibrary()
        let cloud = try await emptyCloud()
        var record = try queueNote(library)
        record.status = .sending
        record.via = .cloud
        record.attempts = 1
        try library.save(record)
        let sent = try #require(
            try await library.sendPushes(paths: PushPaths(usb: nil, cloud: cloudSession(cloud))).first
        )
        // The check found nothing in the cloud, so the push went out.
        #expect(sent.status == .sent && sent.attempts == 2)
    }

    @Test func refusesWhatItCannotSend() throws {
        let library = try temporaryLibrary()
        #expect(throws: (any Error).self) {
            try library.enqueuePush(kind: .pdf, title: "\n", data: Data("%PDF-".utf8))
        }
        let big = Data(count: Library.maxPushBytes + 1)
        #expect(throws: PushError.self) { try library.enqueuePush(kind: .pdf, title: "big", data: big) }
        #expect(throws: PushError.self) { try library.dropPush(id: "nope") }
    }

    @Test func aRefreshHoldsTheQueue() async throws {
        let library = try temporaryLibrary()
        _ = try queueNote(library)
        try await library.withRefreshLock {
            await #expect(throws: RefreshError.self) { try await library.sendPushes(paths: .none) }
        }
    }
}

@Suite struct ExportTests {
    func usb(_ tablet: FakeTablet) -> USBClient { USBClient(transport: tablet, checkInterface: { true }) }

    @Test func keepsTheTabletsExportOfTypedDocumentsByModificationTime() async throws {
        let tablet = FakeTablet()
        try await Shelf.stock(tablet)
        let library = try temporaryLibrary()
        _ = try await library.refreshUSB(client: usb(tablet))
        let typed = try #require(try library.item(id: Shelf.typed))
        guard case .current(let export) = try library.exportState(for: typed) else {
            Issue.record("expected a current export")
            return
        }
        #expect(export.pages == 2 && export.modified == typed.modified)
        #expect(try Data(contentsOf: export.url) == Shelf.typedExport)
        // Documents without typed text need none.
        let sketches = try #require(try library.item(id: Shelf.handwritten))
        #expect(try library.exportState(for: sketches) == .notNeeded)
        // Only the typed notebook's export was requested.
        #expect(await tablet.paths.filter { $0.hasSuffix("/pdf") } == ["/download/\(Shelf.typed)/pdf"])

        // A refresh without changes downloads no export again.
        let again = try await library.refreshUSB(client: usb(tablet))
        #expect(again.exportsDownloaded == 0 && again.requests == 2)
    }

    @Test func aNewerCopyFromTheCloudMakesTheExportStale() async throws {
        let tablet = FakeTablet()
        try await Shelf.stock(tablet)
        let library = try temporaryLibrary()
        _ = try await library.refreshUSB(client: usb(tablet))
        let cloud = FakeCloud()
        var newer = Shelf.typedDocument(extra: " from the cloud")
        newer.lastModified = Date(timeIntervalSince1970: 1_792_900_000)
        _ = try await Shelf.stock(cloud, typed: newer)
        _ = try await library.refreshCloud(session: cloudSession(cloud))
        let typed = try #require(try library.item(id: Shelf.typed))
        guard case .stale = try library.exportState(for: typed) else {
            Issue.record("expected a stale export")
            return
        }
        // The next USB refresh downloads the tablet's copy and a new export.
        try await Shelf.stock(tablet, typedModified: "2026-10-26T07:00:00.000Z")
        let report = try await library.refreshUSB(client: usb(tablet))
        #expect(report.exportsDownloaded == 1)
        guard case .current = try library.exportState(for: try #require(try library.item(id: Shelf.typed))) else {
            Issue.record("expected a current export")
            return
        }
    }

    @Test func anExportThatTheTabletRefusesIsCountedAndTriedAgain() async throws {
        let tablet = FakeTablet()
        try await Shelf.stock(tablet)
        await tablet.add(
            USBItem(
                id: Shelf.typed,
                type: "DocumentType",
                fileType: "notebook",
                modifiedClient: "2026-10-25T07:00:00.000Z",
                parent: Shelf.folder,
                visibleName: "Garden notes"
            ),
            rmdoc: try Shelf.typedDocument().rmdoc()
        )
        await tablet.removePDF(id: Shelf.typed)
        let library = try temporaryLibrary()
        let report = try await library.refreshUSB(client: usb(tablet))
        #expect(report.exportsFailed == 1 && report.stoppedBy == nil)
        let typed = try #require(try library.item(id: Shelf.typed))
        #expect(try library.exportState(for: typed) == .missing)
        // The export is not needed for the refresh to succeed, and a refresh without exports asks for none.
        let without = try await library.refreshUSB(client: usb(tablet), exports: false)
        #expect(without.requests == 2)
    }

    @Test func removingADocumentRemovesItsExport() async throws {
        let tablet = FakeTablet()
        try await Shelf.stock(tablet)
        let library = try temporaryLibrary()
        _ = try await library.refreshUSB(client: usb(tablet))
        await tablet.remove(id: Shelf.typed)
        _ = try await library.refreshUSB(client: usb(tablet))
        #expect(try library.export(for: Shelf.typed) == nil)
        #expect(!FileManager.default.fileExists(atPath: library.exportURL(Shelf.typed).path))
    }
}

@Suite struct MigrationTests {
    @Test func versionOneLibrariesGainTheNewStatusesAndLoseUntimedErrors() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "repossess-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try Database(url: root.appending(path: "library.sqlite"))
        // The version 1 schema, with invented rows: a scan, a handwritten notebook, and an annotated PDF.
        try database.execute(
            """
            CREATE TABLE items (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL,
              parent TEXT NOT NULL DEFAULT '', file_type TEXT, modified REAL, page_count INTEGER NOT NULL DEFAULT 0,
              content_status TEXT NOT NULL DEFAULT 'text', summary TEXT NOT NULL DEFAULT '',
              tags TEXT NOT NULL DEFAULT '[]', source TEXT NOT NULL, usb_modified TEXT, cloud_hash TEXT,
              trashed INTEGER NOT NULL DEFAULT 0, refreshed REAL NOT NULL, error TEXT);
            CREATE TABLE pages (document_id TEXT NOT NULL, number INTEGER NOT NULL, page_id TEXT NOT NULL,
              source_page INTEGER, markdown TEXT NOT NULL DEFAULT '', has_text INTEGER NOT NULL,
              needs_image INTEGER NOT NULL, stroke_count INTEGER NOT NULL, tags TEXT NOT NULL DEFAULT '[]',
              warnings TEXT NOT NULL DEFAULT '[]', PRIMARY KEY (document_id, number));
            CREATE VIRTUAL TABLE page_text USING fts5(document_id UNINDEXED, number UNINDEXED, body);
            CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO items (id, kind, name, file_type, content_status, source, refreshed) VALUES
              ('scan', 'DocumentType', 'Scan', 'pdf', 'ink', 'usb', 0),
              ('hand', 'DocumentType', 'Hand', 'notebook', 'ink', 'usb', 0),
              ('note', 'DocumentType', 'Note', 'notebook', 'text', 'usb', 0),
              ('marked', 'DocumentType', 'Marked', 'pdf', 'text', 'usb', 0);
            INSERT INTO pages VALUES ('scan', 1, 's1', 0, '', 0, 1, 0, '[]', '[]'),
              ('hand', 1, 'h1', NULL, '', 0, 1, 3, '[]', '[]'),
              ('note', 1, 'n1', NULL, 'Typed', 1, 0, 0, '[]', '[]'),
              ('marked', 1, 'm1', 0, 'Printed', 1, 1, 2, '[]', '[]');
            INSERT INTO state VALUES ('usb.last_refresh', '1792800000'), ('usb.last_error', 'old timeout'),
              ('cloud.last_error', 'timed error'), ('cloud.last_error_at', '1792900000');
            PRAGMA user_version = 1;
            """
        )
        let library = try Library(root: root)
        let statuses = Dictionary(uniqueKeysWithValues: try library.documents().map { ($0.id, $0.contentStatus) })
        #expect(statuses == ["scan": .image, "hand": .ink, "note": .text, "marked": .annotated])
        let status = try library.status()
        #expect(status.lastError[.usb] == nil && status.lastError[.cloud] == "timed error")
        let note = try #require(try library.item(id: "note"))
        #expect(try library.exportState(for: note) == .missing)
        let hand = try #require(try library.item(id: "hand"))
        #expect(try library.exportState(for: hand) == .notNeeded)
    }
}
