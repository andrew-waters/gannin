import Foundation
import Security

/// Generic passwords in the login keychain: the GitHub access token, and the
/// sandbox's credentials (`SandboxCredentials`), each under its own service
/// and account.
enum Keychain {
    private static let service = "dev.andon.gannin.github"
    private static let account = "access_token"

    static func token() -> String? {
        value(service: service, account: account)
    }

    static func setToken(_ value: String) {
        setValue(value, service: service, account: account)
    }

    /// The token kept under an older service name, moved to this one when
    /// there's none here yet. The old item belonged to the app under its
    /// old bundle ID, so the keychain may ask to allow it once.
    static func moveToken(fromService old: String) {
        guard token() == nil, let value = value(service: old, account: account) else { return }
        setToken(value)
    }

    static func clearToken() {
        clear(service: service, account: account)
    }

    // MARK: Any item

    nonisolated static func value(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    nonisolated static func setValue(_ value: String, service: String, account: String) {
        clear(service: service, account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    nonisolated static func clear(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
