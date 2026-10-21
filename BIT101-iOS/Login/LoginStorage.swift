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
        static let revokedSession = "login.session.revoked"
    }

    private enum KeychainAccount {
        static let session = "login.session"
        static let studentID = "login.sid"
        static let password = "login.password"
        static let fakeCookie = "login.fakeCookie"
    }

    private struct Session: Codable {
        var studentID: String
        var password: String
        var fakeCookie: String
        var communityPasswordDigest: String? = nil
    }

    private let defaults: UserDefaults
    private let credentials: any LoginCredentialsStoring
    private let clearSchoolCookies: () -> Void
    private let requestSchoolPassword: @MainActor (String) async throws -> String
    private let schoolPasswordRequests = CommunitySessionRefreshCoordinator()
    let communityRefreshCoordinator = CommunitySessionRefreshCoordinator()
    private var sessionGeneration = 0
    private var session = Session(studentID: "", password: "", fakeCookie: "")
    private var sessionReadError: (any Error)?
    var credentialReadIssue: String? { sessionReadError?.localizedDescription }
    private let changeSubject = PassthroughSubject<CommunitySessionIdentity, Never>()
    var changes: AnyPublisher<CommunitySessionIdentity, Never> { changeSubject.eraseToAnyPublisher() }
    private let credentialsSubject = PassthroughSubject<CommunityCredentials, Never>()
    var credentialsChanges: AnyPublisher<CommunityCredentials, Never> { credentialsSubject.eraseToAnyPublisher() }

    var schoolSessionIdentity: SchoolSessionIdentity {
        .init(accountIdentifier: currentStudentID, generation: sessionGeneration)
    }

    var communityCredentials: CommunityCredentials {
        CommunityCredentials(identity: CommunitySessionIdentity(accountIdentifier: currentStudentID, generation: sessionGeneration), cookie: fakeCookie)
    }

    init(defaults: UserDefaults, credentials: any LoginCredentialsStoring, clearSchoolCookies: @escaping () -> Void,
         requestSchoolPassword: @escaping @MainActor (String) async throws -> String = { _ in
             throw LoginServiceError.schoolCredentialsRequired
         }) {
        self.defaults = defaults
        self.credentials = credentials
        self.clearSchoolCookies = clearSchoolCookies
        self.requestSchoolPassword = requestSchoolPassword
        purgePersistedCredentialsIfNeededAfterReinstall()
        migrateLegacyFakeCookieIfNeeded()
        migrateLegacySessionIfNeeded()
        if defaults.string(forKey: DefaultsKey.revokedSession) != "all" {
            do { try restoreSession(publishChange: false) }
            catch { Self.logger.error("Session credentials await a successful read") }
        }
    }

    /// 发布所选凭据存储的账号与代际，供生命周期协调器重载账号数据。
    private func notifyAccountChanged() {
        changeSubject.send(communityCredentials.identity)
        credentialsSubject.send(communityCredentials)
    }

    /// BIT101 自有登录态使用的 fake-cookie。
    var fakeCookie: String {
        guard defaults.object(forKey: DefaultsKey.revokedSession) == nil else { return "" }
        return session.fakeCookie
    }

    /// 当前本地保存的学号。
    var currentStudentID: String {
        guard defaults.string(forKey: DefaultsKey.revokedSession) != "all" else { return "" }
        return session.studentID
    }

    /// 当前本地保存的密码。
    var currentPassword: String {
        guard defaults.object(forKey: DefaultsKey.revokedSession) == nil else { return "" }
        return session.password
    }

    /// 读取本地保存的完整学号和密码组合。
    func loadCredentials() throws -> StoredCredentials? {
        guard defaults.object(forKey: DefaultsKey.revokedSession) == nil else { return nil }
        if sessionReadError != nil { try restoreSession() }
        let saved = session
        let studentID = saved.studentID
        let password = saved.password

        guard !studentID.isEmpty, !password.isEmpty else {
            return nil
        }

        return StoredCredentials(studentID: studentID, password: password)
    }

    func loadCommunityPasswordDigest() throws -> String? {
        guard defaults.object(forKey: DefaultsKey.revokedSession) == nil else { return nil }
        if sessionReadError != nil { try restoreSession() }
        return session.communityPasswordDigest
    }

    func retrySessionReadIfNeeded() {
        guard sessionReadError != nil, defaults.object(forKey: DefaultsKey.revokedSession) == nil else { return }
        do { try restoreSession() }
        catch { Self.logger.error("Session credentials await a successful read") }
    }

    func prepareSchoolCredentials() async throws { try await requestSchoolCredentials(force: false) }

    func updateSchoolCredentials() async throws { try await requestSchoolCredentials(force: true) }

    /// 学校功能按需收集密码，账号内的并发请求共用同一次输入。
    private func requestSchoolCredentials(force: Bool) async throws {
        try Task.checkCancellation()
        let owner = schoolSessionIdentity
        guard !owner.accountIdentifier.isEmpty, !fakeCookie.isEmpty else { throw LoginServiceError.schoolCredentialsRequired }
        if !force, !currentPassword.isEmpty { return }
        try await schoolPasswordRequests.refresh(identity: .init(accountIdentifier: owner.accountIdentifier, generation: owner.generation)) { [self] in
            let password = try await requestSchoolPassword(owner.accountIdentifier)
            try Task.checkCancellation()
            guard schoolSessionIdentity == owner else { throw CancellationError() }
            guard !password.isEmpty else { throw LoginServiceError.schoolCredentialsRequired }
            var updated = session
            updated.password = password
            try saveSession(updated)
            clearSchoolCookies()
        }
        try Task.checkCancellation()
        guard schoolSessionIdentity == owner else { throw CancellationError() }
    }

    /// 保存登录成功后的本地会话。
    ///
    /// 这里保存可长期复用的账号密码和当前 fake-cookie。
    /// 应用重启后可以直接进入主界面，并在需要时于后台静默重登学校 SSO。
    func saveLoginState(studentID: String, password: String, fakeCookie: String, communityPasswordDigest: String? = nil) throws {
        let normalizedStudentID = studentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFakeCookie = fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = communityPasswordDigest ?? (currentStudentID == normalizedStudentID ? session.communityPasswordDigest : nil)
        guard !normalizedStudentID.isEmpty, !password.isEmpty || digest?.isEmpty == false else {
            throw LoginServiceError.invalidCredentials
        }
        guard !normalizedFakeCookie.isEmpty else {
            throw LoginServiceError.invalidServerResponse
        }

        let accountChanged = currentStudentID != normalizedStudentID || self.fakeCookie.isEmpty
        try saveSession(Session(studentID: normalizedStudentID, password: password, fakeCookie: normalizedFakeCookie,
            communityPasswordDigest: digest))
        defaults.set(true, forKey: DefaultsKey.installationMarker)
        defaults.removeObject(forKey: DefaultsKey.revokedSession)
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        retireLegacyCredentials()
        if accountChanged {
            schoolPasswordRequests.cancel()
            clearSchoolCookies()
            sessionGeneration &+= 1
            notifyAccountChanged()
        } else {
            credentialsSubject.send(communityCredentials)
        }
    }

    /// 清除当前会话和已保存密码，保留学号供下次输入。
    ///
    /// 这是“退出登录并保留学号”的语义，适用于远端会话失效后快速回到未登录态。
    func clearSession() {
        schoolPasswordRequests.cancel()
        let studentID = currentStudentID
        let revoked = defaults.string(forKey: DefaultsKey.revokedSession) == "all" ? "all" : "logout"
        defaults.set(revoked, forKey: DefaultsKey.revokedSession)
        session = Session(studentID: studentID, password: "", fakeCookie: "")
        sessionGeneration &+= 1
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        do {
            try saveSession(Session(studentID: studentID, password: "", fakeCookie: ""))
        } catch {
            Self.logger.error("Revoked session credential cleanup remains pending")
        }
        retireLegacyCredentials()

        // 清理学校身份相关域，保留 App 内其他服务和调试环境的 Cookie。
        clearSchoolCookies()
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
        schoolPasswordRequests.cancel()
        session = Session(studentID: "", password: "", fakeCookie: "")
        sessionReadError = nil
        defaults.set("all", forKey: DefaultsKey.revokedSession)
        defaults.removeObject(forKey: DefaultsKey.fakeCookie)
        let didDeleteSession = credentials.delete(account: KeychainAccount.session)
        let didDeleteFakeCookie = credentials.delete(account: KeychainAccount.fakeCookie)
        clearSchoolCookies()
        let didDeleteStudentID = credentials.delete(account: KeychainAccount.studentID)
        let didDeletePassword = credentials.delete(account: KeychainAccount.password)
        return didDeleteSession && didDeleteFakeCookie && didDeleteStudentID && didDeletePassword
    }

    /// 将 `UserDefaults` 中的共享 fake-cookie 迁入账号对应的 Keychain 项。
    private func migrateLegacyFakeCookieIfNeeded() {
        guard defaults.object(forKey: DefaultsKey.revokedSession) == nil else {
            defaults.removeObject(forKey: DefaultsKey.fakeCookie)
            return
        }
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

    private func readSession() throws -> Session {
        let value = try credentials.read(account: KeychainAccount.session)
        if !value.isEmpty { return try JSONDecoder().decode(Session.self, from: Data(value.utf8)) }
        return Session(studentID: try credentials.read(account: KeychainAccount.studentID),
                       password: try credentials.read(account: KeychainAccount.password),
                       fakeCookie: try credentials.read(account: KeychainAccount.fakeCookie))
    }

    private func restoreSession(publishChange: Bool = true) throws {
        do {
            let previousCredentials = communityCredentials
            let previousAccount = currentStudentID
            session = try readSession()
            if defaults.object(forKey: DefaultsKey.revokedSession) != nil {
                session.password = ""
                session.fakeCookie = ""
                session.communityPasswordDigest = nil
            }
            sessionReadError = nil
            if publishChange, previousAccount != currentStudentID {
                sessionGeneration &+= 1
                clearSchoolCookies()
                notifyAccountChanged()
            } else if publishChange, previousCredentials != communityCredentials {
                credentialsSubject.send(communityCredentials)
            }
        } catch {
            sessionReadError = error
            throw error
        }
    }

    private func saveSession(_ value: Session) throws {
        let data = try JSONEncoder().encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else { throw LoginServiceError.invalidServerResponse }
        try credentials.save(encoded, account: KeychainAccount.session)
        session = value
        sessionReadError = nil
    }

    private func migrateLegacySessionIfNeeded() {
        guard defaults.object(forKey: DefaultsKey.revokedSession) == nil,
              defaults.object(forKey: DefaultsKey.fakeCookie) == nil else { return }
        do {
            guard try credentials.read(account: KeychainAccount.session).isEmpty else { return }
            let value = try readSession()
            guard !value.studentID.isEmpty || !value.password.isEmpty || !value.fakeCookie.isEmpty else { return }
            try saveSession(value)
            retireLegacyCredentials()
        } catch {
            Self.logger.error("Session credential migration remains pending")
        }
    }

    private func retireLegacyCredentials() {
        let cleared = [KeychainAccount.studentID, KeychainAccount.password, KeychainAccount.fakeCookie]
            .map { credentials.delete(account: $0) }.allSatisfy { $0 }
        if !cleared { Self.logger.error("Legacy credential cleanup remains pending") }
    }

    func preservingLoginMarkers(_ clearPreferences: () -> Void) {
        let revoked = defaults.string(forKey: DefaultsKey.revokedSession)
        let installed = defaults.object(forKey: DefaultsKey.installationMarker) as? Bool
        clearPreferences()
        if let revoked { defaults.set(revoked, forKey: DefaultsKey.revokedSession) }
        if let installed { defaults.set(installed, forKey: DefaultsKey.installationMarker) }
    }

}
