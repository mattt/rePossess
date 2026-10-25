import Foundation
import RePossessCloud
import RePossessLibrary
import RePossessRecognize

/// Whether rePossess can reach the cloud, as far as the app can tell without reading the token.
public enum PairingState: Sendable, Equatable {
    /// A device token item exists under this service name.
    case paired(service: String)
    /// No device token item exists.
    case notPaired
    /// The app was started with `--no-keychain`.
    case keychainOff
}

/// What the menu shows, read from the library at one moment.
public struct StatusSnapshot: Sendable, Equatable {
    public var usbPresent: Bool
    public var pairing: PairingState
    public var library: LibraryStatus?
    public var libraryError: String?
    public var pushCounts: [PushStatus: Int]
    public var recognizer: RecognizerConfiguration?
    public var recognizerError: String?
    public var recognition: RecognitionCounts?
    /// When the next scheduled refresh is due, or `nil` when the schedule is off.
    public var nextRefresh: Date?
    public var now: Date

    public init(
        usbPresent: Bool,
        pairing: PairingState,
        library: LibraryStatus? = nil,
        libraryError: String? = nil,
        pushCounts: [PushStatus: Int] = [:],
        recognizer: RecognizerConfiguration? = nil,
        recognizerError: String? = nil,
        recognition: RecognitionCounts? = nil,
        nextRefresh: Date? = nil,
        now: Date = Date()
    ) {
        self.nextRefresh = nextRefresh
        self.usbPresent = usbPresent
        self.pairing = pairing
        self.library = library
        self.libraryError = libraryError
        self.pushCounts = pushCounts
        self.recognizer = recognizer
        self.recognizerError = recognizerError
        self.recognition = recognition
        self.now = now
    }

    /// Reads the snapshot from a library. It never reads a secret:
    /// the pairing comes from whether a Keychain item exists.
    public static func read(
        library: Library,
        store: any DeviceTokenStore,
        usesKeychain: Bool,
        usbPresent: Bool,
        now: Date = Date()
    ) -> StatusSnapshot {
        var snapshot = StatusSnapshot(
            usbPresent: usbPresent,
            pairing: usesKeychain
                ? DeviceTokenKeychain.pairedService(in: store).map { .paired(service: $0) } ?? .notPaired
                : .keychainOff,
            now: now
        )
        do {
            snapshot.library = try library.status()
            snapshot.pushCounts = try library.pushCounts()
        } catch {
            snapshot.libraryError = "\(error)"
        }
        do {
            if let configuration = try RecognizerConfiguration.load(from: library.root) {
                snapshot.recognizer = configuration
                snapshot.recognition = try library.recognitionCounts(key: configuration.key)
            }
        } catch {
            snapshot.recognizerError = "\(error)"
        }
        return snapshot
    }

    // MARK: Lines for the menu

    /// The USB line.
    public var usbLine: String {
        usbPresent ? "USB: connected" : "USB: not connected"
    }

    /// The lines about the cloud: the pairing, the last success, and an error newer than it.
    public var cloudLines: [String] {
        switch pairing {
        case .keychainOff: return ["Cloud: not checked (this run does not use the Keychain)"]
        case .notPaired: return ["Cloud: not paired"]
        case .paired: break
        }
        var lines = [
            "Cloud: "
                + (library?.lastRefresh[.cloud].map { "last success \(Self.age($0, now: now))" } ?? "no success yet")
        ]
        if let error = library?.lastError[.cloud] {
            let when = library?.lastErrorAt[.cloud].map { " \(Self.age($0, now: now))" } ?? ""
            lines.append("Cloud error\(when): \(Self.shorten(error))")
        }
        return lines
    }

    /// A USB error that is newer than the last USB success, if there is one.
    public var usbErrorLine: String? {
        guard let error = library?.lastError[.usb] else { return nil }
        let when = library?.lastErrorAt[.usb].map { " \(Self.age($0, now: now))" } ?? ""
        return "USB error\(when): \(Self.shorten(error))"
    }

    /// The mirror's source and age, and when the next scheduled refresh is due.
    public var mirrorLine: String {
        if let libraryError { return "Library: \(Self.shorten(libraryError))" }
        return "Mirror: " + refreshTimes(capitalized: false)
    }

