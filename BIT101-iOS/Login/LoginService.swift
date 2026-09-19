//
//  LoginService.swift
//  BIT101-iOS
//

import Foundation

/// 登录业务门面。
///
/// ViewModel 通过此门面使用学校 CAS、BIT101 注册和本地持久化能力。
struct LoginService {
    private let storage: LoginStorage
    private let apiClient: BIT101APIClient

    /// 支持注入存储与 API 客户端。
    init(storage: LoginStorage = .shared, apiClient: BIT101APIClient = .shared) {
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
        let fakeCookie = storage.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        return !fakeCookie.isEmpty && !savedStudentID.isEmpty
    }

    /// 校验当前本地会话是否仍然有效。
    ///
    /// 这条检查由启动后台校验、设置页手动检查和日程同步前置校验共同调用，
    /// 负责确认 BIT101 自有会话并返回当前学号。学校 SSO 会话按需通过
    /// `restoreSchoolSessionIfNeeded()` 恢复。
    ///
    /// 远端明确返回当前会话失效时清除本地 session；网络错误沿调用链抛出，
    /// 本地数据继续支撑主 App、watch 和 widget 的当前登录展示。
    func checkLogin() async throws -> String? {
        let fakeCookie = storage.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fakeCookie.isEmpty else {
            return nil
        }

        // App 的全局登录态依赖 BIT101 自有 fake-cookie。
        // 学校 SSO 服务课表、空教室等按需功能，App 进入流程以 BIT101 fake-cookie 校验为准。
        let bit101LoggedIn = try await apiClient.checkBIT101Login(fakeCookie: fakeCookie)
        guard bit101LoggedIn else {
            storage.clearSession()
            return nil
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
        let schoolContext = try await apiClient.fetchSchoolLoginContext()
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

        guard reloginSucceeded else {
            throw LoginServiceError.schoolLoginFailed
        }
        return studentID
    }

    /// 执行 BIT101 登录流程：WebVPN 身份校验 -> 登录模式注册。
    ///
    /// WebVPN 校验由 BIT101 后端完成，足以证明学号身份并签发 fake-cookie；手机本地的
    /// 学校 SSO Cookie 由需要学校身份的功能按需获取，App 登录链路与学校 CAS 版本变化保持隔离。
    func login(studentID: String, password: String) async throws -> String {
        let normalizedStudentID = studentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedStudentID.isEmpty, !password.isEmpty else {
            throw LoginServiceError.invalidCredentials
        }

        // 与 BIT101-GO 的现有接口保持一致：初始化验证上下文 -> 校验 WebVPN -> 登录模式注册。
        let initResponse = try await apiClient.webVPNVerifyInit(studentID: normalizedStudentID)
        let encryptedPassword = try LoginCrypto.encryptPassword(password, saltBase64: initResponse.salt)
        let verifyResponse = try await apiClient.webVPNVerify(
            studentID: normalizedStudentID,
            password: encryptedPassword,
            execution: initResponse.execution,
            cookie: initResponse.cookie,
            salt: initResponse.salt
        )
        let md5Password = LoginCrypto.md5Hex(password)
        let registerResponse = try await apiClient.register(
            password: md5Password,
            token: verifyResponse.token,
            code: verifyResponse.code
        )

        let fakeCookie = registerResponse.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fakeCookie.isEmpty else {
            throw LoginServiceError.invalidServerResponse
        }

        try storage.saveLoginState(
            studentID: normalizedStudentID,
            password: password,
            fakeCookie: fakeCookie
        )

        return normalizedStudentID
    }

    /// 清除当前登录会话。
    func logout() {
        storage.clearSession()
    }
}
