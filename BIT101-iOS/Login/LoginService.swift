//
//  LoginService.swift
//  BIT101-iOS
//

import Foundation
import Combine
import ClientCore
import CommunityTransport
import TransportCore

/// 登录业务门面。
///
/// ViewModel 通过此门面使用学校 CAS、BIT101 注册和本地持久化能力。
struct LoginService {
    private let storage: LoginStorage
    private let apiClient: BIT101APIClient
    var sessionChanges: AnyPublisher<Void, Never> { storage.changes.map { _ in () }.eraseToAnyPublisher() }

    init() { self.init(storage: AppAccountSession.storage, apiClient: .shared) }

    /// 独立实例由调用方共同提供凭据存储与 API 客户端。
    init(storage: LoginStorage, apiClient: BIT101APIClient) {
        self.storage = storage
        self.apiClient = apiClient
    }

    /// 当前本地保存的学号。
    var savedStudentID: String {
        storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 当前本地保存的密码。
    var savedPassword: String {
        storage.currentPassword
    }

    /// 表示本地会话是否足以支撑“乐观进入主界面”。
    ///
    /// 该属性读取本地会话状态；远端有效性由后台异步校验。
    var hasCachedSession: Bool {
        storage.hasCachedSession
    }

    /// 校验当前本地会话是否仍然有效。
    ///
    /// 这条检查由启动后台校验、设置页手动检查和日程同步前置校验共同调用，
    /// 负责确认 BIT101 自有会话并返回当前学号。学校 SSO 会话按需通过
    /// `restoreSchoolSessionIfNeeded()` 恢复。
    ///
    /// 远端返回会话过期时共享社区凭据恢复，凭据遭拒时转入社区重新认证；错误沿调用链抛出，
    /// 本地数据继续支撑主 App、watch 和 widget 的当前登录展示。
    func checkLogin() async throws -> String? {
        let fakeCookie = storage.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fakeCookie.isEmpty else {
            if storage.hasCachedSession { throw CommunitySessionRestorationError.credentialsRejected }
            return nil
        }

        // 社区在线会话独立校验，学校 SSO 由各学校功能按需恢复。
        let observed = storage.communityCredentials
        let bit101LoggedIn = try await apiClient.checkBIT101Login(fakeCookie: fakeCookie)
        try Task.checkCancellation()
        guard storage.communityCredentials.identity == observed.identity,
              storage.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines) == fakeCookie
        else { throw CancellationError() }
        guard bit101LoggedIn else {
            try await renewCommunitySession(observed: observed)
            return savedStudentID
        }

        let studentID = savedStudentID
        guard !studentID.isEmpty else {
            storage.clearSession()
            return nil
        }
        return studentID
    }

    /// 负责确保学校 SSO 会话可用，BIT101 自有 fake-cookie 由 `checkLogin()` 校验。
    ///
    /// 空教室这类纯学校接口沿学校会话路径查询，完整登录检查会增加查询等待时间。
    func restoreSchoolSessionIfNeeded() async throws -> String? {
        let owner = storage.schoolSessionIdentity
        try await storage.schoolSessionRecovery.refresh(identity: owner) {
            do { _ = try await restoreSchoolSession() }
            catch LoginServiceError.schoolPasswordRejected {
                try await storage.updateSchoolCredentials()
                _ = try await restoreSchoolSession()
            }
        }
        try Task.checkCancellation()
        guard storage.schoolSessionIdentity == owner else { throw CancellationError() }
        return savedStudentID
    }

