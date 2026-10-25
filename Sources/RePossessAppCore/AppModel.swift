import Foundation
import Network
import Observation
import RePossessCloud
import RePossessLibrary
import RePossessMCP
import RePossessRecognize
import RePossessUSB
import ServiceManagement

/// The app's state: the status that the menu shows, the background refreshes, and the settings' actions.
@MainActor
@Observable
public final class AppModel {
    public let options: AppOptions
    /// The library, or `nil` when it could not be opened; ``libraryError`` says why.
    public let library: Library?
    public let libraryError: String?
    let store: any DeviceTokenStore
    let session: CloudSession
    let coordinator: RefreshCoordinator
    let recognition: BackgroundRecognition
    let helper: URL?

    public private(set) var snapshot: StatusSnapshot
    public private(set) var refreshing = false
    public private(set) var lastOutcome: RefreshOutcome?
    public private(set) var recognizing = false
    public private(set) var lastRecognition: String?

    /// The refresh interval; the settings change it, and `UserDefaults` keeps it.
    public var intervalMinutes: Int {
        didSet {
            defaults.set(intervalMinutes, forKey: Self.intervalKey)
            Log.settings.info("Refresh interval: \(self.intervalMinutes) minutes")
        }
    }

    private let defaults: UserDefaults
    private static let intervalKey = "refreshIntervalMinutes"
    private var usb = USBAppearance()
    private var lastAttempt: Date?
    private var failures = 0
    private var loop: Task<Void, Never>?
    /// The tablet's USB network appeared while another refresh ran; refresh over USB when it ends.
    private var usbWaiting = false
    private var download: Task<Void, Never>?

    /// The model download's progress from 0 to 1, while it runs or after it stops.
    public private(set) var downloadFraction: Double?
    /// The model download's last message.
    public private(set) var downloadMessage: String?
    /// Whether the model download is running.
    public var downloading: Bool { download != nil }
    private var monitor: NWPathMonitor?

    public init(options: AppOptions = AppOptions(), defaults: UserDefaults = .standard) {
        self.options = options
        self.defaults = defaults
        let store = options.tokenStore
        self.store = store
        let opened: Library?
        do {
            opened = try Library(root: options.libraryRoot)
            libraryError = nil
        } catch {
            opened = nil
            libraryError = "The library at \(options.libraryRoot.path) could not be opened: \(error)"
        }
        library = opened
        intervalMinutes = (defaults.object(forKey: Self.intervalKey) as? Int) ?? RefreshSchedule.defaultMinutes
        // The owner may be away when a scheduled refresh reads the device token,
        // so a Keychain dialog does not hold the library's lock for long.
        let session = CloudSession(
            deviceToken: { try DeviceTokenKeychain.read(from: store).token },
            tokenTimeout: .seconds(60)
        )
        self.session = session
        coordinator = RefreshCoordinator(
            paths: {
                RefreshPaths(
                    usbPresent: USBNetwork.isPresent(),
                    paired: options.usesKeychain && DeviceTokenKeychain.pairedService(in: store) != nil
                )
            },
            refresh: Self.refresh(library: opened, session: session, options: options, store: store)
        )
        let helper = ClientSetup.bundledHelper().flatMap {
            FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil
        }
        self.helper = helper
        recognition = BackgroundRecognition(
            launch: helper.map { BackgroundRecognition.processLaunch(helper: $0, libraryRoot: options.libraryRoot) }
        )
        snapshot = StatusSnapshot(usbPresent: USBNetwork.isPresent(), pairing: .notPaired)
        updateSnapshot()
    }

    nonisolated private static func refresh(
        library: Library?,
        session: CloudSession,
        options: AppOptions,
        store: any DeviceTokenStore
    ) -> RefreshCoordinator.Refresh {
        guard let library else { return { _ in throw CocoaError(.fileReadUnknown) } }
        return RefreshCoordinator.libraryRefresh(
            library: library,
            session: session,
            paired: { options.usesKeychain && DeviceTokenKeychain.pairedService(in: store) != nil }
        )
    }

    // MARK: Status

