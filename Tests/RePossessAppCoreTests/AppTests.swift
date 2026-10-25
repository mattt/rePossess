import Foundation
import Testing

@testable import RePossessAppCore
@testable import RePossessCloud
@testable import RePossessLibrary
@testable import RePossessRecognize

@Suite struct OptionsTests {
    @Test func takesTheLibraryAndTheKeychainSwitchLikeTheCommand() {
        let options = AppOptions(
            arguments: ["-NSDocumentRevisionsDebugMode", "YES", "--library", "/tmp/invented-library", "--no-keychain"],
            environment: [:]
        )
        #expect(
            options.libraryRoot.path == "/tmp/invented-library" && !options.isDefaultLibrary && !options.usesKeychain
        )
        let fromEnvironment = AppOptions(
            arguments: [],
            environment: ["REPOSSESS_LIBRARY": "/tmp/invented-other", "REPOSSESS_NO_KEYCHAIN": "1"]
        )
        #expect(fromEnvironment.libraryRoot.path == "/tmp/invented-other" && !fromEnvironment.usesKeychain)
        let plain = AppOptions(arguments: [], environment: [:])
        #expect(plain.isDefaultLibrary && plain.usesKeychain && plain.libraryRoot == Library.defaultRoot)
    }

    @Test func withoutTheKeychainNothingIsPairedOrStored() {
        let store = NoKeychain()
        #expect(DeviceTokenKeychain.pairedService(in: store) == nil)
        #expect(throws: NoKeychainError.self) { try store.add("invented", service: "rePossess") }
        #expect(throws: NoKeychainError.self) { try DeviceTokenKeychain.read(from: store) }
        #expect(throws: NoKeychainError.self) { try Pairing(store: store).unpair() }
    }

    @Test func thePairButtonWantsEightLettersOrDigits() {
        #expect(PairingCode.isPlausible("abcd1234") && PairingCode.isPlausible(" ABCD1234\n"))
        #expect(!PairingCode.isPlausible("abcd123") && !PairingCode.isPlausible("abcd-123"))
    }

    @MainActor @Test func appRefusesToPairWithoutTheKeychain() async throws {
        let library = try temporaryLibrary("model")
        let defaults = UserDefaults(suiteName: "repossess-test-\(UUID().uuidString)")!
        let model = AppModel(
            options: AppOptions(libraryRoot: library.root, isDefaultLibrary: false, usesKeychain: false),
            defaults: defaults
        )
        #expect(model.snapshot.pairing == .keychainOff)
        #expect(await model.pair(code: "abcd1234") == NoKeychain.message)
        #expect(model.unpair() == NoKeychain.message)
        #expect(throws: NoKeychainError.self) { try model.saveAPIKey("invented", provider: .anthropic) }
        #expect(!model.hasAPIKey(.anthropic))
        #expect(model.intervalMinutes == 15)
        model.intervalMinutes = 60
        #expect(defaults.integer(forKey: "refreshIntervalMinutes") == 60)
        #expect(model.clientSetup.arguments == ["mcp", "--library", library.root.path])
    }
}

