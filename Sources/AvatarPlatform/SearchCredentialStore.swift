import Foundation
import Security

public protocol SearchCredentialStore: Sendable {
    /// Reads the provider key when a search starts. Implementations must not cache it.
    func apiKey() throws -> String?
}

public enum SearchCredentialStoreError: Error, Equatable, Sendable {
    case unreadableValue
    case keychainStatus(OSStatus)
}

/// On-demand read access to a generic-password item in the macOS Keychain.
public struct KeychainSearchCredentialStore: SearchCredentialStore {
    public static let defaultService = "com.ospa.avatar-companion.web-search"
    public static let defaultAccount = "brave-api-key"

    private let service: String
    private let account: String

    public init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func apiKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                let value = String(data: data, encoding: .utf8),
                !value.isEmpty
            else {
                throw SearchCredentialStoreError.unreadableValue
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SearchCredentialStoreError.keychainStatus(status)
        }
    }
}
