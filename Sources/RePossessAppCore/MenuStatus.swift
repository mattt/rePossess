import Foundation
import RePossessLibrary

/// What the menu shows: one status, the connection, and only the problems and work that need attention.
///
/// The menu used to list every status line, then the last outcome,
/// so one failure could appear twice and set the menu's width.
/// This keeps one problem for each source, in a short row,
/// and leaves the full text to the settings pane that the row opens.
public struct MenuStatus: Equatable, Sendable {
    /// A failure that the owner can review in a settings pane.
    public struct Problem: Equatable, Sendable {
        /// A short title, such as "USB Refresh Failed 5 Minutes Ago".
        public var title: String
        /// The pane that shows the full text and what to do.
        public var pane: SettingsTab
    }

    /// The library's state, such as "Library Updated 3 Minutes Ago" or "Refreshing…".
    public var headline: String
    /// When the next scheduled refresh is due, such as "Next Refresh in About 12 Minutes".
    public var nextRefresh: String?
    /// The paths to the tablet, such as "Tablet Not on USB · Cloud Paired".
    public var connection: String
    /// The current failures, at most one for each source.
    public var problems: [Problem]
    /// The queue, when a push waits, is being sent, has an unconfirmed delivery, or failed.
    public var queue: [String]
    /// Handwriting, when it needs attention or has work.
    public var handwriting: Handwriting?

    /// The handwriting row: a title, and whether the row opens the Handwriting pane.
    public struct Handwriting: Equatable, Sendable {
        public var title: String
        public var opensPane: Bool
    }

    public init(
        snapshot: StatusSnapshot,
        refreshing: Bool,
        lastOutcome: RefreshOutcome?,
        recognizing: Bool,
        recognitionFailure: String?,
        readiness: RecognizerReadiness
    ) {
        let now = snapshot.now
        if snapshot.libraryError != nil {
            headline = "Library Unavailable"
        } else if refreshing {
            headline = "Refreshing…"
        } else if let latest = snapshot.library?.latestRefresh {
            headline = Self.titleCased("Library updated \(StatusSnapshot.age(latest.date, now: now))")
        } else {
            headline = "Library Not Refreshed Yet"
        }
        nextRefresh =
            refreshing || snapshot.libraryError != nil
            ? nil
            : snapshot.nextRefresh.map { Self.titleCased("Next refresh \(StatusSnapshot.until($0, now: now))") }

        let cloud =
            switch snapshot.pairing {
            case .paired: "Cloud Paired"
            case .notPaired: "Cloud Not Paired"
            case .keychainOff: "Cloud Not Checked"
            }
        connection = (snapshot.usbPresent ? "Tablet on USB" : "Tablet Not on USB") + " · " + cloud

        var problems: [Problem] = []
        if snapshot.libraryError != nil {
            problems.append(Problem(title: "The Library Could Not Be Opened", pane: .general))
        }
        // The library keeps an error only while it is newer than the source's last success.
        for (source, name, pane) in [(Source.usb, "USB", SettingsTab.general), (.cloud, "Cloud", .cloud)] {
            guard snapshot.library?.lastError[source] != nil else { continue }
            let when = snapshot.library?.lastErrorAt[source].map { " " + StatusSnapshot.age($0, now: now) } ?? ""
            problems.append(Problem(title: Self.titleCased("\(name) refresh failed\(when)"), pane: pane))
        }
        // The last outcome repeats a source's error when the library recorded it; show it only otherwise.
        if !refreshing, problems.isEmpty, let lastOutcome, case .failed = lastOutcome.result {
            problems.append(Problem(title: "Refresh Failed", pane: .general))
        }
        self.problems = problems

        let counts = snapshot.pushCounts
        queue = [
            (PushStatus.pending, "Document Waiting to Send", "Documents Waiting to Send"),
            (.sending, "Document Sending", "Documents Sending"),
            (.unknown, "Delivery Unconfirmed", "Deliveries Unconfirmed"),
            (.failed, "Document Not Sent", "Documents Not Sent"),
        ]
        .compactMap { status, one, many in
            guard let count = counts[status], count > 0 else { return nil }
            return "\(count) \(count == 1 ? one : many)"
        }

        if recognizing {
            handwriting = Handwriting(title: "Recognizing Handwriting…", opensPane: false)
        } else if recognitionFailure != nil {
            handwriting = Handwriting(title: "Handwriting Recognition Failed", opensPane: true)
        } else if readiness.needsAction {
            handwriting = Handwriting(title: "Handwriting: \(readiness.title)", opensPane: true)
        } else if readiness == .ready, let waiting = snapshot.recognition?.waiting, waiting > 0 {
            handwriting = Handwriting(
                title: "Handwriting: \(waiting) \(waiting == 1 ? "Page" : "Pages") Waiting",
                opensPane: false
            )
        } else {
            handwriting = nil
        }
    }

    /// The status rows in the menu's order, for the log; a row that opens a pane ends in an ellipsis.
    public var rows: [String] {
        [headline] + [nextRefresh].compactMap { $0 } + [connection] + problems.map { $0.title + "…" } + queue
            + [handwriting.map { $0.opensPane ? $0.title + "…" : $0.title }].compactMap { $0 }
    }

    /// Words that title-style capitalization leaves in lowercase, except at the start.
    static let minorWords: Set<String> = ["a", "an", "and", "the", "of", "to", "in", "on", "by", "from", "or"]

    /// Title-style capitalization for a menu item, such as "Library Updated 3 Minutes Ago".
    /// It changes only the first letter of each word, so "USB" stays as it is.
    static func titleCased(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { index, word in
            let word = String(word)
            if index > 0, minorWords.contains(word) { return word }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        .joined(separator: " ")
    }
}
