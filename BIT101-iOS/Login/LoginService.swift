//
//  LoginService.swift
//  BIT101-iOS
//

import Foundation

/// 登录业务门面。
///
/// ViewModel 不直接关心学校 CAS、BIT101 注册和本地持久化细节，统一通过这里调度。
struct LoginService {
    private let storage: LoginStorage
    private let apiClient: BIT101APIClient

    /// 允许注入存储和 API 客户端，方便测试或将来替换实现。
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

    /// 是否存在足以支撑“乐观进入主界面”的本地会话。
    ///
    /// 这里只做本地判断，不代表远端一定仍然有效；真正校验仍然放到后台异步完成。
    var hasCachedSession: Bool {
        !storage.fakeCookie.isEmpty && !savedStudentID.isEmpty
    }

    /// 校验当前本地会话是否仍然有效。
    ///
    /// 如有必要，会尝试使用已保存的账号密码静默重登学校 SSO。
    ///
    /// 这条检查会被启动后台校验、设置页手动检查和日程同步前置校验共同调用，
    /// 因此清退策略必须保守：只有远端明确说明当前凭据已经无效时才清掉本地 session。
    /// 网络不稳、学校登录页结构异常、缺少静默恢复材料等情况只向上抛错，不删除
    /// `fake-cookie`，避免把一次临时故障扩散成主 App / watch / widget 全部退出登录。
    func checkLogin() async throws -> String? {
        let fakeCookie = storage.fakeCookie
        guard !fakeCookie.isEmpty else {
            return nil
        }

        // App 的全局登录态只由 BIT101 自己的 fake-cookie 决定。
        // 学校 SSO 是课表、空教室等功能的按需依赖，不能因为学校 CAS 改版而阻止用户进入 App。
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

    /// 只确保学校 SSO 会话可用，不检查 BIT101 自有 fake-cookie。
    ///
    /// 空教室这类纯学校接口不需要先访问 BIT101 后端；把完整登录检查放在前置路径上
    /// 会明显拖慢查询速度。
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
    /// 学校 SSO Cookie 留给真正需要它的功能按需获取，避免学校 CAS 改版拖垮整个 App 登录。
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

    /// 退出登录并清掉当前会话。
    func logout() {
        storage.clearSession()
    }
}
