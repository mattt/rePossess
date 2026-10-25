import Foundation
import Testing

@testable import RePossessUSB

@Suite struct USBTests {
    private func client(_ tablet: FakeTablet, connected: Bool = true) -> USBClient {
        USBClient(transport: tablet, checkInterface: { connected })
    }

    @Test func routesAreTheThreeThatWork() throws {
        #expect(try USBRoute.documents(folder: nil).path() == "/documents/")
        #expect(try USBRoute.documents(folder: "ab-12").path() == "/documents/ab-12")
        #expect(try USBRoute.rmdoc(id: "ab-12").path() == "/download/ab-12/rmdoc")
        #expect(try USBRoute.pdf(id: "ab-12").path() == "/download/ab-12/pdf")
        #expect(throws: USBError.invalidID("../thumbnail/x")) { try USBRoute.rmdoc(id: "../thumbnail/x").path() }
        #expect(throws: USBError.invalidID("x?y")) { try USBRoute.documents(folder: "x?y").path() }
    }

    @Test func decodesTheListingWithEitherNameKey() throws {
        let json = """
            [{"ID": "d1", "Type": "DocumentType", "fileType": "notebook", "ModifiedClient": "2026-10-25T07:00:00.000Z",
              "Parent": "", "VissibleName": "Only the misspelled key", "Bookmarked": false, "CurrentPage": 2},
             {"ID": "f1", "Type": "CollectionType", "Parent": "", "VisibleName": "Folder", "VissibleName": "Folder"}]
            """
        let items = try JSONDecoder().decode([USBItem].self, from: Data(json.utf8))
        #expect(items[0].visibleName == "Only the misspelled key")
        #expect(items[0].modifiedClient == "2026-10-25T07:00:00.000Z")
        #expect(items[1].isFolder)
    }

    @Test func listsEveryFolderOneRequestAtATime() async throws {
        let tablet = FakeTablet()
        await tablet.add(USBItem(id: "f1", type: "CollectionType", visibleName: "Folder"))
        await tablet.add(USBItem(id: "f2", type: "CollectionType", parent: "f1", visibleName: "Inner"))
        await tablet.add(USBItem(id: "d1", type: "DocumentType", parent: "f2", visibleName: "Deep"))
        await tablet.add(USBItem(id: "d2", type: "DocumentType", visibleName: "Top"))
        let usb = client(tablet)
        let items = try await usb.listAll()
        #expect(Set(items.map(\.id)) == ["f1", "f2", "d1", "d2"])
        #expect(await tablet.paths == ["/documents/", "/documents/f1", "/documents/f2"])

        // Concurrent calls still reach the tablet one at a time.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 5 { group.addTask { _ = try? await usb.list() } }
        }
        #expect(await tablet.maxConcurrent == 1)
    }

    @Test func stopsAfterATimeout() async throws {
        let tablet = FakeTablet()
        await tablet.add(USBItem(id: "d1", type: "DocumentType", visibleName: "A"), rmdoc: Data([1]))
        await tablet.setHang(true)
        let usb = client(tablet)
        await #expect(throws: USBError.timedOut(route: "/documents/", seconds: 10)) { try await usb.list() }
        await tablet.setHang(false)
        await #expect(throws: USBError.stopped) { try await usb.rmdoc(id: "d1") }
        #expect(await tablet.paths == ["/documents/"])
        #expect(USBError.timedOut(route: "/documents/", seconds: 10).description.contains("off and on"))
    }

    @Test func notConnectedSendsNothing() async throws {
        let tablet = FakeTablet()
        await #expect(throws: USBError.notConnected) { try await client(tablet, connected: false).list() }
        #expect(await tablet.paths.isEmpty)
    }

    @Test func downloadsAndReportsHTTPErrors() async throws {
        let tablet = FakeTablet()
        await tablet.add(
            USBItem(id: "d1", type: "DocumentType", visibleName: "A"),
            rmdoc: Data([1, 2]),
            pdf: Data([3])
        )
        let usb = client(tablet)
        #expect(try await usb.rmdoc(id: "d1") == Data([1, 2]))
        #expect(try await usb.pdf(id: "d1") == Data([3]))
        await #expect(throws: USBError.http(route: "/download/d9/rmdoc", status: 404)) { try await usb.rmdoc(id: "d9") }
        #expect(await usb.requested == [.rmdoc(id: "d1"), .pdf(id: "d1"), .rmdoc(id: "d9")])
    }
}
