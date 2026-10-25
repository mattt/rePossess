import Foundation
import RePossessCloud

/// What pairing or unpairing did, in a sentence for the Cloud pane, with technical details apart.
///
/// The summary never names a Keychain item; the details may.
public struct PairingOutcome: Equatable, Sendable {
    /// Whether the action succeeded.
    public var succeeded: Bool
    /// One or two sentences for the owner, with what to do next after a failure.
    public var summary: String
    /// The technical text, such as the error or the Keychain items, for a "Details" disclosure.
    public var details: String?

    public init(succeeded: Bool, summary: String, details: String? = nil) {
        self.succeeded = succeeded
        self.summary = summary
        self.details = details
    }

    /// Whether the code field keeps its code: after a failure the owner can correct the code or replace it,
    /// and after a success the code is spent.
    public var keepsCode: Bool { !succeeded }

    /// The outcome of a pairing that succeeded.
    public static func paired(olderService: String?) -> Self {
        PairingOutcome(
            succeeded: true,
            summary: "Paired with your reMarkable account. rePossess can now refresh from reMarkable's cloud.",
            details: olderService.map {
                "An older device token, \"\($0)\", is still in the login keychain; rePossess no longer reads it."
            }
        )
    }

    /// The outcome of a pairing that failed, with the recovery for its kind of error.
    public static func pairingFailed(_ error: any Error) -> Self {
        let summary: String
        switch error {
        case CloudError.registrationRefused:
            summary =
                "reMarkable did not accept this code. A code works only once: check it for a typing mistake, or get a new code and try again."
        case CloudError.invalidCode:
            summary = "A one-time code has eight letters or digits."
        case CloudError.alreadyPaired:
            summary = "rePossess is already paired. Unpair it first to pair again."
        case is NoKeychainError:
            summary = NoKeychain.message
        default:
            summary =
                RefreshFailureKind.of(error) == .network
                ? "rePossess could not reach reMarkable's cloud. Check the internet connection, then try the same code again."
                : "Pairing failed. Try again, or get a new code."
        }
        return PairingOutcome(succeeded: false, summary: summary, details: "\(error)")
    }

    /// The outcome of an unpairing that deleted the given Keychain items.
    public static func unpaired(deleted: [String]) -> Self {
        PairingOutcome(
            succeeded: true,
            summary: deleted.isEmpty
                ? "There was no device token on this Mac. reMarkable may still list this Mac on your account."
                : "rePossess deleted its device token from this Mac. reMarkable still lists this Mac as a device until you remove it on my.remarkable.com.",
            details: Pairing.unpairMessage(deleted: deleted)
        )
    }
}

/// The first-run setup's progress, kept in `UserDefaults`.
///
/// The settings open to the setup once, at the first launch that finds no way to the tablet;
/// after that, General shows the setup until the owner finishes it or sets it up later.
public enum SetupProgress {
    /// Whether the owner finished the setup or chose to set it up later.
    public static let finishedKey = "setupFinished"
    /// Whether the app has opened the settings for the setup at launch.
    public static let shownKey = "setupShownAtLaunch"
    /// Whether the owner has opened MCP Clients.
    public static let clientsKey = "setupClientsOpened"

    /// Records the setup's state at launch, and says whether to open the settings for it.
    ///
    /// The setup opens once, at the first launch that finds no way to the tablet,
    /// unless the owner asked for a pane. An install that already reaches the tablet,
    /// such as one from before the setup existed, counts as set up.
    public static func atLaunch(defaults: UserDefaults, tabletReachable: Bool, requestedPane: SettingsTab?) -> Bool {
        if defaults.bool(forKey: finishedKey) || defaults.bool(forKey: shownKey) { return false }
        if tabletReachable {
            defaults.set(true, forKey: finishedKey)
            return false
        }
        guard requestedPane == nil else { return false }
        defaults.set(true, forKey: shownKey)
        return true
    }
}
