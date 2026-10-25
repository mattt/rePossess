import Foundation

/// The claims of a device or user token that the client uses.
///
/// The client reads the payload without checking the signature;
/// it only needs the device ID, the sync region, and the expiry.
/// The profile claim, which can hold an email address, is not read.
public struct TokenClaims: Sendable, Equatable {
    /// The `device-id` claim: the UUID sent at registration
    /// (rmapi-js `src/index.ts` lines 517-533).
    public var deviceID: String?
    /// The `device-desc` claim, such as `desktop-macos`.
    public var deviceDescription: String?
    /// The `tectonic` claim, such as `eu` (rmfakecloud `internal/app/claims.go`).
    public var tectonic: String?
    /// The `scopes` claim, a space-separated list.
    public var scopes: String?
    /// The `exp` claim.
    public var expiration: Date?

    /// Decodes the payload of a JWT.
    public init(jwt: String) throws {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw CloudError.malformedToken }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CloudError.malformedToken }
        deviceID = object["device-id"] as? String
        deviceDescription = object["device-desc"] as? String
        tectonic = object["tectonic"] as? String
        scopes = object["scopes"] as? String
        if let exp = object["exp"] as? NSNumber {
            expiration = Date(timeIntervalSince1970: exp.doubleValue)
        }
    }
}
