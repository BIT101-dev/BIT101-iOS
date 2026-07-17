//
//  LoginService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import CommonCrypto
import CryptoKit
import Foundation
import Security

// MARK: - URL Upgrade

/// 学校 SSO 存在从 HTTPS 跳回 HTTP 的历史问题。
///
/// iOS 的 ATS 不允许这类明文跳转，所以这里统一在客户端把目标地址升级回 HTTPS。
private enum LoginURLUpgrade {
    /// 把学校偶发返回的 HTTP 跳转地址升级成 HTTPS。
    nonisolated static func upgradedURL(from url: URL) -> URL {
        guard url.scheme?.lowercased() == "http" else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }

    /// 根据响应头里的 `Location` 字段解析下一跳地址，并补做 HTTPS 升级。
    nonisolated static func resolvedURL(from location: String, relativeTo baseURL: URL) -> URL? {
        if let absolute = URL(string: location) {
            return upgradedURL(from: absolute)
        }

        return URL(string: location, relativeTo: baseURL).map(upgradedURL(from:))
    }
}

/// 本地保存的登录凭据。
///
/// 这里只保存“足以静默重登学校 SSO”的最小信息组合，不额外混入 fake-cookie 等会话态。
struct StoredCredentials {
    let studentID: String
    let password: String
}

/// 教学中心 WebVPN 会话的进程内状态。
///
/// 这里不再使用“成功一次后永久为 true”的静态布尔值，而是把状态绑定到具体学号，
/// 并且每次使用前同时检查对应 Cookie 是否仍然存在。网络层发现会话失效时可以显式
/// 调用 `invalidate`，下一次请求就会重新经过 bit-login。
final class TeachingCenterSessionState {
    static let shared = TeachingCenterSessionState()

    private let lock = NSLock()
    private let cookieStorage = HTTPCookieStorage.shared
    private var authenticatedStudentID: String?
    private var preparedStudentID: String?

    private init() {}

    func hasUsableSession(for studentID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !studentID.isEmpty else { return false }
        guard hasWebVPNCookie else {
            authenticatedStudentID = nil
            preparedStudentID = nil
            return false
        }

        // App 重启后内存标记会消失，但系统 Cookie 仍可能有效。登录流程在切换账号前会
        // 清掉学校 Cookie，因此这里可以把现存 Cookie 重新绑定到当前保存的学号。
        if authenticatedStudentID == nil {
            authenticatedStudentID = studentID
        }
        return authenticatedStudentID == studentID
    }

    func markAuthenticated(for studentID: String) {
        lock.lock()
        authenticatedStudentID = studentID
        preparedStudentID = nil
        lock.unlock()
    }

    func isPrepared(for studentID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return authenticatedStudentID == studentID && preparedStudentID == studentID && hasWebVPNCookie
    }

    func markPrepared(for studentID: String) {
        lock.lock()
        if authenticatedStudentID == studentID, hasWebVPNCookie {
            preparedStudentID = studentID
        }
        lock.unlock()
    }

    /// 使内存状态失效，并按需只删除教学中心/WebVPN 域的 Cookie。
    func invalidate(clearCookies: Bool = true) {
        lock.lock()
        authenticatedStudentID = nil
        preparedStudentID = nil
        lock.unlock()

        guard clearCookies else { return }
        deleteCookies(matching: [
            "webvpn.bit.edu.cn",
            "jxzxehall.bit.edu.cn",
            "jxzxehallapp.bit.edu.cn",
        ])
    }

    /// 退出、重新登录或切换账号时清理学校身份相关 Cookie，但不影响其他网站 Cookie。
    func clearSchoolAuthenticationCookies() {
        invalidate(clearCookies: false)
        deleteCookies(matching: [
            "webvpn.bit.edu.cn",
            "sso.bit.edu.cn",
            "jxzxehall.bit.edu.cn",
            "jxzxehallapp.bit.edu.cn",
            "jwms.bit.edu.cn",
            "lexue.bit.edu.cn",
        ])
    }

