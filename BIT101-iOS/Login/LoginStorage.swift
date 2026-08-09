//
//  LoginStorage.swift
//  BIT101-iOS
//

import Foundation
import Security

/// 登录状态存储。
///
/// 学号和密码进 Keychain，fake-cookie 和登录标记进 `UserDefaults`，学校 cookie 放系统 `HTTPCookieStorage`。
final class LoginStorage {
    static let shared = LoginStorage()

    private enum DefaultsKey {
        static let fakeCookie = "login.fakeCookie"
        static let installationMarker = "login.installationMarker"
    }

    private enum KeychainAccount {
        static let studentID = "login.sid"
        static let password = "login.password"
    }

    private let keychainService = "harrybit.BIT101-iOS.login"
    private let defaults = UserDefaults.standard
    private init() {
        purgePersistedCredentialsIfNeededAfterReinstall()
    }

    /// 通知全局“当前账号相关数据已变化”。
    ///
    /// 课表缓存、小组件、设置隔离等都依赖这条通知做账号切换刷新。
    private func notifyAccountChanged() {
        NotificationCenter.default.post(name: .loginStorageDidChange, object: nil)
    }

    /// BIT101 自有登录态使用的 fake-cookie。
    var fakeCookie: String {
        defaults.string(forKey: DefaultsKey.fakeCookie) ?? ""
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
    /// 这里既保存可长期复用的账号密码，也保存当前 fake-cookie。这样应用重启后既可以
    /// 直接乐观进入主界面，又能在后台必要时静默重登学校 SSO。
    func saveLoginState(studentID: String, password: String, fakeCookie: String) throws {
        try saveKeychainValue(studentID, account: KeychainAccount.studentID)
        try saveKeychainValue(password, account: KeychainAccount.password)
        defaults.set(fakeCookie, forKey: DefaultsKey.fakeCookie)
        notifyAccountChanged()
    }

    /// 清理当前会话，并清掉已保存密码，但保留学号，方便下次重新输入。
    ///
    /// 这是“退出登录但不清空学号”的语义，主要用于发现远端会话失效时快速回到未登录态。
    func clearSession() {
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)

        // 只清理学校身份相关域，避免把 App 内其他服务或调试环境的 Cookie 一并删除。
        TeachingCenterSessionState.shared.clearSchoolAuthenticationCookies()
        deleteKeychainValue(account: KeychainAccount.password)
        notifyAccountChanged()
    }

    /// 删除客户端本地保存的所有登录相关数据。
    ///
    /// 这是更彻底的“清文稿与数据”语义，会同时抹掉 Keychain 中的账号密码。
    func clearAllLocalData() {
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        TeachingCenterSessionState.shared.clearSchoolAuthenticationCookies()
        deleteKeychainValue(account: KeychainAccount.studentID)
        deleteKeychainValue(account: KeychainAccount.password)
        notifyAccountChanged()
    }

    /// 检测“卸载重装后的首次启动”，并在登录页读取本地凭据前清掉残留 Keychain。
    ///
    /// `UserDefaults` 会在卸载时被系统清掉，而 Keychain 通常会保留。
    /// 因此只要发现安装标记缺失，就说明这是一次全新安装或重装后的首次启动，
    /// 需要把上一个安装遗留的学号密码一起抹掉，避免登录界面先闪出旧账号。
    private func purgePersistedCredentialsIfNeededAfterReinstall() {
        guard !defaults.bool(forKey: DefaultsKey.installationMarker) else { return }

        defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        TeachingCenterSessionState.shared.clearSchoolAuthenticationCookies()
        deleteKeychainValue(account: KeychainAccount.studentID)
        deleteKeychainValue(account: KeychainAccount.password)
        defaults.set(true, forKey: DefaultsKey.installationMarker)
    }

    private func saveKeychainValue(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw LoginServiceError.keychainWriteFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
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