@Suite struct StatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func status(_ change: (inout LibraryStatus) -> Void = { _ in }) -> LibraryStatus {
        var status = LibraryStatus(
            root: URL(filePath: "/tmp/invented"),
            documents: 3,
            folders: 1,
            pages: 9,
            lastRefresh: [:],
            lastError: [:],
            lastErrorAt: [:]
        )
        change(&status)
        return status
    }

    @Test func beforeAnyRefresh() {
        let snapshot = StatusSnapshot(usbPresent: false, pairing: .notPaired, library: status(), now: now)
        #expect(
            snapshot.lines == [
                "USB: not connected", "Cloud: not paired", "Mirror: not refreshed yet", "Pushes: none queued",
                "Recognizer: off",
            ]
        )
    }

    @Test func showsTheCloudsSuccessAndANewerError() throws {
        let library = status {
            $0.lastRefresh = [.cloud: now.addingTimeInterval(-3 * 3600), .usb: now.addingTimeInterval(-120)]
            $0.lastError = [.cloud: "HTTP 503 from the invented host\nmore detail"]
            $0.lastErrorAt = [.cloud: now.addingTimeInterval(-60)]
        }
        let configuration = try RecognizerConfiguration(provider: .mlx)
        var counts = RecognitionCounts()
        counts.pagesWithInk = 5
        counts.text = 3
        let snapshot = StatusSnapshot(
            usbPresent: true,
            pairing: .paired(service: "rePossess"),
            library: library,
            pushCounts: [.pending: 2, .unknown: 1, .sent: 4],
            recognizer: configuration,
            recognition: counts,
            now: now
        )
        #expect(
            snapshot.lines == [
                "USB: connected",
                "Cloud: last success 3 hours ago",
                "Cloud error 1 minute ago: HTTP 503 from the invented host",
                "Mirror: refreshed from USB 2 minutes ago",
                "Pushes: 2 waiting, 1 unknown",
                "Recognizer: mlx, mlx-community/Qwen3-VL-8B-Instruct-4bit; 2 pages wait",
            ]
        )
    }

    @Test func namesACloudProvidersModelAndTheKeychainSwitch() throws {
        let configuration = try RecognizerConfiguration(provider: .anthropic, model: "invented-model")
        let snapshot = StatusSnapshot(usbPresent: false, pairing: .keychainOff, recognizer: configuration, now: now)
        #expect(snapshot.recognizerLine == "Recognizer: anthropic, invented-model")
        #expect(snapshot.cloudLines == ["Cloud: not checked (this run does not use the Keychain)"])
    }

    @Test func readsALibraryWithoutReadingASecret() throws {
        let library = try temporaryLibrary("status")
        let store = FakeKeychain(["rePossess": "invented.token.value"])
        let snapshot = StatusSnapshot.read(library: library, store: store, usesKeychain: true, usbPresent: false)
        #expect(snapshot.pairing == .paired(service: "rePossess"))
        #expect(store.reads.isEmpty)
        #expect(snapshot.library?.documents == 0 && snapshot.recognizer == nil)
    }

    @Test func agesAndShortLines() {
        #expect(StatusSnapshot.age(now.addingTimeInterval(-30), now: now) == "just now")
        #expect(StatusSnapshot.age(now.addingTimeInterval(-3600), now: now) == "1 hour ago")
        #expect(StatusSnapshot.age(now.addingTimeInterval(-3 * 86400), now: now) == "3 days ago")
        #expect(StatusSnapshot.shorten(String(repeating: "x", count: 200)).count == 90)
    }
}

@Suite struct ClientSetupTests {
    let setup = ClientSetup(helperPath: "/Applications/rePossess.app/Contents/MacOS/repossess", libraryRoot: nil)

    @Test func everyClientStartsTheHelperInTheBundle() {
        #expect(
            setup.claudeCodeCommand
                == "claude mcp add --scope user repossess -- /Applications/rePossess.app/Contents/MacOS/repossess mcp"
        )
        #expect(
            setup.codexCommand == "codex mcp add repossess -- /Applications/rePossess.app/Contents/MacOS/repossess mcp"
        )
        #expect(
            setup.codexTOML == """
                [mcp_servers.repossess]
                command = "/Applications/rePossess.app/Contents/MacOS/repossess"
                args = ["mcp"]
                """
        )
        let desktop = try? JSONSerialization.jsonObject(with: Data(setup.claudeDesktopJSON.utf8)) as? [String: Any]
        let entry = (desktop?["mcpServers"] as? [String: Any])?["repossess"] as? [String: Any]
        #expect(entry?["command"] as? String == setup.helperPath && entry?["args"] as? [String] == ["mcp"])
        let code = try? JSONSerialization.jsonObject(with: Data(setup.claudeCodeJSON.utf8)) as? [String: Any]
        let codeEntry = (code?["mcpServers"] as? [String: Any])?["repossess"] as? [String: Any]
        #expect(codeEntry?["type"] as? String == "stdio")
    }

    @Test func aPathWithSpacesAndAnotherLibraryAreQuoted() {
        let other = ClientSetup(
            helperPath: "/Users/invented/My Apps/rePossess.app/Contents/MacOS/repossess",
            libraryRoot: URL(filePath: "/tmp/it's a library", directoryHint: .isDirectory)
        )
        #expect(other.arguments == ["mcp", "--library", "/tmp/it's a library"])
        #expect(
            other.claudeCodeCommand
                == "claude mcp add --scope user repossess -- '/Users/invented/My Apps/rePossess.app/Contents/MacOS/repossess' mcp --library '/tmp/it'\\''s a library'"
        )
        #expect(ClientSetup.tomlString("a \"b\" \\c") == "\"a \\\"b\\\" \\\\c\"")
    }

    @Test func theHelperIsBesideTheAppsExecutable() {
        let helper = ClientSetup.bundledHelper(
            executable: URL(filePath: "/Applications/rePossess.app/Contents/MacOS/RePossessApp")
        )
        #expect(helper?.path == "/Applications/rePossess.app/Contents/MacOS/repossess")
    }
}

