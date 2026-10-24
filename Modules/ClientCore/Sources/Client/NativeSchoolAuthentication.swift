import Foundation
import TransportCore

public nonisolated enum SchoolServiceTarget: Sendable {
    case teachingCenter, grades, transcript, webVPN

    public var baseURL: URL {
        switch self {
        case .teachingCenter: AppURL.required("https://jxzxehallapp.bit.edu.cn")
        case .grades: AppURL.required("https://jwms.bit.edu.cn")
        case .transcript: AppURL.required("https://jwb.bit.edu.cn")
        case .webVPN: AppURL.required("https://webvpn.bit.edu.cn")
        }
    }

    public var webVPNBaseURL: URL? {
        let token: String
        switch self {
        case .teachingCenter: token = "faef5b842238695c720999bcd6572a216b231105adc27d"
        case .grades: token = "fae04c8f69326144300d8db9d6562d"
        case .transcript, .webVPN: return nil
        }
        let scheme = self == .grades ? "http" : "https"
        return AppURL.required("https://webvpn.bit.edu.cn/\(scheme)/77726476706e69737468656265737421\(token)")
    }
}

/// 本机短期业务会话，Cookie 按业务域和路径筛选，随账号代际失效。
public nonisolated struct SchoolAuthenticatedSession: Equatable, Sendable {
    public let baseURL: URL
    public let cookieHeader: String
    public let owner: SchoolSessionIdentity
    public init(baseURL: URL, cookieHeader: String, owner: SchoolSessionIdentity) {
        self.baseURL = baseURL
        self.cookieHeader = cookieHeader
        self.owner = owner
    }
}

public protocol SchoolServiceAuthenticating {
    func authenticate(_ target: SchoolServiceTarget) async throws -> SchoolAuthenticatedSession
}

public nonisolated enum NativeSchoolAuthenticationError: LocalizedError, SchoolServiceFailureProviding {
    case invalidResponse, serviceUnavailable(Int), additionalVerification
    public var schoolServiceFailure: SchoolServiceFailure? {
        guard case .serviceUnavailable(let status) = self else { return nil }
        return status == 403 ? .accessDenied : (status >= 500 ? .unavailable : nil)
    }
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "学校认证页面结构发生变化，请稍后重试。"
        case .serviceUnavailable(let status): "学校服务响应异常（HTTP \(status)）。"
        case .additionalVerification: "学校需要补充身份验证，请重新尝试当前操作。"
        }
    }
}

/// CAS 票据、业务 Cookie 与 WebVPN 回调均在客户端完成。
@MainActor
public final class NativeSchoolAuthenticator: SchoolServiceAuthenticating {
    private let credentials: any SchoolCredentialsProviding
    private let restorer: any SchoolSessionRestoring
    private let client: HTTPClient
    private let cookies: () -> HTTPCookieStorage
    private let secondFactor: (SchoolSecondFactorContext) async throws -> Void
    private let serviceLogin: (URL, String) async throws -> URL
    private let fingerprint = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let authenticationQueue = SchoolAuthenticationQueue()

    public init(credentials: any SchoolCredentialsProviding, restorer: any SchoolSessionRestoring,
        client: HTTPClient, cookies: @escaping () -> HTTPCookieStorage,
        secondFactor: @escaping (SchoolSecondFactorContext) async throws -> Void,
        serviceLogin: @escaping (URL, String) async throws -> URL = { _, _ in throw NativeSchoolAuthenticationError.invalidResponse }) {
        self.credentials = credentials
        self.restorer = restorer
        self.client = client
        self.cookies = cookies
        self.secondFactor = secondFactor
        self.serviceLogin = serviceLogin
    }

    public func authenticate(_ target: SchoolServiceTarget) async throws -> SchoolAuthenticatedSession {
        let owner = credentials.schoolSessionIdentity
        return try await authenticationQueue.perform {
            try await self.authenticate(target, owner: owner)
        }
    }

    public func verifyIdentity() async throws {
        let owner = credentials.schoolSessionIdentity
        try await authenticationQueue.perform {
            let landing = try await self.follow(self.webVPNLoginURL, owner: owner, stopAtIdentityTicket: true)
            guard Self.isIdentityServiceTicket(landing) else { throw NativeSchoolAuthenticationError.invalidResponse }
        }
    }

    public nonisolated static func isIdentityServiceTicket(_ url: URL) -> Bool {
        guard isSchoolURL(url), url.host == "webvpn.bit.edu.cn", url.path == "/login", url.fragment == nil,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let tickets = query.filter { $0.name == "ticket" }
        return tickets.count == 1 && tickets[0].value?.isEmpty == false
            && query.filter { $0.name == "cas_login" }.map(\.value) == ["true"]
    }

