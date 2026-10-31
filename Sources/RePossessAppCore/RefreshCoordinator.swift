import Foundation
import RePossessLibrary
import RePossessMCP
import RePossessCloud
import RePossessUSB

/// Why the app starts a refresh.
public enum RefreshTrigger: String, Sendable, Equatable {
    /// The owner chose "Refresh now".
    case manual
    /// The tablet's USB network appeared.
    case usbAppeared
    /// The schedule's interval passed.
    case schedule
    /// `repossess mcp` asked the app to refresh over USB for its client (see `AppLink`).
    case client
}

/// What the app knows about the paths when a refresh starts.
public struct RefreshPaths: Sendable, Equatable {
    public var usbPresent: Bool
    public var paired: Bool

    public init(usbPresent: Bool, paired: Bool) {
        self.usbPresent = usbPresent
        self.paired = paired
    }

    /// The source for a trigger, or `nil` when there is nothing to refresh from.
    ///
    /// The app never refreshes from the cloud without a device token,
    /// so an unpaired Mac records no cloud errors, and a USB refresh does not fall back to the cloud.
    public func source(for trigger: RefreshTrigger) -> RefreshSource? {
        if trigger == .client { return usbPresent ? .usb : nil }
        return switch (usbPresent, paired) {
        case (true, true): trigger == .usbAppeared ? .usb : .auto
        case (true, false): .usb
        case (false, true): trigger == .usbAppeared ? nil : .cloud
        case (false, false): nil
        }
    }
}

/// The kind of error that stopped a refresh, for the app's retries.
public enum RefreshFailureKind: Sendable, Equatable {
    /// The Mac could not reach the network: offline, no route, or no answer in time,
    /// as at login before Wi-Fi connects.
    case network
    /// The cloud or the tablet refused the request with HTTP 4xx, which a retry does not change.
    case refused
    /// Anything else, such as a server error, which the schedule's long backoff handles.
    case other

    /// The kind of an error from a refresh.
    public static func of(_ error: any Error) -> Self {
        switch error {
        case let error as URLError:
            return Self.networkCodes.contains(error.code) ? .network : .other
        case let error as USBError:
            switch error {
            case .notConnected, .network, .connectionLost, .localNetworkDenied: return .network
            case .http(_, let status) where (400 ..< 500).contains(status): return .refused
            default: return .other
            }
        case let error as CloudError:
            switch error {
            case .unauthorized, .registrationRefused: return .refused
            case .http(let status, _) where (400 ..< 500).contains(status): return .refused
            default: return .other
            }
        default:
            let error = error as NSError
            if error.domain == NSURLErrorDomain { return of(URLError(URLError.Code(rawValue: error.code))) }
            return .other
        }
    }

    /// The URL errors that mean the network was not there.
    static let networkCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .timedOut, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
    ]
}

/// What one refresh did.
public struct RefreshOutcome: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        /// The refresh ran, with a report for each source; a report may say that it stopped early.
        case finished([RefreshReport])
        /// The refresh failed before it had a report.
        case failed(String)
        /// Another refresh in this app was running.
        case alreadyRunning
        /// Another process, such as `repossess mcp`, held the library's refresh lock.
        case busyElsewhere
        /// Neither USB nor the cloud was available.
        case noPath
    }

    public var trigger: RefreshTrigger
    public var result: Result
    public var started: Date
    public var ended: Date
    /// For a refresh that failed before it had a report, the kind of error.
    public var failureKind: RefreshFailureKind?

    public init(
        trigger: RefreshTrigger,
        result: Result,
        started: Date,
        ended: Date,
        failureKind: RefreshFailureKind? = nil
    ) {
        self.trigger = trigger
        self.result = result
        self.started = started
        self.ended = ended
        self.failureKind = failureKind
    }

    /// Whether the refresh counts as a failure for the schedule's backoff.
    public var isFailure: Bool {
        switch result {
        case .failed: true
        case .finished(let reports): reports.last?.stoppedBy != nil
        case .alreadyRunning, .busyElsewhere, .noPath: false
        }
    }

    /// Whether the mirror may have changed, so that recognition should look for new pages.
    public var mayHaveChangedTheMirror: Bool {
        if case .finished = result { return true }
        return false
    }

    /// One line for the menu.
    public var summary: String {
        switch result {
        case .finished(let reports):
            let parts = reports.map { report -> String in
                let name = report.source == .usb ? "USB" : "the cloud"
                if let stopped = report.stoppedBy { return "\(name) stopped: \(stopped)" }
                var text = "\(name): \(report.downloaded) downloaded, \(report.unchanged) unchanged"
                if report.removed > 0 { text += ", \(report.removed) removed" }
                if !report.pushes.isEmpty {
                    let sent = report.pushes.filter { $0.status == .sent }.count
                    text += ", \(sent) of \(report.pushes.count) pushes sent"
                }
                return text
            }
            return "Refreshed from " + parts.joined(separator: "; then ")
        case .failed(let message): return "The refresh failed: \(message)"
        case .alreadyRunning: return "A refresh was already running."
        case .busyElsewhere: return "Another rePossess process was refreshing; the app will try again later."
        case .noPath: return "Nothing to refresh from: the tablet is not on USB, and rePossess is not paired."
        }
    }
}

