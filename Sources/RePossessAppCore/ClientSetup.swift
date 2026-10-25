import Foundation

/// The MCP configuration that each client needs to start the helper inside the app.
///
/// Every client starts `<app>/Contents/MacOS/repossess mcp` over standard input and output.
/// When the app uses a library other than the default, the arguments add `--library`,
/// so that the clients read the library that the app refreshes.
public struct ClientSetup: Sendable, Equatable {
    /// The server's name in each client's configuration.
    public static let serverName = "repossess"

    /// The helper's path, inside the app bundle.
    public var helperPath: String
    /// The arguments after the helper's path.
    public var arguments: [String]

    public init(helperPath: String, libraryRoot: URL?) {
        self.helperPath = helperPath
        self.arguments = ["mcp"] + (libraryRoot.map { ["--library", $0.path] } ?? [])
    }

    /// The helper beside the running app's executable, in `Contents/MacOS`.
    public static func bundledHelper(executable: URL? = Bundle.main.executableURL) -> URL? {
        executable?.deletingLastPathComponent().appending(path: "repossess")
    }

    /// Whether an app bundle is in `/Applications` or the user's `~/Applications`,
    /// where a client's configuration can name its helper for good.
    public static func isInApplications(
        _ bundle: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let path = bundle.standardizedFileURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(home.appending(path: "Applications").standardizedFileURL.path + "/")
    }

    /// The client's entry, as Claude Desktop and Claude Code's `.mcp.json` write it.
    var entry: [String: Any] {
        ["command": helperPath, "args": arguments]
    }

    /// The command that adds the server to Claude Code for every project of this user.
    public var claudeCodeCommand: String {
        (["claude", "mcp", "add", "--scope", "user", Self.serverName, "--", helperPath] + arguments)
            .map(Self.shellQuoted).joined(separator: " ")
    }

    /// A project's `.mcp.json` for Claude Code, or a file for `claude --mcp-config`.
    public var claudeCodeJSON: String {
        Self.json(["mcpServers": [Self.serverName: ["type": "stdio", "command": helperPath, "args": arguments]]])
    }

    /// The `mcpServers` entry for Claude Desktop's `claude_desktop_config.json`.
    public var claudeDesktopJSON: String {
        Self.json(["mcpServers": [Self.serverName: entry]])
    }

    /// The command that adds the server to Codex.
    public var codexCommand: String {
        (["codex", "mcp", "add", Self.serverName, "--", helperPath] + arguments)
            .map(Self.shellQuoted).joined(separator: " ")
    }

    /// The table for Codex's `~/.codex/config.toml`.
    public var codexTOML: String {
        """
        [mcp_servers.\(Self.serverName)]
        command = \(Self.tomlString(helperPath))
        args = [\(arguments.map(Self.tomlString).joined(separator: ", "))]
        """
    }

    // MARK: Formatting

    static func json(_ object: [String: Any]) -> String {
        let data =
            (try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A word for a POSIX shell: as it is when it is safe, and in single quotes otherwise.
    static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,"
        )
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A TOML basic string.
    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case let s where s.value < 0x20 || s.value == 0x7F: out += String(format: "\\u%04X", s.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// Adds the helper to Claude Desktop's configuration file, only when the owner asks.
///
/// The app shows the file before and after the change, and writes only after the owner confirms.
/// It copies the existing file to a backup beside it first,
/// keeps every other key and server, and refuses a file that is not a JSON object.
/// Tests use files in a temporary folder; nothing in development writes a client's configuration.
public struct ClaudeDesktopConfig: Sendable {
    /// The configuration file.
    public var url: URL

    public init(url: URL = Self.defaultURL) {
        self.url = url
    }

    /// `~/Library/Application Support/Claude/claude_desktop_config.json`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Claude/claude_desktop_config.json")
    }

    /// A change that the owner can review before it is written.
    public struct Change: Sendable, Equatable {
        /// The file's text now, or `nil` when there is no file.
        public var before: String?
        /// The file's text after the change.
        public var after: String
        /// Whether the file already has a `repossess` server, which the change replaces.
        public var replacesServer: Bool
        /// Whether the file already has exactly this entry, so that nothing would change.
        public var unchanged: Bool
    }

    /// An error that stops the change before anything is written.
    public struct ConfigError: Error, CustomStringConvertible, Equatable {
        public var description: String
    }

    /// Reads the file and prepares the change, without writing anything.
    public func prepare(_ setup: ClientSetup) throws -> Change {
        let manager = FileManager.default
        var root: [String: Any] = [:]
        var before: String? = nil
        if manager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            before = String(decoding: data, as: UTF8.self)
            if !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ConfigError(
                        description: "\(url.path) is not a JSON object, so rePossess does not change it. "
                            + "Add the entry by hand, or fix the file first."
                    )
                }
                root = object
            }
        }
        var servers: [String: Any] = [:]
        if let existing = root["mcpServers"] {
            guard let existing = existing as? [String: Any] else {
                throw ConfigError(
                    description: "mcpServers in \(url.path) is not an object, so rePossess does not change it."
                )
            }
            servers = existing
        }
        let previous = servers[ClientSetup.serverName]
        let entry = setup.entry
        let unchanged =
            previous.map { NSDictionary(dictionary: entry).isEqual(to: ($0 as? [String: Any]) ?? [:]) } ?? false
        servers[ClientSetup.serverName] = entry
        root["mcpServers"] = servers
        return Change(
            before: before,
            after: ClientSetup.json(root) + "\n",
            replacesServer: previous != nil,
            unchanged: unchanged
        )
    }

    /// Writes a prepared change, after a backup of the current file.
    ///
    /// It refuses when the file changed since ``prepare(_:)`` read it.
    /// - Returns: The backup's location, or `nil` when there was no file to back up.
    @discardableResult
    public func write(_ change: Change, now: Date = Date()) throws -> URL? {
        let manager = FileManager.default
        let current =
            manager.fileExists(atPath: url.path) ? String(decoding: try Data(contentsOf: url), as: UTF8.self) : nil
        guard current == change.before else {
            throw ConfigError(description: "\(url.path) changed after the preview; open the preview again.")
        }
        var backup: URL? = nil
        if current != nil {
            let stamp = Self.stamp(now)
            let target = url.deletingLastPathComponent().appending(
                path: url.lastPathComponent + ".repossess-backup-\(stamp)"
            )
            try manager.copyItem(at: url, to: target)
            backup = target
        } else {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(change.after.utf8).write(to: url, options: .atomic)
        Log.clients.info("Wrote the repossess server to Claude Desktop's configuration")
        return backup
    }

    /// A time stamp for a backup's name, such as `20261025-142301`.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
