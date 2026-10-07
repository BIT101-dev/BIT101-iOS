//
//  LoginStorage.swift
//  BIT101-iOS
//

import Foundation
import OSLog
import Combine
import ClientCore
import CommunityTransport

/// 凭据读写通过所选后端执行，账号变化由 LoginStorage 发布。
protocol LoginCredentialsStoring {
    func read(account: String) throws -> String
    func save(_ value: String, account: String) throws
    @discardableResult func delete(account: String) -> Bool
}

/// 登录状态存储。
///
/// 学号、密码和 fake-cookie 存入 Keychain，安装标记存入 `UserDefaults`，学校 cookie 由系统 `HTTPCookieStorage` 管理。
final class LoginStorage: SchoolCredentialsProviding {
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

    private let defaults: UserDefaults
    private let credentials: any LoginCredentialsStoring
    private let clearSchoolCookies: () -> Void
    private var sessionGeneration = 0
    private let changeSubject = PassthroughSubject<CommunitySessionIdentity, Never>()
    var changes: AnyPublisher<CommunitySessionIdentity, Never> { changeSubject.eraseToAnyPublisher() }

    var communityCredentials: CommunityCredentials {
        CommunityCredentials(identity: CommunitySessionIdentity(accountIdentifier: currentStudentID, generation: sessionGeneration), cookie: fakeCookie)
    }

    init(defaults: UserDefaults, credentials: any LoginCredentialsStoring, clearSchoolCookies: @escaping () -> Void) {
        self.defaults = defaults
        self.credentials = credentials
        self.clearSchoolCookies = clearSchoolCookies
        purgePersistedCredentialsIfNeededAfterReinstall()
        migrateLegacyFakeCookieIfNeeded()
    }

    /// 发布所选凭据存储的账号与代际，供生命周期协调器重载账号数据。
    private func notifyAccountChanged() {
        changeSubject.send(communityCredentials.identity)
    }

    /// BIT101 自有登录态使用的 fake-cookie。
    var fakeCookie: String {
        (try? credentials.read(account: KeychainAccount.fakeCookie)) ?? ""
    }

    /// 当前本地保存的学号。
    var currentStudentID: String {
        (try? credentials.read(account: KeychainAccount.studentID)) ?? ""
    }

    /// 当前本地保存的密码。
    var currentPassword: String {
        (try? credentials.read(account: KeychainAccount.password)) ?? ""
    }

    /// 读取本地保存的完整学号和密码组合。
    func loadCredentials() throws -> StoredCredentials? {
        let studentID = try credentials.read(account: KeychainAccount.studentID)
        let password = try credentials.read(account: KeychainAccount.password)

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

        let accountChanged = currentStudentID != normalizedStudentID || self.fakeCookie.isEmpty
        try credentials.save(normalizedStudentID, account: KeychainAccount.studentID)
        try credentials.save(password, account: KeychainAccount.password)
        try credentials.save(normalizedFakeCookie, account: KeychainAccount.fakeCookie)
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        if accountChanged {
            sessionGeneration &+= 1
            notifyAccountChanged()
        }
    }

    /// 清除当前会话和已保存密码，保留学号供下次输入。
    ///
    /// 这是“退出登录并保留学号”的语义，适用于远端会话失效后快速回到未登录态。
    func clearSession() {
        sessionGeneration &+= 1
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        _ = credentials.delete(account: KeychainAccount.fakeCookie)

        // 清理学校身份相关域，保留 App 内其他服务和调试环境的 Cookie。
        clearSchoolCookies()
        _ = credentials.delete(account: KeychainAccount.password)
        notifyAccountChanged()
    }

    /// 删除客户端本地保存的所有登录相关数据。
    ///
    /// 这是清除全部本地登录数据的语义，同时删除 Keychain 中的学号和密码。
    @discardableResult
    func clearAllLocalData() -> Bool {
        sessionGeneration &+= 1
        let didClear = clearPersistedLoginData()
        notifyAccountChanged()
        return didClear
    }

    /// 检测首次安装标记，并在登录页读取本地凭据前清理 Keychain 中的学号和密码。
    ///
    /// 卸载时系统会清除 `UserDefaults`，Keychain 通常会保留数据。
    /// 安装标记缺失时，当前启动进入首次安装初始化流程。
    private func purgePersistedCredentialsIfNeededAfterReinstall() {
        guard !defaults.bool(forKey: DefaultsKey.installationMarker) else { return }

        guard clearPersistedLoginData() else {
            Self.logger.error("Keychain cleanup after reinstall remains pending")
            return
        }
        defaults.set(true, forKey: DefaultsKey.installationMarker)
    }

    @discardableResult
    private func clearPersistedLoginData() -> Bool {
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        let didDeleteFakeCookie = credentials.delete(account: KeychainAccount.fakeCookie)
        clearSchoolCookies()
        let didDeleteStudentID = credentials.delete(account: KeychainAccount.studentID)
        let didDeletePassword = credentials.delete(account: KeychainAccount.password)
        return didDeleteFakeCookie && didDeleteStudentID && didDeletePassword
    }

    /// 将 `UserDefaults` 中的共享 fake-cookie 迁入账号对应的 Keychain 项。
    private func migrateLegacyFakeCookieIfNeeded() {
        guard let legacyFakeCookie = defaults.string(forKey: DefaultsKey.fakeCookie) else { return }
        guard !legacyFakeCookie.isEmpty else {
            defaults.removeObject(forKey: DefaultsKey.fakeCookie)
            return
        }

        do {
            let currentFakeCookie = try credentials.read(account: KeychainAccount.fakeCookie)
            if !currentFakeCookie.isEmpty {
                defaults.removeObject(forKey: DefaultsKey.fakeCookie)
                return
            }

            try credentials.save(legacyFakeCookie, account: KeychainAccount.fakeCookie)
            defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        } catch {
            // 迁移写入失败时保留来源数据，供下一次启动重试。
            Self.logger.error("Legacy fake-cookie migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

}