    private func authenticate(_ target: SchoolServiceTarget, owner: SchoolSessionIdentity) async throws -> SchoolAuthenticatedSession {
        try validate(owner)
        do {
            guard try await restorer.restoreSchoolSessionIfNeeded() != nil else { throw NativeSchoolAuthenticationError.additionalVerification }
        }
        catch SchoolSessionRestorationError.secondFactorRequired(let context) {
            try await secondFactor(context)
            try validate(owner)
            guard try await restorer.restoreSchoolSessionIfNeeded() != nil else { throw NativeSchoolAuthenticationError.additionalVerification }
        }
        try validate(owner)
        if target == .webVPN {
            try await establishWebVPN(owner: owner)
            return try session(target.baseURL, target: target, owner: owner)
        }
        do {
            let landing = try await follow(entry(target), owner: owner)
            guard landing.host == target.baseURL.host else { throw NativeSchoolAuthenticationError.invalidResponse }
            return try session(target.baseURL, target: target, owner: owner)
        } catch {
            try validate(owner)
            guard let vpnBase = target.webVPNBaseURL,
                  Self.permitsFallback(error) else { throw error }
            try await establishWebVPN(owner: owner)
            let landing = try await follow(entry(target), owner: owner, throughWebVPN: true)
            guard landing.host == vpnBase.host, landing.path.hasPrefix(vpnBase.path) else {
                throw NativeSchoolAuthenticationError.invalidResponse
            }
            return try session(vpnBase, target: target, owner: owner)
        }
    }

    private func entry(_ target: SchoolServiceTarget) -> URL {
        switch target {
        case .teachingCenter:
            AppURL.required("https://jxzxehall.bit.edu.cn/auth-protocol-core/login?service=https%3A%2F%2Fjxzxehallapp.bit.edu.cn%2Fjwapp%2Fsys%2Fwdkbby%2F*default%2Findex.do")
        case .grades:
            // service 标识参与学校票据校验，实际请求统一升级 HTTPS。
            AppURL.required("https://sso.bit.edu.cn/cas/login?service=http%3A%2F%2Fjwms.bit.edu.cn%2F")
        case .transcript: target.baseURL.appending(path: "cjd/Account/ExternalLogin")
        case .webVPN: target.baseURL
        }
    }

    private func establishWebVPN(owner: SchoolSessionIdentity) async throws {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "webvpn.bit.edu.cn"; parts.path = "/set-fingerprint"
        parts.queryItems = [URLQueryItem(name: "fingerprint", value: fingerprint)]
        // 指纹先于 CAS service 登录，Wengine ticket 与本机浏览器身份保持一致。
        guard let fingerprintURL = parts.url else { throw NativeSchoolAuthenticationError.invalidResponse }
        let wire = try await client.send(URLRequest(url: fingerprintURL), accepting: 200 ..< 400)
        try validate(owner)
        guard wire.response.url == parts.url else { throw NativeSchoolAuthenticationError.invalidResponse }
        _ = try await follow(webVPNLoginURL, owner: owner)
        guard hasWebVPNTicket else { throw NativeSchoolAuthenticationError.invalidResponse }
    }

    private var webVPNLoginURL: URL {
        AppURL.required("https://sso.bit.edu.cn/cas/login?service=https%3A%2F%2Fwebvpn.bit.edu.cn%2Flogin%3Fcas_login%3Dtrue")
    }

    private var hasWebVPNTicket: Bool {
        (cookies().cookies(for: SchoolServiceTarget.webVPN.baseURL) ?? []).contains(where: {
            ["wengine_vpn_ticket", "wengine_vpn_ticketwebvpn_bit_edu_cn"].contains($0.name)
                && ($0.expiresDate.map { $0 > Date() } ?? true)
        })
    }

