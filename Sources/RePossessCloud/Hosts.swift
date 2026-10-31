import Foundation

/// The hosts of reMarkable's cloud.
///
/// Sources: rmapi-js `src/index.ts` lines 177-179 (commit 824f0ad),
/// and ddvk/rmapi `config/url.go` (commit aa60dac), read for behavior only.
public enum CloudHosts {
    /// The host for device registration and user tokens.
    public static let auth = URL(string: "https://webapp-prod.cloud.remarkable.engineering")!

    /// The sync host that rmapi-js uses by default.
    public static let defaultSync = URL(string: "https://eu.tectonic.remarkable.com")!

    /// The page that gives a one-time code for a desktop app (rmapi-js `README.md`).
    public static let connectPage = URL(string: "https://my.remarkable.com/device/desktop/connect")!

    /// The sync host that ddvk/rmapi and remarkable-mcp use.
    public static let legacySync = URL(string: "https://internal.cloud.remarkable.com")!

    /// Returns the sync host for a user token.
    ///
    /// A user token can carry a `tectonic` claim, such as `eu`
    /// (rmfakecloud `internal/app/claims.go`, read for behavior only).
    /// Mapping the claim to `https://<claim>.tectonic.remarkable.com`
    /// comes from the host template `{}.tectonic.remarkable.com` reported in ddvk/rmapi issue 66;
    /// a live run checked it for the claim `eu` on 2026-10-25.
    /// Without a usable claim, this returns ``defaultSync``.
    public static func sync(for claims: TokenClaims?) -> URL {
        guard let region = claims?.tectonic, isRegionLabel(region) else {
            return defaultSync
        }
        return URL(string: "https://\(region).tectonic.remarkable.com")!
    }

    /// Returns whether a URL points at one of reMarkable's domains over HTTPS.
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return host.hasSuffix(".remarkable.com") || host.hasSuffix(".remarkable.engineering")
    }

    static func isRegionLabel(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32
            && value.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
    }
}
