import Foundation

/// Storage follows the installed app, independently of its display name or signing team.
enum ApplicationIdentity {
    // Compatibility exception for installations that already have a route library here.
    static let legacyBundleIdentifier =
        Bundle.main.object(forInfoDictionaryKey: "FixBridgeLegacyBundleIdentifier") as? String
    static let currentIdentifier = Bundle.main.bundleIdentifier ?? "FixBridge.unbundled"

    static func storageDirectory(
        for identifier: String, legacyIdentifier: String? = legacyBundleIdentifier
    ) -> String {
        if let legacyIdentifier, !legacyIdentifier.isEmpty, identifier == legacyIdentifier { return "FixBridge" }
        // Bundle IDs normally contain only ASCII letters, digits, dots and hyphens.
        // Encode unexpected input instead of allowing path traversal or collisions.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        if !identifier.isEmpty, identifier != ".", identifier != "..",
            identifier.unicodeScalars.allSatisfy({ allowed.contains($0) })
        {
            return "FixBridge-" + identifier
        }
        return "identity-" + identifier.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
