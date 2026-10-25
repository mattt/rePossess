import Foundation
import MCP
import Testing

@testable import RePossessCloud
@testable import RePossessFormat
@testable import RePossessLibrary
@testable import RePossessMCP
@testable import RePossessUSB

private func temporaryRoot(_ name: String = "link") -> URL {
    FileManager.default.temporaryDirectory.appending(path: "repossess-\(name)-\(UUID().uuidString)")
}

/// A transport that fails like a request that macOS keeps off the local network, a given number of times.
private actor RefusingTransport: USBTransport {
    var refusals: Int
    private(set) var tries = 0

    init(refusals: Int) { self.refusals = refusals }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        tries += 1
        if refusals > 0 {
            refusals -= 1
            throw USBError.localNetworkDenied
        }
        return (200, Data("[]".utf8))
    }

    func post(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws
        -> (status: Int, body: Data)
    {
        try await get(url, timeout: timeout)
    }
}

private actor Waits {
    var durations: [Duration] = []
    func add(_ d: Duration) { durations.append(d) }
}

@Suite struct AppLinkTests {
    @Test func theSocketIsInTheLibraryWhenItsPathFits() {
        let short = AppLink(libraryRoot: URL(filePath: "/Users/someone/Library/Application Support/rePossess"))
        #expect(short.path == "/Users/someone/Library/Application Support/rePossess/app.sock")
        let long = AppLink(libraryRoot: URL(filePath: "/" + String(repeating: "folder/", count: 20)))
        #expect(long.path.hasSuffix(".sock") && long.path.contains("repossess-"))
        #expect(long.path.utf8.count <= AppLink.maxPathLength)
        #expect(AppLink(libraryRoot: URL(filePath: "/" + String(repeating: "folder/", count: 20))).path == long.path)
    }

    @Test func aRequestGetsTheAppsAnswer() async throws {
        let link = AppLink(libraryRoot: temporaryRoot())
        #expect(!link.isAppRunning)
        await #expect(throws: AppLinkError.notRunning) { try await link.send(.refreshUSB, timeout: 5) }

        // A file left by an app that stopped is replaced.
        FileManager.default.createFile(atPath: link.path, contents: Data())
        var report = RefreshReport(source: .usb)
        report.listed = 4
        report.unchanged = 4
        let answer = report
        let server = AppLinkServer(link: link) { request in
            request == .refreshUSB ? AppLinkResponse(status: .done, reports: [answer]) : AppLinkResponse(status: .busy)
        }
        try server.start()
        defer { server.stop() }
        #expect(link.isAppRunning)
        #expect(throws: AppLinkError.self) { try AppLinkServer(link: link) { _ in .init(status: .busy) }.start() }

        let response = try await link.send(.refreshUSB, timeout: 5)
        #expect(response.status == .done && response.reports == [report])
        #expect(try await link.send(.sendPushes, timeout: 5).status == .busy)
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        server.stop()
        #expect(!link.isAppRunning)
        #expect(!FileManager.default.fileExists(atPath: link.path))
    }

    @Test func theHelperRefreshesThroughTheAppAndSendsNothingOverUSBItself() async throws {
        let library = try Library(root: temporaryRoot("handoff"))
        let link = AppLink(libraryRoot: library.root)
        var appReport = RefreshReport(source: .usb)
        appReport.listed = 2
        appReport.unchanged = 2
        let answer = appReport
        let server = AppLinkServer(link: link) { _ in AppLinkResponse(status: .done, reports: [answer]) }
        try server.start()
        defer { server.stop() }

        let tablet = FakeTablet()
        let reports = try await refreshLibrary(
            library,
            .usb,
            session: CloudSession(transport: FakeCloud(), deviceToken: { FakeCloud.deviceToken }),
            usb: { USBClient(transport: tablet, checkInterface: { true }) },
            usbPresent: { true },
            usbByApp: { try await link.refreshUSB(library: library) },
            pushes: PushPaths(usb: { USBClient(transport: tablet, checkInterface: { true }) }, cloud: nil)
        )
        #expect(reports.count == 1 && reports[0].byApp && reports[0].listed == 2)
        #expect(await tablet.paths.isEmpty)

        let tools = RePossessTools(
            library: library,
            refresh: { _ in reports },
            usbConnected: { true },
            cloudPaired: { false }
        )
        let text = texts(await call(tools, "refresh_documents", ["source": "usb"]))[0]
        #expect(text.hasPrefix("Refreshed from USB by rePossess.app in "))
    }