    private func restoreSchoolSession() async throws -> String? {
        try await storage.prepareSchoolCredentials()
        let identity = storage.schoolSessionIdentity
        let schoolContext = try await apiClient.fetchSchoolLoginContext()
        try Task.checkCancellation()
        guard storage.schoolSessionIdentity == identity else { throw CancellationError() }
        if schoolContext.isLoggedIn {
            let studentID = savedStudentID
            if studentID.isEmpty {
                throw LoginServiceError.unableToRestoreSchoolSession
            }
            return studentID
        }

        guard let credentials = try storage.loadCredentials() else {
            throw LoginServiceError.unableToRestoreSchoolSession
        }

        guard
            let salt = schoolContext.salt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !salt.isEmpty,
            let execution = schoolContext.execution?.trimmingCharacters(in: .whitespacesAndNewlines),
            !execution.isEmpty
        else {
            throw LoginServiceError.invalidSchoolLoginPage
        }

        let studentID = credentials.studentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !studentID.isEmpty else {
            throw LoginServiceError.unableToRestoreSchoolSession
        }

        let reloginSucceeded = try await apiClient.loginSchool(
            studentID: studentID,
            password: credentials.password,
            salt: salt,
            execution: execution
        )

        try Task.checkCancellation()
        guard storage.schoolSessionIdentity == identity else { throw CancellationError() }
        guard reloginSucceeded else {
            throw LoginServiceError.schoolLoginFailed
        }
        return studentID
    }

    /// 社区密码优先走账号登录，学校身份验证承接账号缺失与凭据恢复。
    func login(studentID: String, password: String) async throws -> String {
        let account = studentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !password.isEmpty else { throw LoginServiceError.invalidCredentials }
        let identity = storage.communityCredentials.identity
        let digest = LoginCrypto.md5Hex(password)
        var response: RegisterResponse
        var schoolPassword = storage.currentStudentID == account ? storage.currentPassword : ""
        var validatedDigest: String?
        do {
            response = try await apiClient.loginCommunity(studentID: account, passwordDigest: digest)
            validatedDigest = digest
            if schoolPassword.isEmpty { schoolPassword = password }
        } catch LoginServiceError.invalidCredentials {
            // 服务端共用账号缺失与密码错误响应，学校证明交由 login_mode 保留已有密码。
            schoolPassword = try await storage.schoolPasswordForIdentityVerification(studentID: account)
            try validateCommunityIdentity(identity)
            response = try await authenticateSchoolIdentity(studentID: account, password: schoolPassword,
                communityPasswordDigest: digest)
            do {
                response = try await apiClient.loginCommunity(studentID: account, passwordDigest: digest)
                validatedDigest = digest
            } catch {
                if TaskCancellation.matches(error) { throw error }
                // 学校证明取得的社区会话继续使用，已验证的密码摘要按原归属保留。
            }
        }
        try validateCommunityIdentity(identity)
        try storage.saveLoginState(studentID: account, password: schoolPassword, fakeCookie: response.fakeCookie,
            communityPasswordDigest: validatedDigest)
        return account
    }

    private func validateCommunityIdentity(_ identity: CommunitySessionIdentity) throws {
        try Task.checkCancellation()
        guard storage.communityCredentials.identity == identity else { throw CancellationError() }
    }

    func sendRegistrationEmail(studentID: String) async throws -> String {
        let response = try await apiClient.mailVerify(studentID: studentID)
        guard !response.token.isEmpty else { throw LoginServiceError.invalidServerResponse }
        return response.token
    }

    func verifyRegistrationIdentity(studentID: String, password: String) async throws -> WebVPNVerifyResponse {
        let context = try await apiClient.webVPNVerifyInit(studentID: studentID)
        guard context.captcha.isEmpty else { throw LoginServiceError.schoolCaptchaRequired }
        return try await apiClient.webVPNVerify(studentID: studentID,
            password: LoginCrypto.encryptPassword(password, saltBase64: context.salt),
            execution: context.execution, cookie: context.cookie, salt: context.salt)
    }

    func registerAccount(studentID: String, password: String, token: String, code: String, schoolPassword: String?) async throws {
        let identity = storage.communityCredentials.identity
        let digest = LoginCrypto.md5Hex(password)
        let response = try await apiClient.register(password: digest, token: token, code: code, loginMode: false)
        try Task.checkCancellation()
        guard storage.communityCredentials.identity == identity else { throw CancellationError() }
        let existingSchoolPassword = storage.currentStudentID == studentID ? storage.currentPassword : ""
        let savedSchoolPassword = schoolPassword ?? (existingSchoolPassword.isEmpty ? password : existingSchoolPassword)
        try storage.saveLoginState(studentID: studentID, password: savedSchoolPassword, fakeCookie: response.fakeCookie,
            communityPasswordDigest: digest)
    }

