import Foundation
import Security

enum KeychainStore {
    private static let defaultService: String = Bundle.main.bundleIdentifier ?? "io.palmier.pro"

    static func save(_ value: String, account: String) {
        try? save(value, account: account, service: defaultService)
    }

    static func save(_ value: String, account: String, service: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attrs) { _, new in new }
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw KeychainStoreError.status(insertStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainStoreError.status(status)
        }
    }

    static func load(account: String) -> String? {
        try? load(account: account, service: defaultService)
    }

    static func load(account: String, service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.status(status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw KeychainStoreError.invalidData
        }
        return value
    }

    static func delete(account: String) {
        try? delete(account: account, service: defaultService)
    }

    static func delete(account: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.status(status)
        }
    }
}

enum KeychainStoreError: LocalizedError {
    case invalidData
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "The Keychain item contains invalid data."
        case .status(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain operation failed (\(status))."
        }
    }
}