    private var hasWebVPNCookie: Bool {
        let now = Date()
        return cookieStorage.cookies?.contains { cookie in
            normalizedDomain(cookie.domain) == "webvpn.bit.edu.cn"
                && (cookie.expiresDate == nil || cookie.expiresDate! > now)
        } ?? false
    }

    private func deleteCookies(matching domains: Set<String>) {
        cookieStorage.cookies?.forEach { cookie in
            let domain = normalizedDomain(cookie.domain)
            if domains.contains(where: { domain == $0 || domain.hasSuffix(".\($0)") }) {
                cookieStorage.deleteCookie(cookie)
            }
        }
    }

    private func normalizedDomain(_ domain: String) -> String {
        domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }
}

/// 从学校登录页里解析出来的必要上下文。
///
/// 学校 CAS 登录页并不是一个稳定 JSON 接口，而是一段 HTML，所以这里先把后续登录真正
/// 需要的字段提炼成一个小结构体，供业务层继续往下传。
struct SchoolLoginContext {
    let salt: String?
    let execution: String?
    let isLoggedIn: Bool
}

/// 登录链路中的统一错误定义。
enum LoginServiceError: LocalizedError {
    case invalidSchoolLoginPage
    case schoolLoginFailed
    case unableToRestoreSchoolSession
    case invalidServerResponse
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidSchoolLoginPage:
            return "学校登录页结构发生变化，暂时无法完成登录。"
        case .schoolLoginFailed:
            return "学校统一身份认证登录失败，请检查学号和密码。"
        case .unableToRestoreSchoolSession:
            return "学校登录状态已过期，且缺少可用于静默恢复的本地凭据。"
        case .invalidServerResponse:
            return "服务器返回了无法识别的数据。"
        case let .keychainWriteFailed(status):
            return "无法保存登录信息（Keychain 状态码: \(status)）。"
        case let .keychainReadFailed(status):
            return "无法读取登录信息（Keychain 状态码: \(status)）。"
        }
    }
}

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

/// Android 端登录流程依赖的加密算法。
///
/// iOS 端为了兼容现有后端和学校登录链路，需要严格复刻 Android 端的密码处理逻辑。
enum LoginCrypto {
    /// 复刻 Android 端的 AES 加密逻辑，用于学校登录表单和 WebVPN 校验。
    static func encryptPassword(_ password: String, saltBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: saltBase64) else {
            throw LoginServiceError.invalidSchoolLoginPage
        }

        let inputData = Data(password.utf8)
        var outputData = Data(count: inputData.count + kCCBlockSizeAES128)
        let outputBufferSize = outputData.count
        var outputLength: size_t = 0

        let status = outputData.withUnsafeMutableBytes { outputBytes in
            inputData.withUnsafeBytes { inputBytes in
                keyData.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        keyData.count,
                        nil,
                        inputBytes.baseAddress,
                        inputData.count,
                        outputBytes.baseAddress,
                        outputBufferSize,
                        &outputLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw LoginServiceError.invalidSchoolLoginPage
        }

        outputData.count = outputLength
        return outputData.base64EncodedString()
    }