@Suite struct ClaudeDesktopConfigTests {
    let setup = ClientSetup(helperPath: "/Applications/rePossess.app/Contents/MacOS/repossess", libraryRoot: nil)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "repossess-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func createsAMissingFileOnlyAfterTheOwnerConfirms() throws {
        let url = try folder().appending(path: "Claude/claude_desktop_config.json")
        let config = ClaudeDesktopConfig(url: url)
        let change = try config.prepare(setup)
        #expect(change.before == nil && !change.replacesServer && !change.unchanged)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try config.write(change, now: now) == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == change.after)
    }

    @Test func keepsOtherServersAndSettingsAndBacksUp() throws {
        let url = try folder().appending(path: "claude_desktop_config.json")
        let original = #"{"globalShortcut": "", "mcpServers": {"invented": {"command": "/usr/bin/true"}}}"#
        try original.write(to: url, atomically: true, encoding: .utf8)
        let config = ClaudeDesktopConfig(url: url)
        let change = try config.prepare(setup)
        #expect(change.before == original)
        let backup = try #require(try config.write(change, now: now))
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect(backup.lastPathComponent.hasPrefix("claude_desktop_config.json.repossess-backup-"))
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let servers = written["mcpServers"] as! [String: Any]
        #expect(Set(servers.keys) == ["invented", "repossess"] && written["globalShortcut"] as? String == "")
        #expect(try config.prepare(setup).unchanged)
    }

    @Test func refusesAFileThatIsNotAnObjectOrThatChangedAfterThePreview() throws {
        let url = try folder().appending(path: "claude_desktop_config.json")
        try "[1, 2]".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: ClaudeDesktopConfig.ConfigError.self) { try ClaudeDesktopConfig(url: url).prepare(setup) }
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        let config = ClaudeDesktopConfig(url: url)
        let change = try config.prepare(setup)
        try #"{"edited": true}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: ClaudeDesktopConfig.ConfigError.self) { try config.write(change, now: now) }
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"edited": true}"#)
    }
}

@Suite struct BackgroundRecognitionTests {
    @Test func runsOnlyWhenARecognizerOnTheMacOrAProviderHasPagesWaiting() throws {
        let mlx = try RecognizerConfiguration(provider: .mlx)
        #expect(BackgroundRecognition.skipReason(configuration: nil, waiting: 3, modelPresent: true) == .off)
        #expect(BackgroundRecognition.skipReason(configuration: mlx, waiting: 0, modelPresent: true) == .nothingWaits)
        #expect(BackgroundRecognition.skipReason(configuration: mlx, waiting: 3, modelPresent: false) == .modelMissing)
        #expect(BackgroundRecognition.skipReason(configuration: mlx, waiting: 3, modelPresent: true) == nil)
        let client = try RecognizerConfiguration(provider: .client)
        #expect(
            BackgroundRecognition.skipReason(configuration: client, waiting: 3, modelPresent: true) == .clientProvider
        )
        let cloud = try RecognizerConfiguration(provider: .anthropic, model: "invented-model")
        #expect(BackgroundRecognition.skipReason(configuration: cloud, waiting: 3, modelPresent: false) == nil)
    }

    @Test func oneRunAtATime() async throws {
        let gate = GatedRefresh()
        let recognition = BackgroundRecognition(launch: {
            _ = await gate.refresh(.usb)
            return (0, "Recognizing 2 pages\nRecognized 2 pages in 5 s: 2 with text, 0 without words, 0 refused.")
        })
        let mlx = try RecognizerConfiguration(provider: .mlx)
        let first = Task { await recognition.run(configuration: mlx, waiting: 2, modelPresent: true) }
        while gate.waiting == 0 { await Task.yield() }
        let second = await recognition.run(configuration: mlx, waiting: 2, modelPresent: true)
        #expect(second == .failure(.init(.alreadyRunning)))
        gate.open()
        guard case .success(let run) = await first.value else {
            Issue.record("no run")
            return
        }
        #expect(run.exitStatus == 0 && run.lastLine.hasPrefix("Recognized 2 pages"))
        let missing = BackgroundRecognition(launch: nil)
        #expect(
            await missing.run(configuration: mlx, waiting: 2, modelPresent: true) == .failure(.init(.helperMissing))
        )
    }

    @Test func theProcessGetsTheRecognizeCommandAndTheLibrary() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "repossess-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let helper = folder.appending(path: "repossess")
        try "#!/bin/sh\necho \"invented progress\" >&2\necho \"$@\"\nexit 3\n".write(
            to: helper,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let launch = BackgroundRecognition.processLaunch(helper: helper, libraryRoot: URL(filePath: "/tmp/invented"))
        let (status, output) = try await launch()
        #expect(status == 3)
        #expect(output.contains("invented progress") && output.contains("recognize --library /tmp/invented"))
    }
}
