import Foundation
import Testing

@testable import RePossessAppCore
@testable import RePossessCloud
@testable import RePossessLibrary
@testable import RePossessRecognize

/// The preferences suites that one test creates.
///
/// Each suite name is unique, so tests never share state,
/// and `deinit` removes the suites when the test's suite instance goes away,
/// so a test run leaves no files in `~/Library/Preferences`.
final class TestPreferences {
    private var names: [String] = []

    func make() -> UserDefaults {
        let name = "repossess-test-\(UUID().uuidString)"
        names.append(name)
        return UserDefaults(suiteName: name)!
    }

    deinit {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences", directoryHint: .isDirectory)
        for name in names {
            // Removing the domain leaves an empty file, so delete the file too.
            UserDefaults.standard.removePersistentDomain(forName: name)
            CFPreferencesAppSynchronize(name as CFString)
            try? FileManager.default.removeItem(at: folder.appending(path: "\(name).plist"))
        }
    }
}

@Suite struct OptionsTests {
    let preferences = TestPreferences()

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
        #expect(options.settingsAtLaunch == nil)
        #expect(AppOptions(arguments: ["--settings", "clients"], environment: [:]).settingsAtLaunch == .clients)
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
        let defaults = preferences.make()
        let model = AppModel(
            options: AppOptions(libraryRoot: library.root, isDefaultLibrary: false, usesKeychain: false),
            defaults: defaults
        )
        #expect(model.snapshot.pairing == .keychainOff)
        let paired = await model.pair(code: "abcd1234")
        #expect(!paired.succeeded && paired.summary == NoKeychain.message && paired.keepsCode)
        let unpaired = model.unpair()
        #expect(!unpaired.succeeded && unpaired.summary == NoKeychain.message)
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

    @Test func timesUntilTheNextRefreshInWholeMinutes() {
        #expect(StatusSnapshot.until(now.addingTimeInterval(20), now: now) == "in less than a minute")
        #expect(StatusSnapshot.until(now.addingTimeInterval(-5), now: now) == "in less than a minute")
        #expect(StatusSnapshot.until(now.addingTimeInterval(65), now: now) == "in about 1 minute")
        #expect(StatusSnapshot.until(now.addingTimeInterval(12 * 60 + 10), now: now) == "in about 12 minutes")
        #expect(StatusSnapshot.until(now.addingTimeInterval(59 * 60 + 50), now: now) == "in about 1 hour")
        #expect(StatusSnapshot.until(now.addingTimeInterval(6 * 3600), now: now) == "in about 6 hours")
        #expect(StatusSnapshot.until(now.addingTimeInterval(86_400), now: now) == "in about 1 day")
    }

