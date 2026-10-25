import Foundation
import RePossessCloud
import RePossessLibrary
import os

/// The app's logs, under the subsystem of its bundle identifier, as iMCP names its logs.
enum Log {
    static let subsystem = "co.dododo.repossess"
    static let refresh = Logger(subsystem: subsystem, category: "refresh")
    static let recognition = Logger(subsystem: subsystem, category: "recognition")
    static let clients = Logger(subsystem: subsystem, category: "clients")
    static let settings = Logger(subsystem: subsystem, category: "settings")
}

/// What the app was started with: the library folder, and whether it may use the Keychain.
///
/// The app takes the same `--library` option and `REPOSSESS_LIBRARY` variable as the command,
/// so that a check can run it against a copy of the library.
/// `--no-keychain` or `REPOSSESS_NO_KEYCHAIN=1` keeps the app away from the Keychain:
/// it does not look for the device token, so it counts as not paired,
/// and it refuses to pair or unpair.
/// A program with a new signature that reads the Keychain makes macOS ask the owner,
/// and the read waits for the answer.
public struct AppOptions: Sendable, Equatable {
    /// The library folder.
    public var libraryRoot: URL
    /// Whether the library folder is the default one, which `repossess mcp` uses without `--library`.
    public var isDefaultLibrary: Bool
    /// Whether the app may use the Keychain.
    public var usesKeychain: Bool

    public init(libraryRoot: URL, isDefaultLibrary: Bool, usesKeychain: Bool) {
        self.libraryRoot = libraryRoot
        self.isDefaultLibrary = isDefaultLibrary
        self.usesKeychain = usesKeychain
    }

    /// Reads the options from the command line and the environment.
    /// Arguments that the app does not know, such as the ones that macOS adds, are ignored.
    public init(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        var library = environment["REPOSSESS_LIBRARY"].flatMap { $0.isEmpty ? nil : $0 }
        var keychain = !["1", "true", "yes"].contains(environment["REPOSSESS_NO_KEYCHAIN"]?.lowercased() ?? "")
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--library": library = rest.popFirst() ?? library
            case "--no-keychain": keychain = false
            default: continue
            }
        }
        if let library {
            let url = URL(filePath: (library as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            self.init(
                libraryRoot: url,
                isDefaultLibrary: url.standardizedFileURL.path == Library.defaultRoot.standardizedFileURL.path,
                usesKeychain: keychain
            )
        } else {
            self.init(libraryRoot: Library.defaultRoot, isDefaultLibrary: true, usesKeychain: keychain)
        }
    }

    /// The store for the device token: the login keychain, or one that is never paired.
    public var tokenStore: any DeviceTokenStore {
        usesKeychain ? SystemKeychain() : NoKeychain()
    }
}

/// A device token store that never touches the Keychain, for runs with `--no-keychain`.
public struct NoKeychain: DeviceTokenStore {
    public init() {}

    /// The message for every operation that needs the Keychain.
    public static let message = "This run of rePossess does not use the Keychain (--no-keychain)."

    public func read(service: String) throws -> String? { throw NoKeychainError() }
    public func exists(service: String) -> Bool { false }
    public func add(_ token: String, service: String) throws { throw NoKeychainError() }
    public func delete(service: String) throws -> Bool { throw NoKeychainError() }
}

/// The error of every ``NoKeychain`` operation that needs the Keychain.
public struct NoKeychainError: Error, CustomStringConvertible {
    public var description: String { NoKeychain.message }
}

/// The one-time code that pairing needs.
public enum PairingCode {
    /// Whether a code has the form that `repossess pair` accepts: eight ASCII letters or digits,
    /// with spaces and line ends around it ignored. The settings enable "Pair" only for such a code.
    public static func isPlausible(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 8
            && trimmed.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }
}