    /// Reads the status again from the library.
    public func updateSnapshot() {
        guard let library else {
            snapshot = StatusSnapshot(
                usbPresent: USBNetwork.isPresent(),
                pairing: options.usesKeychain ? .notPaired : .keychainOff,
                libraryError: libraryError
            )
            return
        }
        snapshot = StatusSnapshot.read(
            library: library,
            store: store,
            usesKeychain: options.usesKeychain,
            usbPresent: USBNetwork.isPresent()
        )
    }

    /// The schedule from the settings.
    public var schedule: RefreshSchedule { RefreshSchedule(intervalMinutes: intervalMinutes) }

    /// When the next scheduled refresh is due, counting refreshes by `repossess` in other processes.
    public var nextRefresh: Date? {
        let latest = [lastAttempt, snapshot.library?.latestRefresh?.date].compactMap { $0 }.max()
        return schedule.nextDate(after: latest, failures: failures, now: Date())
    }

    // MARK: Background work

    /// Starts watching the network for the tablet and the schedule's clock.
    public func start() {
        guard loop == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.tick(scheduled: false) }
        }
        monitor.start(queue: DispatchQueue(label: "co.dododo.repossess.network"))
        self.monitor = monitor
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick(scheduled: true)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Stops the background work.
    public func stop() {
        loop?.cancel()
        loop = nil
        monitor?.cancel()
        monitor = nil
    }

    /// Checks for the tablet's USB network and the schedule, and starts a refresh when one is due.
    func tick(scheduled: Bool) {
        if usb.update(present: USBNetwork.isPresent()) {
            if refreshing { usbWaiting = true } else { refresh(.usbAppeared) }
            return
        }
        updateSnapshot()
        guard scheduled, !refreshing, let next = nextRefresh, next <= Date() else { return }
        refresh(.schedule)
    }

    /// Refreshes now, unless a refresh is running.
    public func refresh(_ trigger: RefreshTrigger = .manual) {
        guard library != nil, !refreshing else { return }
        refreshing = true
        if trigger == .manual { failures = 0 }
        Task {
            let outcome = await coordinator.run(trigger)
            finish(outcome)
        }
    }

    private func finish(_ outcome: RefreshOutcome) {
        refreshing = false
        if outcome.result != .alreadyRunning {
            lastOutcome = outcome
            lastAttempt = outcome.ended
            failures = outcome.isFailure ? failures + 1 : 0
        }
        Log.refresh.info("\(outcome.trigger.rawValue, privacy: .public): \(outcome.summary)")
        updateSnapshot()
        if usbWaiting {
            usbWaiting = false
            if snapshot.usbPresent {
                refresh(.usbAppeared)
                return
            }
        }
        if outcome.mayHaveChangedTheMirror { recognizeInBackground() }
    }

    /// Recognizes new handwriting in the helper process, when a recognizer is configured and pages wait.
    public func recognizeInBackground() {
        guard let library, !recognizing else { return }
        let configuration = try? RecognizerConfiguration.load(from: library.root)
        let waiting = configuration.flatMap { try? library.recognitionCounts(key: $0.key).waiting } ?? 0
        let modelPresent = ModelStore(libraryRoot: library.root).locate() != nil
        guard
            BackgroundRecognition.skipReason(configuration: configuration, waiting: waiting, modelPresent: modelPresent)
                == nil
        else { return }
        recognizing = true
        Task {
            let result = await recognition.run(
                configuration: configuration,
                waiting: waiting,
                modelPresent: modelPresent
            )
            recognizing = false
            switch result {
            case .success(let run):
                lastRecognition =
                    run.exitStatus == 0
                    ? run.lastLine
                    : "Recognition stopped (\(run.exitStatus)): \(StatusSnapshot.shorten(run.lastLine))"
            case .failure(let skip):
                lastRecognition = skip.skip == .helperMissing ? "The repossess helper is not beside the app." : nil
            }
            updateSnapshot()
        }
    }

    // MARK: Pairing

    /// Pairs with a one-time code. Only the owner starts it, from the settings.
    public func pair(code: String) async -> String {
        guard options.usesKeychain else { return NoKeychain.message }
        do {
            let result = try await Pairing(store: store).pair(code: code)
            updateSnapshot()
            var message = "Paired as a desktop-macos device. The device token is in the login keychain."
            if let older = result.olderService {
                message += " The older item \"\(older)\" is still in the login keychain; rePossess no longer reads it."
            }
            return message
        } catch {
            return "Pairing failed: \(error)"
        }
    }

    /// Deletes the device token items. Only the owner starts it, from the settings.
    public func unpair() -> String {
        guard options.usesKeychain else { return NoKeychain.message }
        do {
            let deleted = try Pairing(store: store).unpair()
            updateSnapshot()
            return Pairing.unpairMessage(deleted: deleted)
        } catch {
            return "Unpairing failed: \(error)"
        }
    }

    // MARK: Recognizer

    /// The configured recognizer, or `nil` when recognition is off.
    public var recognizer: RecognizerConfiguration? { snapshot.recognizer }

    /// Saves a recognizer, as `repossess recognizer set` does.
    public func setRecognizer(_ configuration: RecognizerConfiguration) throws {
        guard let library else { throw CocoaError(.fileWriteUnknown) }
        try configuration.save(to: library.root)
        try library.setActiveRecognitionKey(configuration.key)
        updateSnapshot()
    }

    /// Turns recognition off, as `repossess recognizer off` does; the cache stays.
    public func turnRecognitionOff() throws {
        guard let library else { return }
        try RecognizerConfiguration.remove(from: library.root)
        try library.setActiveRecognitionKey(nil)
        updateSnapshot()
    }

    /// Keeps an API key in the login keychain, as `repossess recognizer key` does.
    public func saveAPIKey(_ key: String, provider: RecognizerProvider) throws {
        guard options.usesKeychain else { throw NoKeychainError() }
        let store = SystemAPIKeychain()
        _ = try? store.delete(provider: provider.rawValue)
        try store.save(key, provider: provider.rawValue)
    }

    /// Whether an API key for a provider is in the login keychain, without reading it.
    public func hasAPIKey(_ provider: RecognizerProvider) -> Bool {
        options.usesKeychain && SystemAPIKeychain().exists(provider: provider.rawValue)
    }

    /// The pinned model's store in this library.
    public var modelStore: ModelStore { ModelStore(libraryRoot: options.libraryRoot) }

    /// Downloads the pinned model from Hugging Face and checks its hashes.
    /// Only the owner's click in the settings starts it (Mattt, 2026-10-25).
    public func startModelDownload() {
        guard download == nil else { return }
        let store = modelStore
        downloadFraction = 0
        downloadMessage = "Starting the download of \(store.model.repository)."
        download = Task {
            do {
                let folder = try await store.download(
                    progress: { line in Task { @MainActor in self.downloadMessage = line } },
                    bytes: { done, total in
                        Task { @MainActor in self.downloadFraction = Double(done) / Double(max(total, 1)) }
                    }
                )
                downloadFraction = 1
                downloadMessage = "The model is on this Mac, and every file matches its SHA-256: \(folder.path)"
            } catch is CancellationError {
                downloadMessage = "The download stopped. Start it again to continue where it stopped."
            } catch {
                downloadMessage = "\(error)"
            }
            download = nil
        }
    }

    /// Stops the model download; the files that were checked stay, and a partial file continues next time.
    public func cancelModelDownload() {
        download?.cancel()
    }

    // MARK: Launch at login

    /// Whether the app opens at login.
    public var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item. Only the owner starts it, from the settings.
    public func setOpensAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    // MARK: Clients

    /// The MCP configuration for the helper inside this app.
    public var clientSetup: ClientSetup {
        ClientSetup(
            helperPath: (helper ?? ClientSetup.bundledHelper()
                ?? URL(filePath: "/Applications/rePossess.app/Contents/MacOS/repossess")).path,
            libraryRoot: options.isDefaultLibrary ? nil : options.libraryRoot
        )
    }
}