    @Test func theLastAndNextRefreshReplaceTheCountdown() throws {
        let library = try temporaryLibrary("status")
        try library.recordRefreshSuccess(.usb, at: now.addingTimeInterval(-180))
        var snapshot = StatusSnapshot(usbPresent: false, pairing: .notPaired, library: try library.status(), now: now)
        #expect(snapshot.refreshTimes() == "Refreshed from USB 3 minutes ago")
        snapshot.nextRefresh = now.addingTimeInterval(12 * 60)
        #expect(snapshot.refreshTimes() == "Refreshed from USB 3 minutes ago · next in about 12 minutes")
        #expect(snapshot.mirrorLine == "Mirror: refreshed from USB 3 minutes ago · next in about 12 minutes")
        let empty = StatusSnapshot(usbPresent: false, pairing: .notPaired, nextRefresh: now, now: now)
        #expect(empty.refreshTimes() == "Not refreshed yet · next in less than a minute")
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

    @Test func onlyAnAppInApplicationsHasALastingPath() {
        let home = URL(filePath: "/Users/invented", directoryHint: .isDirectory)
        #expect(ClientSetup.isInApplications(URL(filePath: "/Applications/rePossess.app"), home: home))
        #expect(ClientSetup.isInApplications(URL(filePath: "/Users/invented/Applications/rePossess.app"), home: home))
        #expect(!ClientSetup.isInApplications(URL(filePath: "/tmp/build/rePossess.app"), home: home))
        #expect(!ClientSetup.isInApplications(URL(filePath: "/Applications Old/rePossess.app"), home: home))
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

@Suite struct ConsentTests {
    let preferences = TestPreferences()

    func configuration(
        _ provider: RecognizerProvider,
        model: String? = "invented-model",
        address: String? = nil
    ) throws -> RecognizerConfiguration {
        try RecognizerConfiguration(
            provider: provider,
            model: provider.needsModel ? model : nil,
            baseURL: address.flatMap(URL.init(string:))
        )
    }

    @Test func aConsentCoversOneProviderAndHostOnly() throws {
        let anthropic = try configuration(.anthropic)
        var consent = PageImageConsent()
        #expect(!consent.allows(anthropic))
        consent.grant(anthropic)
        #expect(consent.allows(anthropic))
        #expect(consent.destination?.address == "api.anthropic.com")
        #expect(consent.destination?.label == "api.anthropic.com (Anthropic)")
        // Another model at the same destination keeps the consent.
        #expect(consent.allows(try configuration(.anthropic, model: "another-invented-model")))
        // Another remote provider does not.
        #expect(!consent.allows(try configuration(.openai)))
        #expect(!consent.allows(try configuration(.gemini)))
        #expect(!consent.allows(try configuration(.client)))
    }

    @Test func anotherAddressNeedsANewConsent() throws {
        let openai = try configuration(.openai)
        var consent = PageImageConsent()
        consent.grant(openai)
        #expect(consent.allows(openai))
        #expect(!consent.allows(try configuration(.openai, address: "https://llm.invented.example/v1/")))
        #expect(!consent.allows(try configuration(.openai, address: "https://api.openai.com:8443/v1/")))
        let remoteOllama = try configuration(.ollama, address: "https://ollama.invented.example")
        #expect(!consent.allows(remoteOllama))
        consent.grant(remoteOllama)
        #expect(consent.allows(remoteOllama) && !consent.allows(openai))
    }

    @Test func recognitionOnThisMacNeedsNoConsent() throws {
        let consent = PageImageConsent()
        #expect(consent.allows(try configuration(.mlx)))
        #expect(consent.allows(try configuration(.foundationModels)))
        #expect(consent.allows(try configuration(.ollama)))
        #expect(consent.allows(try configuration(.ollama, address: "http://localhost:11434")))
        #expect(PageImageConsent(saved: try configuration(.mlx)).destination == nil)
    }

    @Test func changingTheDraftAndBackStillNeedsANewConsent() throws {
        let anthropic = try configuration(.anthropic)
        let gemini = try configuration(.gemini)
        var consent = PageImageConsent(saved: anthropic)
        #expect(consent.allows(anthropic))
        consent.draftChanged(to: PageImageDestination(anthropic))
        #expect(consent.allows(anthropic))
        consent.draftChanged(to: PageImageDestination(gemini))
        #expect(!consent.allows(gemini))
        consent.draftChanged(to: PageImageDestination(anthropic))
        #expect(!consent.allows(anthropic))
        consent.grant(anthropic)
        consent.draftChanged(to: nil)
        #expect(consent.destination == nil)
    }

    @MainActor @Test func theModelChecksTheConsentAgainBeforeItSaves() throws {
        let library = try temporaryLibrary("consent")
        let model = AppModel(
            options: AppOptions(libraryRoot: library.root, isDefaultLibrary: false, usesKeychain: false),
            defaults: preferences.make()
        )
        let anthropic = try configuration(.anthropic)
        let openai = try configuration(.openai)
        let custom = try configuration(.openai, address: "https://llm.invented.example/v1/")

        var consent = PageImageConsent()
        #expect(throws: ConsentError.self) { try model.setRecognizer(anthropic, consent: consent) }
        #expect(model.recognizer == nil)

        consent.grant(anthropic)
        try model.setRecognizer(anthropic, consent: consent)
        #expect(model.recognizer?.provider == .anthropic)

        // The consent for Anthropic does not cover OpenAI, nor OpenAI's consent another address.
        #expect(throws: ConsentError.self) { try model.setRecognizer(openai, consent: consent) }
        #expect(model.recognizer?.provider == .anthropic)
        consent.grant(openai)
        #expect(throws: ConsentError.self) { try model.setRecognizer(custom, consent: consent) }
        #expect(model.recognizer?.provider == .anthropic)
        consent.grant(custom)
        try model.setRecognizer(custom, consent: consent)
        #expect(model.recognizer?.baseURL?.host() == "llm.invented.example")

        // A recognizer on this Mac needs no consent.
        try model.setRecognizer(try configuration(.mlx), consent: PageImageConsent())
        #expect(model.recognizer?.provider == .mlx)
        let error = ConsentError(destination: try #require(PageImageDestination(anthropic)))
        #expect(error.description.contains("api.anthropic.com"))
    }
}

@Suite struct RecognizerSetupTests {
    let preferences = TestPreferences()

    @Test func theDraftGivesGuidanceForEachField() throws {
        var draft = RecognizerDraft(provider: .anthropic)
        #expect(draft.showsModel && !draft.showsAddress)
        #expect(draft.modelProblem == "Enter the provider's name for a model that reads images.")
        #expect(draft.configuration == nil)
        draft.model = "invented-model"
        #expect(draft.modelProblem == nil && draft.configuration?.provider == .anthropic)

        var openai = RecognizerDraft(provider: .openai, model: "invented-model")
        #expect(openai.showsAddress && openai.defaultAddress == "https://api.openai.com/v1/")
        #expect(openai.addressProblem == nil && openai.configuration?.baseURL == nil)
        openai.address = "llm.invented.example"
        #expect(openai.addressProblem == "Enter a full address that starts with https://.")
        openai.address = "http://llm.invented.example/v1/"
        #expect(openai.addressProblem?.hasPrefix("Use an https address") == true && openai.configuration == nil)
        openai.address = "https://llm.invented.example/v1/"
        #expect(openai.addressProblem == nil)
        #expect(openai.configuration?.receivingHost == "llm.invented.example")

        let ollama = RecognizerDraft(provider: .ollama, model: "invented-model", address: "http://localhost:11434")
        #expect(ollama.addressProblem == nil && ollama.configuration?.sendsPageImages == false)
        // No field mentions a command-line option.
        for provider in RecognizerProvider.allCases {
            let empty = RecognizerDraft(provider: provider, address: "ftp://invented")
            for text in [empty.modelProblem, empty.addressProblem].compactMap({ $0 }) {
                #expect(!text.contains("--"))
            }
        }
    }

    @Test func aDraftFromASavedConfigurationKeepsItsValues() throws {
        let saved = try RecognizerConfiguration(
            provider: .openai,
            model: "invented-model",
            baseURL: URL(string: "https://llm.invented.example/v1/")
        )
        let draft = RecognizerDraft(saved)
        #expect(draft.provider == .openai && draft.model == "invented-model")
        #expect(draft.address == "https://llm.invented.example/v1/")
        #expect(PageImageDestination(try #require(draft.configuration)) == PageImageDestination(saved))
        let local = try RecognizerConfiguration(provider: .mlx, modelPath: "/tmp/invented-model")
        #expect(RecognizerDraft(local).configuration?.modelPath == "/tmp/invented-model")
    }

    @Test func readinessSaysWhatTheRecognizerNeeds() throws {
        let mlx = try RecognizerConfiguration(provider: .mlx)
        let anthropic = try RecognizerConfiguration(provider: .anthropic, model: "invented-model")
        let client = try RecognizerConfiguration(provider: .client)
        #expect(RecognizerReadiness.of(nil, modelPresent: false, apiKeySource: nil) == .off)
        #expect(RecognizerReadiness.of(mlx, modelPresent: false, apiKeySource: nil) == .modelRequired)
        #expect(RecognizerReadiness.of(mlx, modelPresent: true, apiKeySource: nil) == .ready)
        let ownModel = try RecognizerConfiguration(provider: .mlx, modelPath: "/tmp/invented-model")
        #expect(RecognizerReadiness.of(ownModel, modelPresent: false, apiKeySource: nil) == .ready)
        #expect(RecognizerReadiness.of(anthropic, modelPresent: false, apiKeySource: nil) == .apiKeyRequired)
        #expect(
            RecognizerReadiness.of(anthropic, modelPresent: false, apiKeySource: "the login keychain") == .ready
        )
        #expect(RecognizerReadiness.of(client, modelPresent: false, apiKeySource: nil) == .clientOnly)
        let broken = RecognizerReadiness.of(nil, error: "invented error", modelPresent: true, apiKeySource: nil)
        #expect(broken == .unreadable("invented error") && broken.needsAction)
        #expect(RecognizerReadiness.modelRequired.title == "Model Required")
        #expect(!RecognizerReadiness.ready.needsAction && RecognizerReadiness.apiKeyRequired.needsAction)
    }

    @MainActor @Test func offTakesEffectAtOnceAndTheReadinessFollowsTheSavedConfiguration() throws {
        let library = try temporaryLibrary("readiness")
        let model = AppModel(
            options: AppOptions(libraryRoot: library.root, isDefaultLibrary: false, usesKeychain: false),
            defaults: preferences.make()
        )
        #expect(model.recognizerReadiness == .off)
        let anthropic = try RecognizerConfiguration(provider: .anthropic, model: "invented-model")
        var consent = PageImageConsent()
        consent.grant(anthropic)
        try model.setRecognizer(anthropic, consent: consent)
        // Without the Keychain, a key can come only from the environment.
        let fromEnvironment = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"].map { !$0.isEmpty } ?? false
        #expect(model.recognizerReadiness == (fromEnvironment ? .ready : .apiKeyRequired))
        try model.turnRecognitionOff()
        #expect(model.recognizer == nil && model.recognizerReadiness == .off)
        #expect(try RecognizerConfiguration.load(from: library.root) == nil)
        #expect(try library.activeRecognitionKey() == nil)
    }

    @Test func downloadProgressInWords() {
        let state = ModelDownloadState.stopped(done: 1_200_000_000, total: 5_800_000_000)
        #expect(state.progressText == "1.2 GB of 5.8 GB" && !state.isRunning)
        #expect(ModelDownloadState.running(done: 0, total: 10).isRunning)
        #expect(ModelDownloadState.finished.bytes == nil)
    }
}

@Suite struct MenuStatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func library(_ change: (inout LibraryStatus) -> Void = { _ in }) -> LibraryStatus {
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

    func menu(
        _ snapshot: StatusSnapshot,
        refreshing: Bool = false,
        outcome: RefreshOutcome? = nil,
        recognizing: Bool = false,
        failure: String? = nil,
        readiness: RecognizerReadiness = .off
    ) -> MenuStatus {
        MenuStatus(
            snapshot: snapshot,
            refreshing: refreshing,
            lastOutcome: outcome,
            recognizing: recognizing,
            recognitionFailure: failure,
            readiness: readiness
        )
    }

    @Test func aQuietMenuHasThreeShortRows() {
        let snapshot = StatusSnapshot(
            usbPresent: false,
            pairing: .paired(service: "rePossess"),
            library: library { $0.lastRefresh = [.cloud: now.addingTimeInterval(-180)] },
            nextRefresh: now.addingTimeInterval(12 * 60),
            now: now
        )
        let status = menu(snapshot)
        #expect(status.headline == "Library Updated 3 Minutes Ago")
        #expect(status.nextRefresh == "Next Refresh in About 12 Minutes")
        #expect(status.connection == "Tablet Not on USB · Cloud Paired")
        #expect(status.problems.isEmpty && status.queue.isEmpty && status.handwriting == nil)
        // No row names a Keychain item or a model repository.
        for row in [status.headline, status.nextRefresh ?? "", status.connection] {
            #expect(!row.contains("rePossess spike") && !row.contains("mlx-community"))
        }
    }

    @Test func oneFailureAppearsOnceAndOpensItsPane() {
        let snapshot = StatusSnapshot(
            usbPresent: false,
            pairing: .paired(service: "rePossess"),
            library: library {
                $0.lastRefresh = [.cloud: now.addingTimeInterval(-3 * 3600)]
                $0.lastError = [.cloud: "HTTP 503 from the invented host, with a long explanation that goes on"]
                $0.lastErrorAt = [.cloud: now.addingTimeInterval(-60)]
            },
            now: now
        )
        let failed = RefreshOutcome(
            trigger: .schedule,
            result: .failed("HTTP 503 from the invented host, with a long explanation that goes on"),
            started: now,
            ended: now
        )
        let status = menu(snapshot, outcome: failed)
        #expect(status.problems == [.init(title: "Cloud Refresh Failed 1 Minute Ago", pane: .cloud)])
        // Without the library's record, the outcome is the one problem.
        let unrecorded = StatusSnapshot(usbPresent: false, pairing: .notPaired, library: library(), now: now)
        #expect(menu(unrecorded, outcome: failed).problems == [.init(title: "Refresh Failed", pane: .general)])
        #expect(menu(unrecorded, refreshing: true, outcome: failed).problems.isEmpty)
        #expect(menu(unrecorded, refreshing: true).headline == "Refreshing…")
        let usb = StatusSnapshot(
            usbPresent: true,
            pairing: .keychainOff,
            library: library { $0.lastError = [.usb: "invented USB error"] },
            now: now
        )
        #expect(menu(usb).problems == [.init(title: "USB Refresh Failed", pane: .general)])
        #expect(menu(usb).connection == "Tablet on USB · Cloud Not Checked")
    }

    @Test func theQueueAndHandwritingShowOnlyWhenTheyNeedAttention() throws {
        var counts = RecognitionCounts()
        counts.pagesWithInk = 5
        counts.text = 3
        let snapshot = StatusSnapshot(
            usbPresent: false,
            pairing: .notPaired,
            library: library(),
            pushCounts: [.pending: 2, .unknown: 1, .sent: 4],
            recognizer: try RecognizerConfiguration(provider: .mlx),
            recognition: counts,
            now: now
        )
        #expect(menu(snapshot).queue == ["2 Documents Waiting to Send", "1 Delivery Unconfirmed"])
        #expect(menu(snapshot, readiness: .ready).handwriting?.title == "Handwriting: 2 Pages Waiting")
        let required = menu(snapshot, readiness: .modelRequired).handwriting
        #expect(required?.title == "Handwriting: Model Required" && required?.opensPane == true)
        #expect(menu(snapshot, recognizing: true, readiness: .ready).handwriting?.title == "Recognizing Handwriting…")
        let failed = menu(snapshot, failure: "invented failure", readiness: .ready).handwriting
        #expect(failed?.title == "Handwriting Recognition Failed" && failed?.opensPane == true)
        #expect(menu(snapshot, readiness: .off).handwriting == nil)
    }

    @Test func titleCaseLeavesShortWordsAndAcronyms() {
        #expect(MenuStatus.titleCased("library updated just now") == "Library Updated Just Now")
        #expect(MenuStatus.titleCased("next refresh in about 1 hour") == "Next Refresh in About 1 Hour")
        #expect(MenuStatus.titleCased("USB refresh failed") == "USB Refresh Failed")
    }

    @Test func theSettingsSayTheLastAndNextRefresh() {
        let snapshot = StatusSnapshot(
            usbPresent: false,
            pairing: .notPaired,
            library: library { $0.lastRefresh = [.usb: now.addingTimeInterval(-180)] },
            nextRefresh: now.addingTimeInterval(12 * 60),
            now: now
        )
        #expect(snapshot.lastRefreshText == "From USB 3 minutes ago")
        #expect(snapshot.nextRefreshText == "In about 12 minutes")
        let unscheduled = StatusSnapshot(usbPresent: false, pairing: .notPaired, now: now)
        #expect(unscheduled.lastRefreshText == "Not yet")
        #expect(unscheduled.nextRefreshText == "When the tablet connects or on request")
    }
}

@Suite struct SetupTests {
    let preferences = TestPreferences()

    func defaults() -> UserDefaults {
        preferences.make()
    }

    @Test func theSetupOpensOnceAndOnlyWithoutAWayToTheTablet() {
        let fresh = defaults()
        #expect(SetupProgress.atLaunch(defaults: fresh, tabletReachable: false, requestedPane: nil))
        #expect(!SetupProgress.atLaunch(defaults: fresh, tabletReachable: false, requestedPane: nil))
        #expect(!fresh.bool(forKey: SetupProgress.finishedKey))

        let existing = defaults()
        #expect(!SetupProgress.atLaunch(defaults: existing, tabletReachable: true, requestedPane: nil))
        #expect(existing.bool(forKey: SetupProgress.finishedKey))

        let requested = defaults()
        #expect(!SetupProgress.atLaunch(defaults: requested, tabletReachable: false, requestedPane: .cloud))
        #expect(SetupProgress.atLaunch(defaults: requested, tabletReachable: false, requestedPane: nil))

        let later = defaults()
        later.set(true, forKey: SetupProgress.finishedKey)
        #expect(!SetupProgress.atLaunch(defaults: later, tabletReachable: false, requestedPane: nil))
    }

    @Test func aWrongCodeKeepsTheCodeAndSaysWhatToDo() {
        let refused = PairingOutcome.pairingFailed(CloudError.registrationRefused(status: 400, message: "invented"))
        #expect(!refused.succeeded && refused.keepsCode)
        #expect(refused.summary.hasPrefix("reMarkable did not accept this code."))
        #expect(refused.details?.contains("HTTP 400") == true)
        let offline = PairingOutcome.pairingFailed(URLError(.notConnectedToInternet))
        #expect(offline.summary.hasPrefix("rePossess could not reach reMarkable's cloud"))
        #expect(PairingOutcome.pairingFailed(CloudError.invalidCode).summary.contains("eight letters or digits"))
    }

    @Test func theSummariesNeverNameAKeychainItem() {
        let paired = PairingOutcome.paired(olderService: "rePossess spike 6")
        #expect(paired.succeeded && !paired.keepsCode)
        #expect(!paired.summary.contains("spike") && paired.details?.contains("rePossess spike 6") == true)
        let unpaired = PairingOutcome.unpaired(deleted: ["rePossess", "rePossess spike 6"])
        #expect(!unpaired.summary.contains("\"") && unpaired.summary.contains("my.remarkable.com"))
        #expect(unpaired.details?.contains("rePossess spike 6") == true)
    }
}