    @Test func withoutTheAppTheHelperRefreshesItself() async throws {
        let library = try Library(root: temporaryRoot("handoff"))
        let link = AppLink(libraryRoot: library.root)
        let tablet = FakeTablet()
        let reports = try await refreshLibrary(
            library,
            .usb,
            session: CloudSession(transport: FakeCloud(), deviceToken: { FakeCloud.deviceToken }),
            usb: { USBClient(transport: tablet, checkInterface: { true }) },
            usbPresent: { true },
            usbByApp: { try await link.refreshUSB(library: library) }
        )
        #expect(reports.count == 1 && !reports[0].byApp && reports[0].stoppedBy == nil)
        #expect(await tablet.paths == ["/documents/"])
    }

    @Test func aLateAnswerFallsBackToTheLibrarysUSBRecord() async throws {
        let library = try Library(root: temporaryRoot("handoff"))
        let link = AppLink(libraryRoot: library.root)
        let server = AppLinkServer(link: link) { _ in
            // The app records a success and answers too late.
            try? library.recordRefreshSuccess(.usb)
            try? await Task.sleep(for: .seconds(3))
            return AppLinkResponse(status: .done)
        }
        try server.start()
        defer { server.stop() }
        let report = try #require(try await link.refreshUSB(library: library, timeout: 1))
        #expect(report.byApp && report.stoppedBy == nil)
    }

    @Test func pushesGoThroughTheAppWhenTheTabletIsOnUSB() async throws {
        let library = try Library(root: temporaryRoot("handoff"))
        let link = AppLink(libraryRoot: library.root)
        let asked = Waits()
        let server = AppLinkServer(link: link) { request in
            await asked.add(.seconds(request == .sendPushes ? 1 : 0))
            return AppLinkResponse(status: .done)
        }
        try server.start()
        defer { server.stop() }
        let tablet = FakeTablet()
        let pusher = Pusher(
            library: library,
            paths: { PushPaths(usb: { USBClient(transport: tablet, checkInterface: { true }) }, cloud: nil) },
            byApp: { try await link.sendPushes() }
        )
        let result = try await pusher.pushMarkdown(title: "Invented", markdown: "# Invented", paginate: false)
        #expect(result.status == "queued")
        #expect(await asked.durations == [.seconds(1)])
        #expect(await tablet.uploads.isEmpty)
        #expect(await tablet.paths.isEmpty)
    }
}

@Suite struct LocalNetworkTests {
    @Test func anOfflineErrorOnTheTabletsNetworkIsALocalNetworkRefusal() {
        let url = URL(string: "http://10.11.99.1/documents/")!
        let offline = URLError(.notConnectedToInternet)
        #expect(
            URLSessionUSBTransport.usbError(offline, url: url, timeout: 10, usbPresent: true) == .localNetworkDenied
        )
        if case .network = URLSessionUSBTransport.usbError(offline, url: url, timeout: 10, usbPresent: false) {
        } else {
            Issue.record("without the USB network, offline is a network error")
        }
        #expect(USBError.localNetworkDenied.description.contains("Privacy & Security > Local Network"))
        #expect(USBError.localNetworkDenied.description.contains("rePossess.app"))
    }

    @Test func aRefusalIsTriedAgainBriefly() async throws {
        let waits = Waits()
        let transport = RefusingTransport(refusals: 1)
        let client = USBClient(transport: transport, checkInterface: { true }, wait: { await waits.add($0) })
        #expect(try await client.list().isEmpty)
        #expect(await transport.tries == 2)
        #expect(await waits.durations == [.seconds(3)])

        let refusing = RefusingTransport(refusals: 10)
        let stubborn = USBClient(transport: refusing, checkInterface: { true }, wait: { _ in })
        await #expect(throws: USBError.localNetworkDenied) { try await stubborn.list() }
        #expect(await refusing.tries == 3)
    }
}