    /// 登录模式注册接口要求密码先转成 MD5 十六进制字符串。
    static func md5Hex(_ value: String) -> String {
        Insecure.MD5
            .hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// 从学校 CAS 登录页 HTML 中抽取 salt 和 execution。
///
/// 学校登录页不是稳定 API，因此这层解析需要尽量宽松，只抽真正必要的几个字段。
enum SchoolLoginHTMLParser {
    /// 从学校 CAS 登录页 HTML 中提取 salt、execution 和“是否已登录”状态。
    static func parse(html: String) -> SchoolLoginContext {
        SchoolLoginContext(
            salt: value(in: html, pattern: #"id=["']login-croypto["'][^>]*>\s*([^<\s]+)\s*<"#),
            execution: value(in: html, pattern: #"id=["']login-page-flowkey["'][^>]*>\s*([^<\s]+)\s*<"#),
            isLoggedIn: !html.contains("用户名密码")
        )
    }

    /// 使用正则从 HTML 中提取单个字段值。
    private static func value(in html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(html.startIndex..., in: html)
        guard
            let match = regex.firstMatch(in: html, options: [], range: range),
            let captureRange = Range(match.range(at: 1), in: html)
        else {
            return nil
        }

        return String(html[captureRange])
    }
}

/// WebVPN 校验初始化请求体。
fileprivate struct WebVPNVerifyInitRequest: Encodable {
    let sid: String
}

/// WebVPN 校验初始化响应。
fileprivate struct WebVPNVerifyInitResponse: Decodable {
    let captcha: String
    let cookie: String
    let execution: String
    let salt: String
}

/// WebVPN 校验请求体。
fileprivate struct WebVPNVerifyRequest: Encodable {
    let sid: String
    let password: String
    let execution: String
    let cookie: String
    let salt: String
    let captcha: String
}

/// WebVPN 校验结果。
fileprivate struct WebVPNVerifyResponse: Decodable {
    let token: String
    let code: String
}

/// BIT101 登录模式注册请求体。
fileprivate struct RegisterRequest: Encodable {
    let password: String
    let token: String
    let code: String
    let loginMode: Bool
}

/// BIT101 登录模式注册响应。
fileprivate struct RegisterResponse: Decodable {
    let fakeCookie: String
}

/// 禁止自动重定向的 `URLSession` delegate。
///
/// 学校登录的第一跳需要手动截获 302，才能继续补走整条 SSO 链路。
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// 允许正常跳转，但在发生 HTTP 降级时强制改回 HTTPS。
private final class HTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(request)
            return
        }

        let upgradedURL = LoginURLUpgrade.upgradedURL(from: url)
        if upgradedURL != url {
            var secureRequest = request
            secureRequest.url = upgradedURL
            completionHandler(secureRequest)
            return
        }

        completionHandler(request)
    }
}

/// 登录相关的网络客户端。
///
/// 既负责学校 CAS，也负责 BIT101 自己的 `webvpn_verify` / `register` 接口。
struct BIT101APIClient {
    static let shared = BIT101APIClient()
    private let schoolBaseURL = URL(string: "https://sso.bit.edu.cn")!
    private let bit101BaseURL = URL(string: "https://bit101.flwfdd.xyz")!

    private let session: URLSession
    private let noRedirectSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let noRedirectDelegate = NoRedirectDelegate()
    private let redirectDelegate = HTTPSRedirectDelegate()

    /// 构造两套会话：
    /// 1. 正常跟随重定向
    /// 2. 手动接管 302
    ///
    /// 学校 SSO 链路里两种模式都会用到，所以在这里一次性准备好。
    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true

        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        noRedirectSession = URLSession(
            configuration: configuration,
            delegate: noRedirectDelegate,
            delegateQueue: nil
        )

        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    /// 拉取学校登录页并解析出后续登录所需上下文。
    ///
    /// 这里不会做任何缓存，因为学校 CAS 的 salt/execution 都是一次性的。
    func fetchSchoolLoginContext() async throws -> SchoolLoginContext {
        var request = URLRequest(url: schoolBaseURL.appending(path: "cas/login"))
        request.httpMethod = "GET"

        let html = try await sendStringRequest(request)
        return SchoolLoginHTMLParser.parse(html: html)
    }

