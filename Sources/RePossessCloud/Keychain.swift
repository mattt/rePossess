import Foundation
import Security

/// Reads the device token from the login keychain.
///
/// Spike 6 stored the token when Mattt paired the Mac on 2026-10-25.
/// Phase 1 only reads it; pairing comes in phase 2,
/// and phase 5 can rename the item by changing ``service`` here, the only place that names it.
public enum DeviceTokenKeychain {
    /// The service name of the Keychain item.
    public static let service = "rePossess spike 6"
    /// The account name of the Keychain item.
    public static let account = "reMarkable device token"

    /// Reads the device token.
    ///
    /// macOS may ask the user to allow the command to read the item,
    /// because another program created it.
    /// - Throws: ``CloudError/notPaired(service:)`` when there is no item.
    @Sendable public static func read() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw CloudError.notPaired(service: service) }
        guard status == errSecSuccess, let data = result as? Data else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            throw CloudError.keychain(status: status, message: message)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether the item exists. This reads the item's attributes, not the token,
    /// so macOS does not ask for permission.
    public static func exists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