    private func follow(_ start: URL, owner: SchoolSessionIdentity, throughWebVPN: Bool = false,
                        stopAtIdentityTicket: Bool = false) async throws -> URL {
        var next = start
        var completedSecondFactor = false
        var submittedPassword = false
        for _ in 0 ..< 16 {
            try validate(owner)
            if throughWebVPN { next = vpnURL(next) }
            guard Self.isSchoolURL(next) else { throw NativeSchoolAuthenticationError.invalidResponse }
            if stopAtIdentityTicket {
                if Self.isIdentityServiceTicket(next) {
                    guard submittedPassword else { throw NativeSchoolAuthenticationError.invalidResponse }
                    return next
                }
                guard next.host == "sso.bit.edu.cn" else { throw NativeSchoolAuthenticationError.invalidResponse }
            }
            var request = URLRequest(url: next)
            request.timeoutInterval = 25
            let wire = try await client.send(request, accepting: 100 ..< 600)
            try validate(owner)
            guard let responseURL = wire.response.url, Self.isSchoolURL(responseURL),
                  responseURL == next else { throw NativeSchoolAuthenticationError.invalidResponse }
            if (300 ..< 400).contains(wire.response.statusCode),
               let location = wire.response.value(forHTTPHeaderField: "Location"),
               let url = HTTPSURLUpgrade.resolvedURL(from: location, relativeTo: next) {
                next = url
                continue
            }
            guard (200 ..< 300).contains(wire.response.statusCode) else {
                throw NativeSchoolAuthenticationError.serviceUnavailable(wire.response.statusCode)
            }
            let html = String(decoding: wire.data, as: UTF8.self)
            if let failure = SchoolServiceFailure.schoolResponse(html) { throw failure }
            if let context = SchoolLoginHTMLParser.parseSecondFactorPage(html: html,
                baseURL: AppURL.required("https://sso.bit.edu.cn"), documentURL: next) {
                guard !completedSecondFactor else { throw NativeSchoolAuthenticationError.additionalVerification }
                try await secondFactor(context)
                completedSecondFactor = true
                next = start
                continue
            }
            if SchoolLoginHTMLParser.parse(html: html).salt != nil {
                guard next.host == "sso.bit.edu.cn", !submittedPassword else { throw NativeSchoolAuthenticationError.invalidResponse }
                next = try await serviceLogin(next, html)
                submittedPassword = true
                continue
            }
            if next.host == "webvpn.bit.edu.cn", next.path == "/fingerprint" {
                guard !throughWebVPN else { throw NativeSchoolAuthenticationError.invalidResponse }
                guard var parts = URLComponents(url: next, resolvingAgainstBaseURL: false) else { throw NativeSchoolAuthenticationError.invalidResponse }
                parts.path = "/set-fingerprint"
                parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "fingerprint" }
                    + [URLQueryItem(name: "fingerprint", value: fingerprint)]
                guard let fingerprintURL = parts.url else { throw NativeSchoolAuthenticationError.invalidResponse }
                next = fingerprintURL
                continue
            }
            return next
        }
        throw NativeSchoolAuthenticationError.invalidResponse
    }

    private func session(_ base: URL, target: SchoolServiceTarget, owner: SchoolSessionIdentity) throws -> SchoolAuthenticatedSession {
        try validate(owner)
        let resource = target == .transcript ? base.appending(path: "cjd/ScoreReport2/Index") : base
        let scoped = (cookies().cookies(for: resource) ?? []).filter { $0.expiresDate.map { $0 > Date() } ?? true }
        let header = scoped.isEmpty ? "" : HTTPCookie.requestHeaderFields(with: scoped)["Cookie"] ?? ""
        return SchoolAuthenticatedSession(baseURL: base, cookieHeader: header, owner: owner)
    }

    private func validate(_ owner: SchoolSessionIdentity) throws {
        try Task.checkCancellation()
        guard !owner.accountIdentifier.isEmpty, credentials.schoolSessionIdentity == owner else { throw CancellationError() }
    }

    private func vpnURL(_ url: URL) -> URL {
        let base: URL
        switch url.host {
        case "jxzxehall.bit.edu.cn":
            base = AppURL.required("https://webvpn.bit.edu.cn/https/77726476706e69737468656265737421faef5b842238695c72468ba58c1b26316e8e7f6f")
        case "jxzxehallapp.bit.edu.cn":
            guard let mapped = SchoolServiceTarget.teachingCenter.webVPNBaseURL else { return url }
            base = mapped
        case "jwms.bit.edu.cn":
            guard let mapped = SchoolServiceTarget.grades.webVPNBaseURL else { return url }
            base = mapped
        default: return url
        }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let mapped = URL(string: base.absoluteString + parts.percentEncodedPath
                + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")) else { return url }
        return mapped
    }

    private nonisolated static func isSchoolURL(_ url: URL) -> Bool {
        url.scheme == "https" && (url.port ?? 443) == 443 && url.user == nil && url.password == nil
            && (url.host == "bit.edu.cn" || url.host?.hasSuffix(".bit.edu.cn") == true)
    }

    /// 交互、密码与账号边界错误交由页面处理，传输及协议错误允许尝试中转。
    public nonisolated static func permitsFallback(_ error: Error) -> Bool {
        if TaskCancellation.matches(error) { return false }
        if let error = error as? NativeSchoolAuthenticationError {
            switch error {
            case .additionalVerification: return false
            default: return true
            }
        }
        return ErrorChain.contains(error) { $0 is URLError || $0 is HTTPClientError }
    }
}

/// CAS service 登录会更新 execution，同一 Cookie 容器按请求顺序完成认证。
@MainActor
private final class SchoolAuthenticationQueue {
    private var active: UUID?
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    func perform<T>(_ operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if active == nil { active = id; continuation.resume() }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiting.firstIndex(where: { $0.0 == id }) else { return }
                self.waiting.remove(at: index).1.resume(throwing: CancellationError())
            }
        }
        defer {
            if waiting.isEmpty { active = nil }
            else {
                let next = waiting.removeFirst()
                active = next.0
                next.1.resume()
            }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}