    /// 提交学校 CAS 登录表单。
    ///
    /// 返回值只表示学校侧认证是否成功，不代表 BIT101 自己已经完成注册或登录。
    func loginSchool(studentID: String, password: String, salt: String, execution: String) async throws -> Bool {
        let encryptedPassword = try LoginCrypto.encryptPassword(password, saltBase64: salt)
        let encryptedCaptchaPayload = try LoginCrypto.encryptPassword("{}", saltBase64: salt)

        var request = URLRequest(url: schoolBaseURL.appending(path: "cas/login"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(
            [
                ("username", studentID),
                ("password", encryptedPassword),
                ("execution", execution),
                ("croypto", salt),
                ("captcha_payload", encryptedCaptchaPayload),
                ("type", "UsernamePassword"),
                ("geolocation", ""),
                ("captcha_code", ""),
                ("_eventId", "submit"),
            ]
        )

        let (data, response) = try await sendRequest(request, followRedirects: false)

        if (300 ..< 400).contains(response.statusCode) {
            // 正确密码时学校会进入一串 SSO 成功跳转；如果这里不补走，后续教务和乐学接口仍然拿不到学校 cookie。
            if let location = response.value(forHTTPHeaderField: "Location") {
                try await finishSchoolLoginRedirectChain(from: location, relativeTo: request.url!)
            }
            return true
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            throw errorForStatusCode(response.statusCode)
        }

        let html = String(decoding: data, as: UTF8.self)
        return !html.contains("用户名密码")
    }

    /// 手动补走学校侧 SSO 的 302 链路，确保相关学校 cookie 真正落盘。
    ///
    /// 如果缺了这一步，后续看起来像“学校登录成功了”，但教务/乐学接口依赖的学校 cookie
    /// 实际上还没完整写入，会导致部分功能在进入主界面后再失败。
    private func finishSchoolLoginRedirectChain(from location: String, relativeTo baseURL: URL) async throws {
        guard var nextURL = LoginURLUpgrade.resolvedURL(from: location, relativeTo: baseURL) else {
            return
        }

        // 学校成功页通常会经历多次 302，这里手动接管，避免被 ATS 卡在中间的 HTTP 地址上。
        for _ in 0 ..< 8 {
            var request = URLRequest(url: nextURL)
            request.httpMethod = "GET"

            let (_, response) = try await sendRequest(request, followRedirects: false)

            if (300 ..< 400).contains(response.statusCode),
               let nextLocation = response.value(forHTTPHeaderField: "Location"),
               let resolved = LoginURLUpgrade.resolvedURL(from: nextLocation, relativeTo: nextURL) {
                nextURL = resolved
                continue
            }

            if (200 ..< 300).contains(response.statusCode) {
                return
            }

            if (200 ..< 400).contains(response.statusCode) {
                return
            }

            throw errorForStatusCode(response.statusCode)
        }
    }

    /// 初始化 WebVPN 校验上下文。
    fileprivate func webVPNVerifyInit(studentID: String) async throws -> WebVPNVerifyInitResponse {
        try await sendJSONRequest(
            url: bit101BaseURL.appending(path: "user/webvpn_verify_init"),
            method: "POST",
            body: WebVPNVerifyInitRequest(sid: studentID)
        )
    }

    /// 提交 WebVPN 校验。
    fileprivate func webVPNVerify(studentID: String, password: String, execution: String, cookie: String, salt: String) async throws -> WebVPNVerifyResponse {
        try await sendJSONRequest(
            url: bit101BaseURL.appending(path: "user/webvpn_verify"),
            method: "POST",
            body: WebVPNVerifyRequest(
                sid: studentID,
                password: password,
                execution: execution,
                cookie: cookie,
                salt: salt,
                captcha: ""
            )
        )
    }

    /// 以“登录模式”完成 BIT101 自身注册/登录。
    fileprivate func register(password: String, token: String, code: String) async throws -> RegisterResponse {
        try await sendJSONRequest(
            url: bit101BaseURL.appending(path: "user/register"),
            method: "POST",
            body: RegisterRequest(
                password: password,
                token: token,
                code: code,
                loginMode: true
            )
        )
    }

    /// 检查 BIT101 自己的 fake-cookie 是否仍然有效。
    func checkBIT101Login(fakeCookie: String) async throws -> Bool {
        guard !fakeCookie.isEmpty else {
            return false
        }

        var request = URLRequest(url: bit101BaseURL.appending(path: "user/check"))
        request.httpMethod = "GET"
        request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")

        let (_, response) = try await sendRequest(request, followRedirects: true)
        switch response.statusCode {
        case 200 ..< 300:
            return true
        case 401:
            return false
        default:
            throw errorForStatusCode(response.statusCode)
        }
    }

    /// 发送普通字符串请求，主要用于学校 HTML 页面。
    private func sendStringRequest(_ request: URLRequest) async throws -> String {
        let (data, response) = try await sendRequest(request, followRedirects: true)

        guard (200 ..< 400).contains(response.statusCode) else {
            throw errorForStatusCode(response.statusCode)
        }

        return String(decoding: data, as: UTF8.self)
    }

    /// 发送 JSON 请求并自动解码响应体。
    ///
    /// 登录链路里的 BIT101 自有接口都走这条路径：编码 body、发送请求、检查状态码、解码响应。
    private func sendJSONRequest<Body: Encodable, Response: Decodable>(
        url: URL,
        method: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await sendRequest(request, followRedirects: true)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw errorForStatusCode(response.statusCode)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw LoginServiceError.invalidServerResponse
        }
    }

    /// 根据是否允许跟随重定向，选择合适的 `URLSession` 并统一做 HTTPS 升级。
    ///
    /// 这里是整个登录链路里最核心的网络入口，学校接口和 BIT101 接口最终都从这里出。
    private func sendRequest(_ request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        let activeSession = followRedirects ? session : noRedirectSession
        let finalRequest: URLRequest

        if let url = request.url {
            var upgradedRequest = request
            upgradedRequest.url = LoginURLUpgrade.upgradedURL(from: url)
            finalRequest = upgradedRequest
        } else {
            finalRequest = request
        }

        do {
            let result = try await HTTPClient(transport: activeSession).send(
                finalRequest,
                accepting: 100 ..< 600
            )
            data = result.data
            response = result.response
        } catch {
            throw describeNetworkError(error, request: finalRequest)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LoginServiceError.invalidServerResponse
        }

        return (data, httpResponse)
    }

    /// 把表单字段编码成 `application/x-www-form-urlencoded` 数据。
    ///
    /// 学校 CAS 登录表单不收 JSON，因此需要保留这条传统表单编码路径。
    private func formBody(_ fields: [(String, String)]) -> Data {
        let encoded = fields
            .map { key, value in
                "\(urlEncode(key))=\(urlEncode(value))"
            }
            .joined(separator: "&")

        return Data(encoded.utf8)
    }

    /// 表单字段专用的 URL 编码。
    private func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 把 HTTP 状态码转成统一错误对象。
    private func errorForStatusCode(_ statusCode: Int) -> NSError {
        NSError(
            domain: "BIT101.Login",
            code: statusCode,
            userInfo: [NSLocalizedDescriptionKey: "请求失败，HTTP 状态码 \(statusCode)。"]
        )
    }

    /// 为网络错误附带更具体的 URL 与诊断信息。
    private func describeNetworkError(_ error: Error, request: URLRequest) -> NSError {
        let nsError = error as NSError
        let failingURL =
            (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ??
            request.url

        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            let message = """
            网络请求被 ATS 拦截。
            URL: \(failingURL?.absoluteString ?? "未知")
            code: \(nsError.code)
            \(nsError.localizedDescription)
            """

            return NSError(
                domain: nsError.domain,
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let message = """
        网络请求失败。
        URL: \(failingURL?.absoluteString ?? "未知")
        code: \(nsError.code)
        \(nsError.localizedDescription)
        """

        return NSError(
            domain: nsError.domain,
            code: nsError.code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

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