/// Runs one refresh at a time.
///
/// The app has one coordinator. A second request while a refresh runs returns ``RefreshOutcome/Result/alreadyRunning``
/// at once, and the library's lock file keeps the app and `repossess` in another process
/// from refreshing at the same time: the one that comes second gets ``RefreshOutcome/Result/busyElsewhere``.
/// The refresh function sends the queue of pushes when it finishes (``Library/sendPushes(paths:wait:progress:)``),
/// under the same lock.
public actor RefreshCoordinator {
    /// Refreshes from a source and sends the queue; `refreshLibrary` in the app.
    public typealias Refresh = @Sendable (RefreshSource) async throws -> [RefreshReport]

    private let refresh: Refresh
    private let paths: @Sendable () -> RefreshPaths
    private let clock: @Sendable () -> Date
    private var running = false

    public init(
        paths: @escaping @Sendable () -> RefreshPaths,
        clock: @escaping @Sendable () -> Date = Date.init,
        refresh: @escaping Refresh
    ) {
        self.paths = paths
        self.clock = clock
        self.refresh = refresh
    }

    /// Whether a refresh is running.
    public var isRunning: Bool { running }

    /// Refreshes, unless a refresh is running or there is no path.
    public func run(_ trigger: RefreshTrigger) async -> RefreshOutcome {
        let started = clock()
        guard !running else {
            return RefreshOutcome(trigger: trigger, result: .alreadyRunning, started: started, ended: started)
        }
        guard let source = paths().source(for: trigger) else {
            return RefreshOutcome(trigger: trigger, result: .noPath, started: started, ended: started)
        }
        running = true
        defer { running = false }
        let result: RefreshOutcome.Result
        var kind: RefreshFailureKind?
        do {
            result = .finished(try await refresh(source))
        } catch RefreshError.busy {
            result = .busyElsewhere
        } catch {
            result = .failed("\(error)")
            kind = RefreshFailureKind.of(error)
        }
        return RefreshOutcome(trigger: trigger, result: result, started: started, ended: clock(), failureKind: kind)
    }
}

extension RefreshCoordinator {
    /// The app's refresh: `refreshLibrary` from a source, then the queue of pushes
    /// by USB when the tablet is on USB and through the cloud when a device token item exists.
    ///
    /// The cloud path is offered only when the app may use the Keychain and an item exists,
    /// which the app checks without reading the token.
    public static func libraryRefresh(
        library: Library,
        session: CloudSession,
        paired: @escaping @Sendable () -> Bool,
        usbPresent: @escaping @Sendable () -> Bool = USBNetwork.isPresent,
        usb: @escaping @Sendable () -> USBClient = { USBClient() }
    ) -> Refresh {
        { source in
            let paths = PushPaths(usb: usbPresent() ? usb : nil, cloud: paired() ? session : nil)
            return try await refreshLibrary(
                library,
                source,
                session: session,
                usb: usb,
                usbPresent: usbPresent,
                pushes: paths,
                progress: { Log.refresh.info("\($0)") }
            )
        }
    }
}
