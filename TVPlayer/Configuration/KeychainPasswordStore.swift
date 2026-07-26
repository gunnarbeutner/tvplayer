import Foundation
import Security

protocol PasswordStoring {
    func read(account: String) -> String
    func write(_ password: String, account: String) throws
    func delete(account: String)
}

struct KeychainPasswordStore: PasswordStoring {
    private let service = "de.beutner.TVPlayer.tvheadend"
    static let legacyAccount = "default-server"

    func read(account: String = Self.legacyAccount) -> String {
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
              let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
    }

    func write(_ password: String, account: String = Self.legacyAccount) throws {
        if password.isEmpty {
            delete(account: account)
            return
        }

        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(password.utf8)
        let status = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if status == errSecItemNotFound {
            var item = lookup
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw error(for: addStatus) }
        } else if status != errSecSuccess {
            throw error(for: status)
        }
    }

    func delete(account: String = Self.legacyAccount) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func error(for status: OSStatus) -> ConfigurationError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .keychain(message)
    }
}
