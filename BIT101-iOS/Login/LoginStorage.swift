//
//  LoginStorage.swift
//  BIT101-iOS
//

import Foundation
import OSLog
import Security

/// 登录状态存储。
///
/// 学号、密码和 fake-cookie 存入 Keychain，安装标记存入 `UserDefaults`，学校 cookie 由系统 `HTTPCookieStorage` 管理。
final class LoginStorage {
    static let shared = LoginStorage()
    private static let logger = Logger(subsystem: "BIT101", category: "LoginStorage")

    private enum DefaultsKey {
        static let fakeCookie = "login.fakeCookie"
        static let installationMarker = "login.installationMarker"
    }

    private enum KeychainAccount {
        static let studentID = "login.sid"
        static let password = "login.password"
        static let fakeCookie = "login.fakeCookie"
    }

    private let keychainService = "harrybit.BIT101-iOS.login"
    private let defaults = UserDefaults.standard
    private init() {
        purgePersistedCredentialsIfNeededAfterReinstall()
        migrateLegacyFakeCookieIfNeeded()
    }

    /// 通知全局“当前账号相关数据已变化”。
    ///
    /// 账号切换时，课表缓存、小组件和设置隔离通过这条通知刷新。
    private func notifyAccountChanged() {
        NotificationCenter.default.post(name: .loginStorageDidChange, object: nil)
    }

    /// BIT101 自有登录态使用的 fake-cookie。
    var fakeCookie: String {
        (try? readKeychainValue(account: KeychainAccount.fakeCookie)) ?? ""
    }

    /// 当前本地保存的学号。
    var currentStudentID: String {
        (try? readKeychainValue(account: KeychainAccount.studentID)) ?? ""
    }

    /// 当前本地保存的密码。
    var currentPassword: String {
        (try? readKeychainValue(account: KeychainAccount.password)) ?? ""
    }

    /// 读取本地保存的完整学号和密码组合。
    func loadCredentials() throws -> StoredCredentials? {
        let studentID = try readKeychainValue(account: KeychainAccount.studentID)
        let password = try readKeychainValue(account: KeychainAccount.password)

        guard !studentID.isEmpty, !password.isEmpty else {
            return nil
        }

        return StoredCredentials(studentID: studentID, password: password)
    }

    /// 保存登录成功后的本地会话。
    ///
    /// 这里保存可长期复用的账号密码和当前 fake-cookie。
    /// 应用重启后可以直接进入主界面，并在需要时于后台静默重登学校 SSO。
    func saveLoginState(studentID: String, password: String, fakeCookie: String) throws {
        let normalizedStudentID = studentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFakeCookie = fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedStudentID.isEmpty, !password.isEmpty else {
            throw LoginServiceError.invalidCredentials
        }
        guard !normalizedFakeCookie.isEmpty else {
            throw LoginServiceError.invalidServerResponse
        }

        try saveKeychainValue(normalizedStudentID, account: KeychainAccount.studentID)
        try saveKeychainValue(password, account: KeychainAccount.password)
        try saveKeychainValue(normalizedFakeCookie, account: KeychainAccount.fakeCookie)
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        notifyAccountChanged()
    }

    /// 清除当前会话和已保存密码，保留学号供下次输入。
    ///
    /// 这是“退出登录并保留学号”的语义，适用于远端会话失效后快速回到未登录态。
    func clearSession() {
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        deleteKeychainValue(account: KeychainAccount.fakeCookie)

        // 清理学校身份相关域，保留 App 内其他服务和调试环境的 Cookie。
        TeachingCenterSessionState.shared.clearSchoolAuthenticationCookies()
        deleteKeychainValue(account: KeychainAccount.password)
        notifyAccountChanged()
    }

    /// 删除客户端本地保存的所有登录相关数据。
    ///
    /// 这是清除全部本地登录数据的语义，同时删除 Keychain 中的学号和密码。
    func clearAllLocalData() {
        clearPersistedLoginData()
        notifyAccountChanged()
    }

    /// 检测首次安装标记，并在登录页读取本地凭据前清理 Keychain 中的学号和密码。
    ///
    /// 卸载时系统会清除 `UserDefaults`，Keychain 通常会保留数据。
    /// 安装标记缺失时，当前启动进入首次安装初始化流程。
    private func purgePersistedCredentialsIfNeededAfterReinstall() {
        guard !defaults.bool(forKey: DefaultsKey.installationMarker) else { return }

        clearPersistedLoginData()
        defaults.set(true, forKey: DefaultsKey.installationMarker)
    }

    private func clearPersistedLoginData() {
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        deleteKeychainValue(account: KeychainAccount.fakeCookie)
        TeachingCenterSessionState.shared.clearSchoolAuthenticationCookies()
        deleteKeychainValue(account: KeychainAccount.studentID)
        deleteKeychainValue(account: KeychainAccount.password)
    }

    /// 将 `UserDefaults` 中的共享 fake-cookie 迁入账号对应的 Keychain 项。
    private func migrateLegacyFakeCookieIfNeeded() {
        guard let legacyFakeCookie = defaults.string(forKey: DefaultsKey.fakeCookie) else { return }
        guard !legacyFakeCookie.isEmpty else {
            defaults.removeObject(forKey: DefaultsKey.fakeCookie)
            return
        }

        do {
            let currentFakeCookie = try readKeychainValue(account: KeychainAccount.fakeCookie)
            if !currentFakeCookie.isEmpty {
                defaults.removeObject(forKey: DefaultsKey.fakeCookie)
                return
            }

            try saveKeychainValue(legacyFakeCookie, account: KeychainAccount.fakeCookie)
            defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        } catch {
            // 迁移写入失败时保留来源数据，供下一次启动重试。
            Self.logger.error("Legacy fake-cookie migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveKeychainValue(_ value: String, account: String) throws {
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

    private func readKeychainValue(account: String) throws -> String {
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

    private func deleteKeychainValue(account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }
}