    /// The last refresh and the next, in relative times,
    /// such as "Refreshed from USB 3 minutes ago · next in about 12 minutes".
    ///
    /// The times are in whole minutes, so the text changes at most once a minute;
    /// the app reads the status every 15 seconds and when its menu opens.
    public func refreshTimes(capitalized: Bool = true) -> String {
        var text: String
        if let latest = library?.latestRefresh {
            let source = latest.source == .usb ? "USB" : "the cloud"
            text = "refreshed from \(source) \(Self.age(latest.date, now: now))"
        } else {
            text = "not refreshed yet"
        }
        if capitalized { text = text.prefix(1).uppercased() + text.dropFirst() }
        if let nextRefresh { text += " · next \(Self.until(nextRefresh, now: now))" }
        return text
    }

    /// The last refresh, for the settings, such as "From USB 3 minutes ago".
    public var lastRefreshText: String {
        guard let latest = library?.latestRefresh else { return "Not yet" }
        return "From \(latest.source == .usb ? "USB" : "the cloud") \(Self.age(latest.date, now: now))"
    }

    /// The next scheduled refresh, for the settings, such as "In about 12 minutes".
    public var nextRefreshText: String {
        guard let nextRefresh else { return "When the tablet connects or on request" }
        let text = Self.until(nextRefresh, now: now)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The queue of pushes.
    public var pushesLine: String {
        let parts = [
            (PushStatus.pending, "waiting"), (.sending, "sending"), (.unknown, "unknown"), (.failed, "failed"),
        ]
        .compactMap { status, name in pushCounts[status].flatMap { $0 > 0 ? "\($0) \(name)" : nil } }
        return parts.isEmpty ? "Pushes: none queued" : "Pushes: " + parts.joined(separator: ", ")
    }

    /// The recognizer: off, or its provider and model, with the pages that wait.
    public var recognizerLine: String {
        if let recognizerError { return "Recognizer: \(Self.shorten(recognizerError))" }
        guard let recognizer else { return "Recognizer: off" }
        var line = "Recognizer: \(recognizer.provider.rawValue), \(Self.modelName(recognizer))"
        if let waiting = recognition?.waiting, waiting > 0 {
            line += "; \(waiting) \(waiting == 1 ? "page waits" : "pages wait")"
        }
        return line
    }

    /// Every status line, in the menu's order.
    public var lines: [String] {
        [usbLine] + [usbErrorLine].compactMap { $0 } + cloudLines + [mirrorLine, pushesLine, recognizerLine]
    }

    // MARK: Formatting

    /// A short name for a configuration's model.
    public static func modelName(_ configuration: RecognizerConfiguration) -> String {
        switch configuration.provider {
        case .mlx:
            if let path = configuration.modelPath { return (path as NSString).lastPathComponent }
            return PinnedModel.qwen3VL8B.repository
        case .foundationModels: return "Apple's on-device model"
        case .client: return "the MCP client's model"
        default: return configuration.model ?? "no model"
        }
    }

    /// An age in words, such as "just now" or "3 hours ago".
    public static func age(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let (value, unit): (Int, String) =
            switch seconds {
            case ..<3600: (seconds / 60, "minute")
            case ..<86400: (seconds / 3600, "hour")
            default: (seconds / 86400, "day")
            }
        return "\(value) \(unit)\(value == 1 ? "" : "s") ago"
    }

    /// The time until a date in words, such as "in less than a minute" or "in about 12 minutes".
    public static func until(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "in less than a minute" }
        let (value, unit): (Int, String) =
            switch seconds {
            case ..<3570: (Int((seconds / 60).rounded()), "minute")
            case ..<86_400: (max(Int((seconds / 3600).rounded()), 1), "hour")
            default: (Int((seconds / 86_400).rounded()), "day")
            }
        return "in about \(value) \(unit)\(value == 1 ? "" : "s")"
    }

    /// The first line of a message, at most 90 characters, for a menu item.
    public static func shorten(_ message: String) -> String {
        let first = message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.count > 90 ? String(first.prefix(89)) + "…" : first
    }
}
