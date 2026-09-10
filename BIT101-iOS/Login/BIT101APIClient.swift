//
//  BIT101APIClient.swift
//  BIT101-iOS
//

import Foundation

private struct LoginServerResponseError: LocalizedError {
    let statusCode: Int
    let message: String?

    var indicatesCredentialFailure: Bool {
        BIT101APIClient.isCredentialFailureMessage(message)
    }

    var errorDescription: String? {
        guard let message, !message.isEmpty else {
            return "请求失败，HTTP 状态码 \(statusCode)。"
        }
        return "服务器响应异常（HTTP \(statusCode)）：\(message)"
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

/// 登录相关的网络客户端。
///
/// 既负责学校 CAS，也负责 BIT101 自己的 `webvpn_verify` / `register` 接口。
struct BIT101APIClient {
    static let shared = BIT101APIClient()
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
    private let schoolBaseURL = AppURL.required("https://sso.bit.edu.cn")
    private let bit101BaseURL = AppURL.required("https://bit101.flwfdd.xyz")

    private let session: URLSession
    private let noRedirectSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let noRedirectDelegate = NoRedirectURLSessionDelegate()
    private let redirectDelegate = HTTPSUpgradingRedirectDelegate()

    /// 初始化两套会话：
    /// 1. 正常跟随重定向
    /// 2. 手动接管 302
    ///
    /// 学校 SSO 链路需要这两种模式。
    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always

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
    /// 学校 CAS 的 salt/execution 只用于当前请求，函数直接解析响应。
    func fetchSchoolLoginContext() async throws -> SchoolLoginContext {
        var request = URLRequest(url: schoolBaseURL.appending(path: "cas/login"))
        request.httpMethod = "GET"
        guard let requestURL = request.url else { throw LoginServiceError.invalidServerResponse }

        let (data, response) = try await sendRequest(request, followRedirects: false)
        if (300 ..< 400).contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location"),
           let redirectURL = HTTPSURLUpgrade.resolvedURL(from: location, relativeTo: requestURL),
           Self.isSchoolLoginSuccessLanding(redirectURL, schoolHost: schoolBaseURL.host)
        {
            return SchoolLoginContext(salt: nil, execution: nil, isLoggedIn: true)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw errorForStatusCode(response.statusCode)
        }

        let html = String(decoding: data, as: UTF8.self)
        return SchoolLoginHTMLParser.parse(html: html)
    }

    /// 提交学校 CAS 登录表单。
    ///
    /// 返回值表示学校侧认证结果；BIT101 注册或登录状态由后续流程确定。
    func loginSchool(studentID: String, password: String, salt: String, execution: String) async throws -> Bool {
        let encryptedPassword = try LoginCrypto.encryptPassword(password, saltBase64: salt)
        let encryptedCaptchaPayload = try LoginCrypto.encryptPassword("{}", saltBase64: salt)

        var request = URLRequest(url: schoolBaseURL.appending(path: "cas/login"))
        request.httpMethod = "POST"
        guard let requestURL = request.url else { throw LoginServiceError.invalidServerResponse }
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
            // 正确密码时学校会进入一串 SSO 成功跳转；继续访问跳转链后，教务和乐学接口才能获得学校 cookie。
            if let location = response.value(forHTTPHeaderField: "Location") {
                try await finishSchoolLoginRedirectChain(from: location, relativeTo: requestURL)
            }
            return true
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            throw errorForStatusCode(response.statusCode)
        }

        let html = String(decoding: data, as: UTF8.self)
        if let context = SchoolLoginHTMLParser.parseSecondFactorPage(
            html: html,
            baseURL: schoolBaseURL
        ) {
            throw LoginServiceError.schoolSMSRequired(context)
        }
        return !html.contains("用户名密码")
    }

    /// 手动补走学校侧 SSO 的 302 链路，确保相关学校 cookie 真正落盘。
    ///
    /// 这一步继续访问跳转链并完成学校 cookie 写入；教务和乐学接口在进入主界面后依赖这些 cookie。
    private func finishSchoolLoginRedirectChain(from location: String, relativeTo baseURL: URL) async throws {
        guard var nextURL = HTTPSURLUpgrade.resolvedURL(from: location, relativeTo: baseURL) else {
            return
        }

        // 学校成功页通常会经历多次 302，这里手动接管并将中间 HTTP 地址升级为 HTTPS，满足 ATS 要求。
        for _ in 0 ..< 8 {
            var request = URLRequest(url: nextURL)
            request.httpMethod = "GET"

            let (_, response) = try await sendRequest(request, followRedirects: false)

            if (300 ..< 400).contains(response.statusCode),
               let nextLocation = response.value(forHTTPHeaderField: "Location"),
               let resolved = HTTPSURLUpgrade.resolvedURL(from: nextLocation, relativeTo: nextURL) {
                nextURL = resolved
                continue
            }

            // 新版统一认证把登录成功后的浏览器落点改成了前端 gate 路由。
            // CAS 会话 Cookie 在上一步 302 时写入；普通 URLSession GET 访问该路由
            // 返回 401，用户名密码认证仍已完成。后续带 service 参数访问 CAS 时，业务系统
            // 继续完成票据跳转。
            if Self.isAcceptedSchoolLoginCompletion(
                statusCode: response.statusCode,
                url: nextURL,
                schoolHost: schoolBaseURL.host
            ) {
                return
            }

            throw errorForStatusCode(response.statusCode)
        }
    }

    static func isAcceptedSchoolLoginCompletion(
        statusCode: Int,
        url: URL,
        schoolHost: String? = "sso.bit.edu.cn"
    ) -> Bool {
        if (200 ..< 400).contains(statusCode) {
            return true
        }
        return statusCode == 401
            && isSchoolLoginSuccessLanding(url, schoolHost: schoolHost)
    }

    static func isSchoolLoginSuccessLanding(
        _ url: URL,
        schoolHost: String? = "sso.bit.edu.cn"
    ) -> Bool {
        url.host?.lowercased() == schoolHost?.lowercased()
            && url.path == "/gate/cas-success"
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
        do {
            return try await sendJSONRequest(
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
        } catch let error as LoginServerResponseError where error.indicatesCredentialFailure {
            throw LoginServiceError.invalidCredentials
        }
    }

    static func isCredentialFailureMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        let normalized = message.lowercased()
        return normalized.contains("统一身份认证失败")
            || normalized.contains("用户名或密码")
            || normalized.contains("账号或密码")
            || normalized.contains("password") && normalized.contains("invalid")
    }

    /// 使用“登录模式”完成 BIT101 自身注册/登录。
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

    /// 检查 BIT101 自己的 fake-cookie 有效性。
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

    /// 发送 JSON 请求并自动解码响应体。
    ///
    /// BIT101 登录接口均在此编码请求体、发送请求、检查状态码并解码响应。
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
            throw LoginServerResponseError(
                statusCode: response.statusCode,
                message: responseMessage(from: data)
            )
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw LoginServiceError.invalidServerResponse
        }
    }

    private func responseMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        for key in ["msg", "message", "error"] {
            if let value = object[key] as? String {
                let message = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty {
                    return String(message.prefix(200))
                }
            }
        }
        return nil
    }

    /// 根据是否允许跟随重定向，选择合适的 `URLSession` 并统一做 HTTPS 升级。
    private func sendRequest(_ request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        let activeSession = followRedirects ? session : noRedirectSession
        let finalRequest: URLRequest

        if let url = request.url {
            var upgradedRequest = request
            upgradedRequest.url = HTTPSURLUpgrade.upgradedURL(from: url)
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
    /// 学校 CAS 登录表单使用 `application/x-www-form-urlencoded`，这条编码路径继续保留。
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
