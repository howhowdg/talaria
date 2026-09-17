import Foundation
import Security

/// Only connection tokens live here. Agent/provider secrets stay on the Hermes host.
public struct CredentialStore: Sendable {
    private let service: String
    public init(service: String = "com.talaria.gateway") { self.service = service }
    public func read(account: String) throws -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError(status: status) }
        return String(data: data, encoding: .utf8)
    }
    public func save(_ token: String, account: String) throws {
        guard !token.isEmpty else { try delete(account: account); return }
        let data = Data(token.utf8)
        let status = SecItemUpdate(base(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = base(account)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw StoreError(status: added) }
        } else if status != errSecSuccess { throw StoreError(status: status) }
    }
    public func delete(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
    }
    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public struct StoreError: LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? { "Keychain could not access the connection credential (\(status))." }
    }
}