    /// 认证恢复在保存前核对账号归属，网络和取消错误沿原语义返回。
    func renewCommunitySession(observed: CommunityCredentials) async throws {
        try await storage.communityRefreshCoordinator.refresh(observed: observed, current: { storage.communityCredentials }) {
            do { try await authenticateCommunitySession(expectedIdentity: observed.identity) }
            catch CommunitySessionRestorationError.credentialsRejected {
                try Task.checkCancellation()
                guard storage.communityCredentials == observed else { throw CancellationError() }
                storage.requireCommunityAuthentication()
                throw CommunitySessionRestorationError.credentialsRejected
            }
        }
    }

    /// 社区重新认证保留同一账号的学校凭据与本机数据归属。
    func restoreCommunitySession(password: String) async throws {
        guard storage.hasCachedSession, !password.isEmpty else { throw LoginServiceError.invalidCredentials }
        let identity = storage.communityCredentials.identity
        let digest = LoginCrypto.md5Hex(password)
        let response = try await apiClient.loginCommunity(studentID: identity.accountIdentifier, passwordDigest: digest)
        try Task.checkCancellation()
        guard storage.communityCredentials.identity == identity else { throw CancellationError() }
        try storage.saveLoginState(studentID: identity.accountIdentifier, password: storage.currentPassword,
            fakeCookie: response.fakeCookie, communityPasswordDigest: digest)
    }

    private func authenticateCommunitySession(expectedIdentity: CommunitySessionIdentity) async throws {
        guard storage.communityCredentials.identity == expectedIdentity else { throw CancellationError() }
        if let digest = try storage.loadCommunityPasswordDigest() {
            let account = storage.currentStudentID
            let response: RegisterResponse
            do { response = try await apiClient.loginCommunity(studentID: account, passwordDigest: digest) }
            catch let error as LoginServiceError where error.isCredentialFailure {
                throw CommunitySessionRestorationError.credentialsRejected
            }
            try Task.checkCancellation()
            guard storage.communityCredentials.identity == expectedIdentity else { throw CancellationError() }
            try storage.saveLoginState(studentID: account, password: storage.currentPassword,
                fakeCookie: response.fakeCookie, communityPasswordDigest: digest)
            return
        }
        guard let credentials = try storage.loadCredentials() else {
            throw CommunitySessionRestorationError.credentialsRejected
        }
        let digest = LoginCrypto.md5Hex(credentials.password)
        let response: RegisterResponse
        var validatedDigest: String?
        do {
            response = try await apiClient.loginCommunity(studentID: credentials.studentID, passwordDigest: digest)
            validatedDigest = digest
        } catch LoginServiceError.invalidCredentials {
            do {
                response = try await authenticateSchoolIdentity(studentID: credentials.studentID,
                    password: credentials.password, communityPasswordDigest: digest)
            } catch let error as LoginServiceError where error.isCredentialFailure {
                throw CommunitySessionRestorationError.credentialsRejected
            }
        }
        try validateCommunityIdentity(expectedIdentity)
        try storage.saveLoginState(studentID: credentials.studentID, password: credentials.password,
            fakeCookie: response.fakeCookie, communityPasswordDigest: validatedDigest)
    }

    private func authenticateSchoolIdentity(studentID: String, password: String,
        communityPasswordDigest: String) async throws -> RegisterResponse {
        let identity = storage.communityCredentials.identity
        let proof = try await verifyRegistrationIdentity(studentID: studentID, password: password)
        try validateCommunityIdentity(identity)
        return try await apiClient.register(password: communityPasswordDigest, token: proof.token,
            code: proof.code, loginMode: true)
    }

    /// 清除当前登录会话。
    func logout() {
        storage.clearSession()
    }
}
