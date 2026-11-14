import Foundation
import TransportCore

public nonisolated protocol SchoolServiceFailureProviding: Error {
    var schoolServiceFailure: SchoolServiceFailure? { get }
}

/// 学校协议适配层保留错误来源，页面文案独立调整。
public nonisolated enum SchoolServiceFailure: LocalizedError, Equatable,
    SchoolServiceFailureProviding
{
    case authenticationChannel, authenticationRestricted, captchaRequired, accountLocked,
        sessionExpired, accessDenied, secureConnection, unavailable

    public var schoolServiceFailure: Self? { self }

    public static func from(_ error: (any Error)?) -> Self? {
        guard let error else { return nil }
        var result: Self?
        _ = ErrorChain.contains(error) { candidate in
            result = (candidate as? any SchoolServiceFailureProviding)?.schoolServiceFailure
            return result != nil
        }
        return result
    }

    /// 这些标记来自学校与认证网关的响应协议。
    public static func authenticationResponse(_ message: String) -> Self? {
        let value = message.lowercased()
        if accountIsLocked(message) { return .accountLocked }
        if let failure = schoolResponse(message) { return failure }
        if hasErrorCode("1320007", in: message) { return .captchaRequired }
        if hasErrorCode("1320009", in: message) { return .authenticationRestricted }
        if value.contains("risk=ustc-token") || value.contains("risk=error-fallback") {
            return .authenticationRestricted
        }
        if value.contains("初始化webvpn验证失败") || value.contains("jxzxehall: 解析 service url 失败") {
            return .authenticationChannel
        }
        return nil
    }

    public static func schoolResponse(_ message: String) -> Self? {
        if accountIsLocked(message) { return .accountLocked }
        switch SchoolLoginHTMLParser.loginErrorCode(html: message) {
        case "1320007": return .captchaRequired
        case "1320009": return .authenticationRestricted
        default: break
        }
        if message.contains("无权访问该资源") { return .accessDenied }
        if message.contains("会话已经过期") { return .sessionExpired }
        return nil
    }

    private static func hasErrorCode(_ code: String, in message: String) -> Bool {
        message.range(of: #"(?<![0-9])"# + code + #"(?![0-9])"#, options: .regularExpression) != nil
    }

    private static func accountIsLocked(_ message: String) -> Bool {
        ["账号已被锁定", "账号被锁定", "帐号已被锁定", "帐号被锁定"].contains(where: message.contains)
            || SchoolLoginHTMLParser.loginErrorCode(html: message) == "1030028"
            || message.range(
                of: #"\bcode["']?\s*[:=]\s*["']?1030028\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    public var errorDescription: String? {
        switch self {
        case .authenticationChannel:
            "学校认证通道暂时无法完成请求。请稍后重试，也可通过学校官方入口核对服务状态。"
        case .authenticationRestricted:
            "学校统一认证拒绝了本次认证请求。请通过学校官方入口核对账号与验证要求，稍后重试。"
        case .captchaRequired:
            "学校统一认证要求完成图形验证码核验。请通过学校官方入口登录一次后再返回重试。"
        case .accountLocked:
            "学校统一认证提示账号已被锁定。请通过学校官方入口确认解锁方式，或联系学校服务渠道处理。"
        case .sessionExpired:
            "学校教务服务会话暂时失效，请稍后重试，或通过学校官方入口处理。"
        case .accessDenied:
            "学校教务服务返回“无权访问该资源”。请通过学校官方入口核对，或联系学校服务渠道处理。"
        case .secureConnection:
            "学校统一认证服务的安全连接暂时受阻，请稍后重试，或通过学校官方入口处理。"
        case .unavailable:
            "学校服务暂时无法完成请求，请稍后重试，也可通过学校官方入口核对服务状态。"
        }
    }
}

public nonisolated struct BITLoginAuthenticationChallenge: Identifiable, Equatable, Sendable {
    public let challengeID: String
    public let accessToken: String
    public let status: String
    public let maskedPhone: String?
    public let expiresIn: Int?
    public let ownerIdentity: SchoolSessionIdentity?
    public let receivedAt: Date
    public let nativeSession: SchoolAuthenticatedSession?
    public let captchaImage: String?
    public let error: String?

    public var id: String { challengeID }
    public var isCaptcha: Bool { status == "waiting_captcha" }
    public var requiresVerification: Bool { isCaptcha || status == "waiting_sms" }
    public var captchaImageData: Data? {
        guard let captchaImage, captchaImage.hasPrefix("data:image/"),
            let comma = captchaImage.firstIndex(of: ","),
            captchaImage[..<comma].hasSuffix(";base64")
        else { return nil }
        return Data(base64Encoded: String(captchaImage[captchaImage.index(after: comma)...]))
    }

    public var isExpired: Bool {
        guard let expiresIn else { return false }
        return Date() >= receivedAt.addingTimeInterval(TimeInterval(expiresIn))
    }

    public init(
        challengeID: String,
        accessToken: String,
        status: String,
        maskedPhone: String?,
        expiresIn: Int?,
        receivedAt: Date = Date(),
        ownerIdentity: SchoolSessionIdentity? = nil,
        nativeSession: SchoolAuthenticatedSession? = nil,
        captchaImage: String? = nil,
        error: String? = nil
    ) {
        self.challengeID = challengeID
        self.accessToken = accessToken
        self.status = status
        self.maskedPhone = maskedPhone
        self.expiresIn = expiresIn
        self.receivedAt = receivedAt
        self.ownerIdentity = ownerIdentity
        self.nativeSession = nativeSession
        self.captchaImage = captchaImage
        self.error = error
    }
}

/// 表示 bit-login 为学校 JWB 系列业务创建的短期统一认证挑战。
///
/// `accessToken` 的生命周期限于内存，UserDefaults 与 Keychain 承载长期凭据。

public nonisolated struct BITLoginCodeRequest: Encodable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

public nonisolated struct BITLoginChallengeEnvelope: Decodable, Sendable {
    public let detail: BITLoginChallengePayload
}

public nonisolated struct BITLoginChallengePayload: Decodable, Sendable {
    public let challengeID: String
    public let accessToken: String?
    public let status: String
    public let maskedPhone: String?
    public let expiresIn: Int?
    public let error: String?
    public let captchaImage: String?

    enum CodingKeys: String, CodingKey {
        case status, error
        case challengeID = "challenge_id"
        case accessToken = "access_token"
        case maskedPhone = "masked_phone"
        case expiresIn = "expires_in"
        case captchaImage = "captcha_image"
    }
}

/// `BITLoginChallengeSupport` 共享成绩和课表的 bit-login 协议细节，各业务维护自己的会话与错误含义。
public enum BITLoginChallengeSupport {
    private struct PollDeadlineReached: Error {}

    public nonisolated static func decodePayload(from data: Data) throws -> BITLoginChallengePayload
    {
        try JSONDecoder().decode(BITLoginChallengePayload.self, from: data)
    }

    public static func pollUntilActionable(
        _ initialPayload: BITLoginChallengePayload,
        timeout: TimeInterval,
        interval: Duration,
        fetch: @escaping @Sendable (String) async throws -> BITLoginChallengePayload
    ) async throws -> BITLoginChallengePayload {
        guard timeout > 0, interval > .zero else { return initialPayload }

        var payload = initialPayload
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))

        while ["running", "processing"].contains(payload.status) {
            let remaining = deadline - clock.now
            guard remaining > .zero else { break }

            try await Task.sleep(for: min(interval, remaining))

            guard clock.now < deadline else { break }

            let challengeID = payload.challengeID
            do {
                payload = try await withThrowingTaskGroup(
                    of: BITLoginChallengePayload.self
                ) { group in
                    group.addTask {
                        try await fetch(challengeID)
                    }
                    group.addTask {
                        try await clock.sleep(until: deadline)
                        throw PollDeadlineReached()
                    }
                    defer { group.cancelAll() }

                    guard let result = try await group.next() else {
                        throw PollDeadlineReached()
                    }
                    guard clock.now < deadline else {
                        throw PollDeadlineReached()
                    }
                    return result
                }
            } catch is PollDeadlineReached {
                break
            }
        }
        return payload
    }

    public static func challenge(
        from payload: BITLoginChallengePayload,
        accessToken: String,
        ownerIdentity: SchoolSessionIdentity? = nil
    ) -> BITLoginAuthenticationChallenge {
        BITLoginAuthenticationChallenge(
            challengeID: payload.challengeID,
            accessToken: accessToken,
            status: payload.status,
            maskedPhone: payload.maskedPhone,
            expiresIn: payload.expiresIn,
            ownerIdentity: ownerIdentity,
            captchaImage: payload.captchaImage,
            error: payload.error
        )
    }

    public nonisolated static func verificationRequest(
        code: String, for challenge: BITLoginAuthenticationChallenge,
        baseURL: URL
    ) throws -> URLRequest {
        let step = challenge.isCaptcha ? "captcha" : "sms"
        var request = URLRequest(
            url: baseURL.appending(components: "api", "auth", challenge.challengeID, step))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(challenge.accessToken, forHTTPHeaderField: "X-Challenge-Token")
        request.httpBody = try JSONEncoder().encode(BITLoginCodeRequest(code: code))
        return request
    }

    public nonisolated static func errorMessage(from data: Data) -> String? {
        HTTPClient.errorMessage(from: data)
    }
}
