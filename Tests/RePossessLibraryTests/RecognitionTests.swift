import Foundation
import Testing

@testable import RePossessFormat
@testable import RePossessLibrary
@testable import RePossessUSB

@Suite struct RecognitionCacheTests {
    let key = RecognitionKey(provider: "fake", model: "reader-1", promptVersion: "v1")

    func library() async throws -> (Library, FakeTablet) {
        let tablet = FakeTablet()
        try await Shelf.stock(tablet)
        let library = try temporaryLibrary()
        _ = try await library.refreshUSB(client: USBClient(transport: tablet, checkInterface: { true }))
        return (library, tablet)
    }

    func recognition(_ hash: String, _ text: String, key: RecognitionKey? = nil, status: Recognition.Status = .text)
        -> Recognition
    {
        Recognition(
            key: key ?? self.key,
            strokeHash: hash,
            status: status,
            text: text,
            label: "Fake reader",
            strips: 1,
            seconds: 0.5
        )
    }

    @Test func pagesWithStrokesHaveAHash() async throws {
        let (library, _) = try await library()
        let sketches = try library.pages(of: Shelf.handwritten)
        #expect(sketches[0].strokeHash?.count == 64 && sketches[1].strokeHash == nil)
        let ink = try library.inkPages()
        #expect(ink.map(\.documentID) == [Shelf.typed, Shelf.annotated, Shelf.handwritten])
        #expect(try library.inkPages(documentID: Shelf.typed).map(\.number) == [2])
    }

    @Test func storesAndReadsARecognition() async throws {
        let (library, _) = try await library()
        let hash = try #require(try library.pages(of: Shelf.handwritten)[0].strokeHash)
        #expect(try library.recognition(strokeHash: hash, key: key) == nil)
        try library.storeRecognition(recognition(hash, "Pumpkin trellis plan"))
        let stored = try #require(try library.recognition(strokeHash: hash, key: key))
        #expect(stored.text == "Pumpkin trellis plan" && stored.label == "Fake reader" && stored.status == .text)
        let other = RecognitionKey(provider: "fake", model: "reader-2", promptVersion: "v1")
        #expect(try library.recognition(strokeHash: hash, key: other) == nil)
        let counts = try library.recognitionCounts(key: key)
        #expect(counts.pagesWithInk == 3 && counts.text == 1 && counts.waiting == 2)
    }

    @Test func searchFindsHandwritingOnlyForTheActiveKey() async throws {
        let (library, _) = try await library()
        let hash = try #require(try library.pages(of: Shelf.handwritten)[0].strokeHash)
        try library.storeRecognition(recognition(hash, "Pumpkin trellis plan"))
        #expect(try library.search("pumpkin").total == 0)
        try library.setActiveRecognitionKey(key)
        let hits = try library.search("trellis").hits
        #expect(hits.count == 1 && hits[0].match == .handwriting && hits[0].pageNo == 1)
        #expect(hits[0].item.id == Shelf.handwritten && hits[0].snippet.contains("trellis"))
        try library.setActiveRecognitionKey(nil)
        #expect(try library.search("trellis").total == 0)
        try library.setActiveRecognitionKey(key)
        #expect(try library.search("trellis").total == 1)
    }

    @Test func aRecognitionStoredWhileActiveIsSearchableAtOnce() async throws {
        let (library, _) = try await library()
        try library.setActiveRecognitionKey(key)
        let hash = try #require(try library.pages(of: Shelf.handwritten)[0].strokeHash)
        try library.storeRecognition(recognition(hash, "Compost rota"))
        #expect(try library.search("compost").hits.map(\.match) == [.handwriting])
        // A refusal replaces the text and takes it out of search.
        try library.storeRecognition(recognition(hash, "", status: .refused))
        #expect(try library.search("compost").total == 0)
    }

    @Test func onePageMatchesOnceWhenTextAndHandwritingBothMatch() async throws {
        let (library, _) = try await library()
        try library.setActiveRecognitionKey(key)
        let page = try library.pages(of: Shelf.typed)[1]
        try library.storeRecognition(recognition(try #require(page.strokeHash), "Lighthouse keeper ticks"))
        let hits = try library.search("lighthouse").hits
        #expect(hits.count == 1 && hits[0].pageNo == 2)
    }

    @Test func aRefreshKeepsTheHandwritingOfUnchangedStrokes() async throws {
        let (library, tablet) = try await library()
        try library.setActiveRecognitionKey(key)
        let page = try library.pages(of: Shelf.typed)[1]
        try library.storeRecognition(recognition(try #require(page.strokeHash), "Beans by the gate"))
        // A new version of the typed notebook: different text, the same strokes.
        await tablet.add(
            USBItem(
                id: Shelf.typed,
                type: "DocumentType",
                fileType: "notebook",
                modifiedClient: "2026-10-26T07:00:00.000Z",
                parent: Shelf.folder,
                visibleName: "Garden notes"
            ),
            rmdoc: try Shelf.typedDocument(extra: " again").rmdoc()
        )
        let report = try await library.refreshUSB(client: USBClient(transport: tablet, checkInterface: { true }))
        #expect(report.downloaded == 1)
        #expect(try library.pages(of: Shelf.typed)[1].strokeHash == page.strokeHash)
        #expect(try library.search("gate").hits.map(\.match) == [.handwriting])
    }

    @Test func migrationFromVersion2AddsHashesAndKeepsSearch() async throws {
        let (library, _) = try await library()
        let root = library.root
        let hash = try library.pages(of: Shelf.handwritten)[0].strokeHash
        // Make the database a version 2 library again: no stroke hashes and the old search table.
        try library.database.execute(
            """
            DROP TABLE recognitions;
            ALTER TABLE pages DROP COLUMN stroke_hash;
            DROP TABLE page_text;
            CREATE VIRTUAL TABLE page_text USING fts5(document_id UNINDEXED, number UNINDEXED, body,
              tokenize = 'unicode61 remove_diacritics 2');
            INSERT INTO page_text (document_id, number, body)
              SELECT document_id, number, markdown FROM pages WHERE has_text = 1;
            PRAGMA user_version = 2;
            """
        )
        let reopened = try Library(root: root)
        #expect(try reopened.pages(of: Shelf.handwritten)[0].strokeHash == hash)
        #expect(try reopened.search("lighthouse").hits.map(\.match) == [.text])
        #expect(try reopened.database.query("PRAGMA user_version").first?.first?.int == 4)
    }
}
