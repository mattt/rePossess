import Foundation

/// How often the app refreshes the mirror on its own, and when the next refresh is due.
///
/// The default is every 15 minutes.
/// A cloud refresh whose root has not changed costs one request, and one more when the user token
/// is renewed, which the app's session does about once an hour.
/// Spike 6 saw rate-limit values of 30, 29, and 2 for the root, and 5, 2 to 4, and 12 to 26
/// for user tokens (phase 2), so four refreshes an hour stay far inside both
/// (an inference: how the server counts its window is unchecked).
/// reMarkdown's index lags the tablet by about 10 minutes;
/// 15 minutes keeps a new note on the Mac within a similar time.
/// After a failure, the wait doubles for each failure in a row,
/// to at most 8 times the interval and at most 6 hours, so that a broken token or an outage
/// does not send a request every interval; a success, or "Refresh now", starts the count again.
public struct RefreshSchedule: Sendable, Equatable {
    /// The interval in minutes, or 0 when the app refreshes only on request and when the tablet connects.
    public var intervalMinutes: Int

    public init(intervalMinutes: Int = Self.defaultMinutes) {
        self.intervalMinutes = intervalMinutes
    }

    /// The default interval.
    public static let defaultMinutes = 15
    /// The shortest interval that the settings offer.
    public static let minimumMinutes = 5
    /// The intervals that the settings offer, in minutes; 0 is "Only when the tablet connects or I ask".
    public static let choices = [0, 5, 15, 30, 60, 120, 360, 1440]
    /// The longest wait after failures.
    public static let maximumBackoff: TimeInterval = 6 * 3600

    /// The interval in seconds, or `nil` when scheduled refreshes are off.
    public var interval: TimeInterval? {
        intervalMinutes > 0 ? TimeInterval(max(intervalMinutes, Self.minimumMinutes) * 60) : nil
    }

    /// When the next scheduled refresh is due, or `nil` when scheduled refreshes are off.
    /// - Parameters:
    ///   - lastAttempt: The end of the last refresh that the app ran or tried, or `nil` before the first.
    ///   - failures: The refreshes in a row that failed.
    ///   - now: The time now, for the first refresh.
    public func nextDate(after lastAttempt: Date?, failures: Int, now: Date) -> Date? {
        guard let interval else { return nil }
        guard let lastAttempt else { return now }
        let factor = Double(1 << min(max(failures, 0), 3))
        let wait = min(interval * factor, max(interval, Self.maximumBackoff))
        return lastAttempt.addingTimeInterval(wait)
    }

    /// The waits before each quick retry after a network failure: 15 and 30 seconds, then 1, 2, and 5 minutes,
    /// then every 5 minutes while the network stays away. None is longer than the interval.
    public static let quickRetries: [TimeInterval] = [15, 30, 60, 120, 300]

    /// When to try again after network failures in a row, or `nil` when there were none
    /// or scheduled refreshes are off.
    ///
    /// A refresh that fails because the Mac is offline sends nothing, so it is tried again soon,
    /// apart from the long backoff for failures that reached a server.
    public func quickRetryDate(after lastAttempt: Date, networkFailures: Int) -> Date? {
        guard let interval, networkFailures > 0 else { return nil }
        let wait = Self.quickRetries[min(networkFailures, Self.quickRetries.count) - 1]
        return lastAttempt.addingTimeInterval(min(wait, interval))
    }

    /// A label for an interval in the settings.
    public static func label(minutes: Int) -> String {
        switch minutes {
        case 0: "Only when the tablet connects or on request"
        case 60: "Every hour"
        case 1440: "Every day"
        case let m where m % 60 == 0: "Every \(m / 60) hours"
        default: "Every \(minutes) minutes"
        }
    }
}

/// Tells when the tablet's USB network appears.
///
/// The app checks the network when macOS reports a change and every few seconds,
/// and refreshes over USB when the network appears, including when the app starts with the tablet connected.
public struct USBAppearance: Sendable, Equatable {
    /// Whether the network was present at the last check, or `nil` before the first check.
    public private(set) var present: Bool?

    public init() {}

    /// Records a check.
    /// - Returns: Whether the network appeared since the last check.
    public mutating func update(present now: Bool) -> Bool {
        defer { present = now }
        return now && present != true
    }
}

/// The app's failures in a row: network failures, which get quick retries,
/// and other failures, which lengthen the wait for the next scheduled refresh.
public struct RefreshBackoff: Sendable, Equatable {
    /// Failures in a row that reached a server or the tablet, or were refused.
    public private(set) var failures = 0
    /// Failures in a row because the network was not there.
    public private(set) var networkFailures = 0

    public init() {}

    /// Counts a refresh.
    ///
    /// A client's refresh through the helper does not count, nor does one that another process's lock
    /// or a missing path stopped. A refusal (HTTP 4xx) gets no quick retry.
    public mutating func record(_ outcome: RefreshOutcome) {
        guard outcome.trigger != .client else { return }
        switch outcome.result {
        case .alreadyRunning, .busyElsewhere, .noPath:
            return
        case .failed where outcome.failureKind == .network:
            networkFailures += 1
        case .failed, .finished:
            if outcome.isFailure {
                failures += 1
            } else {
                failures = 0
            }
            networkFailures = 0
        }
    }

    /// Starts the counts again, as "Refresh Now" does.
    public mutating func reset() {
        failures = 0
        networkFailures = 0
    }

    /// Whether a refresh failed because the network was away, so that its return should start one.
    public var waitsForNetwork: Bool { networkFailures > 0 }

    /// When the next refresh is due.
    /// - Parameters:
    ///   - lastAttempt: The end of the app's last refresh.
    ///   - latestRefresh: The latest refresh that finished, by any process.
    public func nextDate(schedule: RefreshSchedule, lastAttempt: Date?, latestRefresh: Date?, now: Date) -> Date? {
        if let lastAttempt, let quick = schedule.quickRetryDate(after: lastAttempt, networkFailures: networkFailures) {
            return quick
        }
        let latest = [lastAttempt, latestRefresh].compactMap { $0 }.max()
        return schedule.nextDate(after: latest, failures: failures, now: now)
    }
}

/// Tells when the network returns, from `NWPathMonitor`'s reports.
public struct NetworkReturn: Sendable, Equatable {
    /// Whether the path was satisfied at the last report, or `nil` before the first.
    public private(set) var satisfied: Bool?

    public init() {}

    /// Records a report.
    /// - Returns: Whether the path became satisfied after a report that it was not.
    public mutating func update(satisfied now: Bool) -> Bool {
        defer { satisfied = now }
        return now && satisfied == false
    }
}
