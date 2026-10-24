import Foundation
import LocalAuthentication
import MarmotKit
import Security

/// Account-ID keyed credentials for the separate development application.
nonisolated final class SyncDevelopmentSecretStore: SecretStore {
    let service: String

    init(service: String = "com.marmot.whitenoise.syncdev") {
        self.service = service
    }

    func hasSecretForLabel(label: String) throws -> Bool { false }
    func hasSecretForAccountId(accountIdHex: String) throws -> Bool {
        var query = accountQuery(accountIdHex)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    func writeSecret(label: String, accountIdHex: String, secretKeyHex: String) throws {
        let query = accountQuery(accountIdHex)
        let attributes = [kSecValueData as String: Data(secretKeyHex.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else {
            try check(status)
            return
        }
        var item = query
        item[kSecValueData as String] = attributes[kSecValueData as String]
        let inserted = SecItemAdd(item as CFDictionary, nil)
        if inserted == errSecDuplicateItem {
            // Another worker created this same account credential after our update.
            try check(SecItemUpdate(query as CFDictionary, attributes as CFDictionary))
        } else {
            try check(inserted)
        }
    }

    func loadSecret(label: String, accountIdHex: String) throws -> String {
        var query = accountQuery(accountIdHex)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw MarmotKitError.SecretNotFound(details: "Development credential not found")
        }
        try check(status)
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw MarmotKitError.KeystoreUnavailable(details: "Invalid development credential encoding")
        }
        return secret
    }

    func removeSecret(label: String, accountIdHex: String) throws {
        let status = SecItemDelete(accountQuery(accountIdHex) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    func purgeAllAccountKeys() throws {
        try MarmotAccountKeychain.purgeAllAccountKeys(service: service)
    }

    func accountQuery(_ accountIdHex: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountIdHex,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw MarmotKitError.KeystoreUnavailable(details: "Development Keychain operation failed (\(status))")
        }
    }
}
