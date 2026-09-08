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
        storage.currentStudentID
    }

    /// 当前本地保存的密码。
    var savedPassword: String {
        storage.currentPassword
    }

    /// 表示本地会话是否足以支撑“乐观进入主界面”。
    ///
    /// 该属性读取本地会话状态；远端有效性由后台异步校验。
    var hasCachedSession: Bool {
        !storage.fakeCookie.isEmpty && !savedStudentID.isEmpty
    }

    /// 校验当前本地会话是否仍然有效。
    ///
    /// 如有必要，会尝试使用已保存的账号密码静默重登学校 SSO。
    ///
    /// 这条检查由启动后台校验、设置页手动检查和日程同步前置校验共同调用。
    /// 清退策略保持保守，远端明确说明当前凭据无效时清除本地 session。
    /// 网络不稳、学校登录页结构异常、缺少静默恢复材料等情况向上抛错，同时保留
    /// `fake-cookie`，让主 App、watch 和 widget 保持当前登录展示。
    func checkLogin() async throws -> String? {
        let fakeCookie = storage.fakeCookie
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

        let studentID = storage.currentStudentID
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
            let studentID = storage.currentStudentID
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

        let reloginSucceeded = try await apiClient.loginSchool(
            studentID: credentials.studentID,
            password: credentials.password,
            salt: salt,
            execution: execution
        )

        return reloginSucceeded ? credentials.studentID : nil
    }

    /// 执行 BIT101 登录流程：WebVPN 身份校验 -> 登录模式注册。
    ///
    /// WebVPN 校验由 BIT101 后端完成，足以证明学号身份并签发 fake-cookie；手机本地的
    /// 学校 SSO Cookie 由需要学校身份的功能按需获取，App 登录链路与学校 CAS 版本变化保持隔离。
    func login(studentID: String, password: String) async throws -> String {
        storage.clearSession()

        // 与 BIT101-GO 的现有接口保持一致：初始化验证上下文 -> 校验 WebVPN -> 登录模式注册。
        let initResponse = try await apiClient.webVPNVerifyInit(studentID: studentID)
        let encryptedPassword = try LoginCrypto.encryptPassword(password, saltBase64: initResponse.salt)
        let verifyResponse = try await apiClient.webVPNVerify(
            studentID: studentID,
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

        try storage.saveLoginState(
            studentID: studentID,
            password: password,
            fakeCookie: registerResponse.fakeCookie
        )

        return studentID
    }

    /// 清除当前登录会话。
    func logout() {
        storage.clearSession()
    }
}
