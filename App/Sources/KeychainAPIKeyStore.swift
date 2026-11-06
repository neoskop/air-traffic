import AirTrafficCore
import Foundation
import Security

/// OpenRouter-API-Key im Schlüsselbund (Generic Password, §12.1). Nie in `config.json`, nie im Log.
struct KeychainAPIKeyStore: APIKeyStore {
    static let defaultService = "de.neoskop.AirTraffic"
    static let defaultAccount = "openrouter-api-key"

    let service: String
    let account: String

    init(service: String = KeychainAPIKeyStore.defaultService, account: String = KeychainAPIKeyStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Schlüsselbund: \(message)"
        }
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    func readKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Nur Attribute abfragen – liest das Passwort nicht und fragt daher nicht nach.
    func hasKey() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    func saveKey(_ key: String) throws {
        let data = Data(key.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery
            add[kSecValueData] = data
            add[kSecAttrLabel] = "Air Traffic – OpenRouter-API-Key"
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        default:
            throw KeychainError(status: update)
        }
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
