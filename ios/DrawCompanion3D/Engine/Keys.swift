import Foundation
import Security

/// API keys for on-device generation, kept in the Keychain.
///
/// For development, a `DevKeys.plist` dropped into the app folder (git-ignored;
/// `scripts/ios-dev-keys.sh` writes it from the repo's `.env`) is imported into
/// the Keychain on first launch, so you don't have to type keys on the phone.
/// Anyone with the app binary can read a bundled key: don't distribute such builds.
enum Keys {
    static let anthropic = "anthropic-api-key"
    static let meshy = "meshy-api-key"
    /// Optional: ElevenLabs voices for the characters (otherwise iOS's own).
    static let elevenLabs = "elevenlabs-api-key"
    private static let service = "DrawCompanion"

    static func value(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static var haveBoth: Bool { value(anthropic) != nil && value(meshy) != nil }

    /// Imports keys from a bundled DevKeys.plist into the Keychain (dev builds only).
    static func importBundledDevKeys() {
        guard let url = Bundle.main.url(forResource: "DevKeys", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: String]
        else { return }
        if let a = dict["ANTHROPIC_API_KEY"], !a.isEmpty, value(anthropic) != a { set(a, for: anthropic) }
        if let m = dict["MESHY_API_KEY"], !m.isEmpty, value(meshy) != m { set(m, for: meshy) }
        if let e = dict["ELEVENLABS_API_KEY"], !e.isEmpty, value(elevenLabs) != e { set(e, for: elevenLabs) }
    }
}
