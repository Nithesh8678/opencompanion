import Foundation
#if canImport(Security)
import Security
#endif

public enum CredentialStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidIdentifier
    case unavailable
    case keychainStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "A credential requires a service and account identifier."
        case .unavailable: "Secure credential storage is unavailable on this platform."
        case let .keychainStatus(status): "Keychain could not complete the request (status \(status))."
        }
    }
}

/// Credentials are stored as generic passwords in the user's Keychain. This
/// type never logs identifiers, values, or query dictionaries.
public final class CredentialStore: Sendable {
    public init() {}

    public func save(_ data: Data, service: String, account: String) throws {
        try validate(service: service, account: account)
        #if canImport(Security)
        let query = query(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw CredentialStoreError.keychainStatus(result) }
        } else if update != errSecSuccess {
            throw CredentialStoreError.keychainStatus(update)
        }
        #else
        throw CredentialStoreError.unavailable
        #endif
    }

    public func load(service: String, account: String) throws -> Data? {
        try validate(service: service, account: account)
        #if canImport(Security)
        var lookup = query(service: service, account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(lookup as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess else { throw CredentialStoreError.keychainStatus(result) }
        guard let data = value as? Data else { throw CredentialStoreError.keychainStatus(errSecDecode) }
        return data
        #else
        throw CredentialStoreError.unavailable
        #endif
    }

    public func delete(service: String, account: String) throws {
        try validate(service: service, account: account)
        #if canImport(Security)
        let result = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CredentialStoreError.keychainStatus(result) }
        #else
        throw CredentialStoreError.unavailable
        #endif
    }

    private func validate(service: String, account: String) throws {
        guard !service.isEmpty, !account.isEmpty else { throw CredentialStoreError.invalidIdentifier }
    }

    #if canImport(Security)
    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    #endif
}
