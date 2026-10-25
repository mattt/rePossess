import Foundation
import Security

/// Stores API keys for the cloud providers, as generic passwords under one service name.
///
/// The live store is ``SystemAPIKeychain``; tests use an in-memory fake.
public protocol APIKeyStore: Sendable {
    /// Reads the key for a provider, or returns `nil` when there is none.
    func read(provider: String) throws -> String?
    /// Whether a key exists for a provider. This must not read the secret.
    func exists(provider: String) -> Bool
    /// Stores a key, replacing an earlier one.
    func save(_ key: String, provider: String) throws
    /// Deletes a key.
    /// - Returns: Whether there was a key to delete.
    func delete(provider: String) throws -> Bool
}

/// Where rePossess finds a provider's API key: an environment variable first, then the Keychain.
///
/// Keys never go into `recognizer.json`, a log, or a tool result.
public enum APIKeys {
    /// The Keychain service of every API key; the account is the provider's name.
    public static let service = "rePossess recognizer"

    /// The key for a provider, from its environment variables or the Keychain.
    ///
    /// macOS may ask the user before the Keychain read.
    public static func key(
        for provider: RecognizerProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: any APIKeyStore = SystemAPIKeychain()
    ) throws -> String {
        for variable in provider.apiKeyVariables {
            if let value = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        if let value = try store.read(provider: provider.rawValue), !value.isEmpty { return value }
        throw RecognizerError.apiKeyMissing(
            "No API key for \(provider.rawValue). Set \(provider.apiKeyVariables.joined(separator: " or ")), "
                + "or run `repossess recognizer key \(provider.rawValue)` to keep one in the login keychain."
        )
    }

    /// Where a key would come from, without reading a secret: an environment variable's name,
    /// "the login keychain", or `nil` when there is none.
    public static func source(
        for provider: RecognizerProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: any APIKeyStore = SystemAPIKeychain()
    ) -> String? {
        if let variable = provider.apiKeyVariables.first(where: { !(environment[$0] ?? "").isEmpty }) {
            return variable
        }
        return store.exists(provider: provider.rawValue) ? "the login keychain" : nil
    }
}

/// API keys in the login keychain.
public struct SystemAPIKeychain: APIKeyStore {
    public init() {}

    private func query(_ provider: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: APIKeys.service,
            kSecAttrAccount as String: provider,
        ]
    }

    private func failure(_ status: OSStatus) -> RecognizerError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return .apiKeyMissing("The login keychain answered \(status): \(message)")
    }

    public func read(provider: String) throws -> String? {
        var query = query(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func exists(provider: String) -> Bool {
        var query = query(provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func save(_ key: String, provider: String) throws {
        _ = try delete(provider: provider)
        var item = query(provider)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "\(APIKeys.service): \(provider) API key"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
    }

    public func delete(provider: String) throws -> Bool {
        let status = SecItemDelete(query(provider) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw failure(status) }
        return true
    }
}

/// An in-memory key store for tests. It is internal; tests reach it with `@testable import`.
final class FakeAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]
    private var readLog: [String] = []

    init(_ keys: [String: String] = [:]) { self.keys = keys }

    /// The providers whose keys were read, in order.
    var reads: [String] { lock.withLock { readLog } }

    func read(provider: String) throws -> String? {
        lock.withLock {
            readLog.append(provider)
            return keys[provider]
        }
    }

    func exists(provider: String) -> Bool { lock.withLock { keys[provider] != nil } }

    func save(_ key: String, provider: String) throws { lock.withLock { keys[provider] = key } }

    func delete(provider: String) throws -> Bool { lock.withLock { keys.removeValue(forKey: provider) != nil } }
}
