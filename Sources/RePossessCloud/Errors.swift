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
    /// The Keychain did not give the device token in time, most likely because macOS
    /// is waiting for the user to allow the read.
    case keychainTimedOut
    /// A one-time code did not have eight letters or digits.
    case invalidCode
    /// A device token is already stored, so pairing again would add a second device.
    case alreadyPaired(service: String)
    /// The server refused to register the device.
    case registrationRefused(status: Int, message: String)
    /// The root changed between the read and the update, so the update did not happen.
    case generationConflict
    /// An upload could not be planned, so nothing was sent.
    case invalidUpload(String)
    /// The root update got no answer, and a new read of the root does not list the document,
    /// so the update did not happen.
    case rootUpdateNotApplied(String)

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
            "no device token in the login keychain under the service \"\(service)\"; run `repossess pair` first"
        case .keychain(let status, let message): "Keychain error \(status): \(message)"
        case .keychainTimedOut:
            "macOS did not give rePossess the device token in time; it may be asking for permission. "
                + "Run `repossess check-token` in Terminal and choose Always Allow, then try again."
        case .invalidCode:
            "a one-time code has eight letters or digits; get one from \(CloudHosts.connectPage.absoluteString)"
        case .alreadyPaired(let service):
            "rePossess is already paired: the login keychain has a device token under \"\(service)\". "
                + "Run `repossess unpair` first to pair again."
        case .registrationRefused(let status, let message):
            "reMarkable refused the one-time code (HTTP \(status): \(message)). "
                + "Get a new code from \(CloudHosts.connectPage.absoluteString) and try again."
        case .generationConflict: "the cloud root changed during the upload; read the root again and plan again"
        case .invalidUpload(let reason): "cannot plan the upload: \(reason)"
        case .rootUpdateNotApplied(let reason):
            "the root update got no answer (\(reason)), and the cloud root does not list the document"
        }
    }

    /// Maps a failed response to an error.
    ///
    /// A generation conflict on a root update is HTTP 412 in rmfakecloud and ddvk/rmapi,
    /// and the body `{"message":"precondition failed"}` in rmapi-js (`src/index.ts` line 808).
    static func from(_ response: HTTPResponse) -> CloudError {
        if response.status == 412 || response.text.contains("precondition failed") {
            return .generationConflict
        }
        if response.status == 401 || response.status == 403 {
            return .unauthorized(status: response.status)
        }
        return .http(status: response.status, message: String(response.text.prefix(300)))
    }
}
