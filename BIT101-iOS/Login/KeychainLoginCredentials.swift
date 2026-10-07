import Foundation
import OSLog
import Security

/// Keychain 的生产适配器，服务名由 App 组装入口选择。
final class KeychainLoginCredentials: LoginCredentialsStoring {
    private static let logger = Logger(subsystem: "BIT101", category: "LoginKeychain")
    private let service: String

    init(service: String) { self.service = service }

    @discardableResult
    func deleteAll() -> Bool {
        Self.keychainDeleteSucceeded(status: SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary))
    }

    func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw LoginServiceError.keychainWriteFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw LoginServiceError.keychainWriteFailed(addStatus)
        }
    }

    func read(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return ""
        }

        guard status == errSecSuccess else {
            throw LoginServiceError.keychainReadFailed(status)
        }

        guard
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw LoginServiceError.invalidServerResponse
        }

        return value
    }

    @discardableResult
    func delete(account: String) -> Bool {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard Self.keychainDeleteSucceeded(status: status) else {
            Self.logger.error("Keychain delete failed account=\(account, privacy: .public) status=\(status)")
            return false
        }
        return true
    }

    nonisolated static func keychainDeleteSucceeded(status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
