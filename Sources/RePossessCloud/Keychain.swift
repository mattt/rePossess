import Foundation
import Security

/// Stores device tokens as generic passwords, one item for each service name.
///
/// The live store is ``SystemKeychain``; tests use an in-memory fake.
public protocol DeviceTokenStore: Sendable {
    /// Reads the token stored under a service, or returns `nil` when there is none.
    func read(service: String) throws -> String?
    /// Whether an item exists under a service. This must not read the secret.
    func exists(service: String) -> Bool
    /// Stores a new token; fails if an item already exists under the service.
    func add(_ token: String, service: String) throws
    /// Deletes the item under a service.
    /// - Returns: Whether there was an item to delete.
    func delete(service: String) throws -> Bool
}

/// The device token's Keychain items, and the order in which rePossess reads them.
///
/// `repossess pair` stores the token under ``service``.
/// Spike 6 stored the token that phase 1 used under ``spikeService``;
/// reading falls back to it, so that the pairing from 2026-10-25 keeps working.
/// This is the only place that names the items.
public enum DeviceTokenKeychain {
    /// The service name of the item that `repossess pair` creates.
    public static let service = "rePossess"
    /// The service name of the item that spike 6 created.
    public static let spikeService = "rePossess spike 6"
    /// The account name of both items.
    public static let account = "reMarkable device token"
    /// The services to read, in order.
    public static let services = [service, spikeService]

    /// Reads the device token from the first item that exists, with the item's service name.
    ///
    /// macOS may ask the user to allow the read when another program created the item,
    /// and the read waits for the answer.
    /// - Throws: ``CloudError/notPaired(service:)`` when no item exists.
    public static func read(from store: any DeviceTokenStore) throws -> (token: String, service: String) {
        for service in services {
            if let token = try store.read(service: service) { return (token, service) }
        }
        throw CloudError.notPaired(service: service)
    }

    /// Reads the device token from the login keychain.
    @Sendable public static func read() throws -> String {
        try read(from: SystemKeychain()).token
    }

    /// The service of the first item that exists, without reading a token,
    /// so that macOS does not ask for permission.
    public static func pairedService(in store: any DeviceTokenStore = SystemKeychain()) -> String? {
        services.first { store.exists(service: $0) }
    }

    /// Whether any item exists, without reading a token.
    @Sendable public static func exists() -> Bool {
        pairedService() != nil
    }
}

/// The login keychain.
public struct SystemKeychain: DeviceTokenStore {
    public init() {}

    private func query(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: DeviceTokenKeychain.account,
        ]
    }

    private func failure(_ status: OSStatus) -> CloudError {
        .keychain(status: status, message: SecCopyErrorMessageString(status, nil) as String? ?? "unknown")
    }

    public func read(service: String) throws -> String? {
        var query = query(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func exists(service: String) -> Bool {
        var query = query(service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func add(_ token: String, service: String) throws {
        var item = query(service)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrLabel as String] = "\(service): \(DeviceTokenKeychain.account)"
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { throw CloudError.alreadyPaired(service: service) }
        guard status == errSecSuccess else { throw failure(status) }
    }

    public func delete(service: String) throws -> Bool {
        let status = SecItemDelete(query(service) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw failure(status) }
        return true
    }
}

/// An in-memory token store for tests. It is internal; tests reach it with `@testable import`.
final class FakeKeychain: DeviceTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]
    private var readLog: [String] = []

    init(_ items: [String: String] = [:]) { self.items = items }

    /// The stored items, by service.
    var contents: [String: String] { lock.withLock { items } }
    /// The services whose secrets were read, in order.
    var reads: [String] { lock.withLock { readLog } }

    func read(service: String) throws -> String? {
        lock.withLock {
            readLog.append(service)
            return items[service]
        }
    }

    func exists(service: String) -> Bool { lock.withLock { items[service] != nil } }

    func add(_ token: String, service: String) throws {
        try lock.withLock {
            guard items[service] == nil else { throw CloudError.alreadyPaired(service: service) }
            items[service] = token
        }
    }

    func delete(service: String) throws -> Bool {
        lock.withLock { items.removeValue(forKey: service) != nil }
    }
}
