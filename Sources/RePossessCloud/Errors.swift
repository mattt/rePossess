import Foundation

/// The errors of the cloud client.
public enum CloudError: Error, Equatable, CustomStringConvertible {
    /// A request named a host outside reMarkable's domains.
    case hostNotAllowed(String)
    /// The response was not an HTTP response.
    case notHTTP
    /// The server rejected the token.
    case unauthorized(status: Int)
    /// The server returned another failure.
    case http(status: Int, message: String)
    /// A string was not a 64-digit hex hash.
    case invalidHash(String)
    /// An index file could not be parsed.
    case malformedIndex(String)
    /// A JSON response could not be decoded.
    case malformedResponse(String)
    /// Downloaded bytes did not match their hash.
    case hashMismatch(expected: String, actual: String)
    /// A token was not a JWT with a readable payload.
    case malformedToken
    /// There is no device token in the Keychain.
    case notPaired(service: String)
    /// The Keychain refused to give the device token.
    case keychain(status: Int32, message: String)

    public var description: String {
        switch self {
        case .hostNotAllowed(let host): "refused to contact \(host): not a reMarkable host"
        case .notHTTP: "the response was not HTTP"
        case .unauthorized(let status):
            "reMarkable's cloud rejected the device token (HTTP \(status)); the pairing may have been removed"
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .invalidHash(let hash): "not a hash: \(hash)"
        case .malformedIndex(let reason): "malformed index: \(reason)"
        case .malformedResponse(let reason): "malformed response: \(reason)"
        case .hashMismatch(let expected, let actual): "hash mismatch: expected \(expected), got \(actual)"
        case .malformedToken: "the token is not a JWT"
        case .notPaired(let service):
            "no device token in the login keychain under the service \"\(service)\"; pair rePossess first"
        case .keychain(let status, let message): "Keychain error \(status): \(message)"
        }
    }

    /// Maps a failed response to an error.
    static func from(_ response: HTTPResponse) -> CloudError {
        if response.status == 401 || response.status == 403 {
            return .unauthorized(status: response.status)
        }
        return .http(status: response.status, message: String(response.text.prefix(300)))
    }
}
