//
//  BIT101APIClient.swift
//  BIT101-iOS
//

import Foundation

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

/// WebVPN 校验初始化请求体。
struct WebVPNVerifyInitRequest: Encodable {
    let sid: String
}

/// WebVPN 校验初始化响应。
struct WebVPNVerifyInitResponse: Decodable {
    let captcha: String
    let cookie: String
    let execution: String
    let salt: String
}

/// WebVPN 校验请求体。
struct WebVPNVerifyRequest: Encodable {
    let sid: String
    let password: String
    let execution: String
    let cookie: String
    let salt: String
    let captcha: String
}

/// WebVPN 校验结果。
struct WebVPNVerifyResponse: Decodable {
    let token: String
    let code: String
}

/// BIT101 登录模式注册请求体。
struct RegisterRequest: Encodable {
    let password: String
    let token: String
    let code: String
    let loginMode: Bool
}

/// BIT101 登录模式注册响应。
struct RegisterResponse: Decodable {
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
    func webVPNVerifyInit(studentID: String) async throws -> WebVPNVerifyInitResponse {
        try await sendJSONRequest(
            url: bit101BaseURL.appending(path: "user/webvpn_verify_init"),
            method: "POST",
            body: WebVPNVerifyInitRequest(sid: studentID)
        )
    }

    /// 提交 WebVPN 校验。
    func webVPNVerify(studentID: String, password: String, execution: String, cookie: String, salt: String) async throws -> WebVPNVerifyResponse {
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
    func register(password: String, token: String, code: String) async throws -> RegisterResponse {
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
