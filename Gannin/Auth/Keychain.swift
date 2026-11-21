import Foundation
import Security

/// Generic passwords in the login keychain: the GitHub access token, and the
/// sandbox's credentials (`SandboxCredentials`), each under its own service
/// and account. The demo build never touches it: it reads nothing and
/// writes nothing.
nonisolated enum Keychain {
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
        if NetworkGate.isSealed { return nil }
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

    /// Whether an item is there, without reading its secret: only the
    /// attributes are asked for, so there's no access prompt to wait on. For
    /// a check made while drawing or deciding, where `value` could block on
    /// one.
    nonisolated static func exists(service: String, account: String) -> Bool {
        if NetworkGate.isSealed { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    nonisolated static func setValue(_ value: String, service: String, account: String) {
        if NetworkGate.isSealed { return }
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
        if NetworkGate.isSealed { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
