import Foundation
import Security
import HermesTransport

/// Only gateway credentials live here. Agent/provider secrets stay on the Hermes host.
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

extension CredentialStore {
    private struct BoundCredential<Value: Codable>: Codable {
        let baseURL: URL
        let ssh: GatewaySSHDestination?
        let value: Value
    }

    func readSession(for endpoint: GatewayEndpoint) throws -> GatewaySessionSnapshot? {
        try readBound(GatewaySessionSnapshot.self, account: "basic." + endpoint.id.uuidString, endpoint: endpoint)
    }
    func saveSession(_ snapshot: GatewaySessionSnapshot, for endpoint: GatewayEndpoint) throws {
        try saveBound(snapshot, account: "basic." + endpoint.id.uuidString, endpoint: endpoint)
    }
    func deleteSession(for endpoint: GatewayEndpoint) throws {
        try delete(account: "basic." + endpoint.id.uuidString)
    }
    func readToken(for endpoint: GatewayEndpoint, legacyEndpoint: GatewayEndpoint?) throws -> String? {
        if let token = try readBound(String.self, account: "token." + endpoint.id.uuidString, endpoint: endpoint) { return token }
        // Legacy UUID accounts have no origin binding; only their saved endpoint proves ownership.
        guard legacyEndpoint?.id == endpoint.id, legacyEndpoint?.baseURL == endpoint.baseURL,
              legacyEndpoint?.authentication == .sessionToken, endpoint.ssh == nil else { return nil }
        return try read(account: endpoint.id.uuidString)
    }
    func saveToken(_ token: String, for endpoint: GatewayEndpoint) throws {
        try saveBound(token, account: "token." + endpoint.id.uuidString, endpoint: endpoint)
        try delete(account: endpoint.id.uuidString)
    }
    func deleteToken(for endpoint: GatewayEndpoint) throws {
        try delete(account: "token." + endpoint.id.uuidString)
        try delete(account: endpoint.id.uuidString)
    }
    private func readBound<Value: Codable>(_ type: Value.Type, account: String, endpoint: GatewayEndpoint) throws -> Value? {
        guard let raw = try read(account: account) else { return nil }
        let saved = try JSONDecoder().decode(BoundCredential<Value>.self, from: Data(raw.utf8))
        return saved.baseURL == endpoint.baseURL && saved.ssh == endpoint.ssh ? saved.value : nil
    }
    private func saveBound<Value: Codable>(_ value: Value, account: String, endpoint: GatewayEndpoint) throws {
        let data = try JSONEncoder().encode(BoundCredential(baseURL: endpoint.baseURL, ssh: endpoint.ssh, value: value))
        try save(String(decoding: data, as: UTF8.self), account: account)
    }
}
