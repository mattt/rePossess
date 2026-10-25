import Foundation

/// Pairs rePossess with a reMarkable account, and forgets the pairing.
///
/// Pairing registers a new `desktop-macos` device on the owner's account
/// with a one-time code from ``CloudHosts/connectPage``,
/// and keeps the device token in the Keychain under ``DeviceTokenKeychain/service``.
/// The code and the token never go to a file, a log, or standard output.
public struct Pairing: Sendable {
    let transport: any HTTPTransport
    let store: any DeviceTokenStore
    let builder: RequestBuilder

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        store: any DeviceTokenStore = SystemKeychain(),
        authHost: URL = CloudHosts.auth
    ) {
        self.transport = transport
        self.store = store
        self.builder = RequestBuilder(authHost: authHost)
    }

    /// What a pairing did.
    public struct Result: Sendable, Equatable {
        /// The service name of the new Keychain item.
        public var service: String
        /// The device ID that rePossess registered.
        public var deviceID: String
        /// An older item that is still in the Keychain and is no longer read first, if one is.
        public var olderService: String?
    }

    /// Registers this Mac with a one-time code and stores the device token.
    ///
    /// It refuses before any request when the code is malformed,
    /// or when an item already exists under ``DeviceTokenKeychain/service``,
    /// because a second registration would add a second device to the account.
    /// - Parameter text: The code as typed; spaces and line ends around it are ignored.
    public func pair(code text: String, deviceID: UUID = UUID()) async throws -> Result {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try builder.registerDevice(code: code, deviceID: deviceID)
        let service = DeviceTokenKeychain.service
        guard !store.exists(service: service) else { throw CloudError.alreadyPaired(service: service) }
        let response = try await transport.send(request)
        guard (200 ..< 300).contains(response.status) else {
            throw CloudError.registrationRefused(status: response.status, message: String(response.text.prefix(300)))
        }
        let token = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.split(separator: ".", omittingEmptySubsequences: false).count == 3 else {
            throw CloudError.malformedToken
        }
        try store.add(token, service: service)
        let older = DeviceTokenKeychain.services.dropFirst().first { store.exists(service: $0) }
        return Result(service: service, deviceID: deviceID.uuidString.lowercased(), olderService: older)
    }

    /// Deletes every device token item that rePossess reads, and sends nothing to reMarkable.
    ///
    /// The device stays on the account until the owner removes it on my.remarkable.com.
    /// - Returns: The service names of the deleted items.
    public func unpair() throws -> [String] {
        try DeviceTokenKeychain.services.filter { try store.delete(service: $0) }
    }

    /// What to tell the owner after ``unpair()``.
    public static func unpairMessage(deleted: [String]) -> String {
        let removed =
            deleted.isEmpty
            ? "There was no device token in the login keychain."
            : "Deleted the device token from the login keychain ("
                + deleted.map { "\"\($0)\"" }.joined(separator: " and ") + ")."
        return removed
            + " reMarkable still lists the device on your account:"
            + " remove the desktop-macos device on my.remarkable.com to revoke its token."
    }
}
