import TransportCore
import Foundation

public nonisolated protocol SchoolServiceFailureProviding: Error {
    var schoolServiceFailure: SchoolServiceFailure? { get }
}

/// 学校协议适配层保留错误来源，页面文案独立调整。
public nonisolated enum SchoolServiceFailure: LocalizedError, Equatable, SchoolServiceFailureProviding {
    case authenticationChannel, authenticationRestricted, sessionExpired, accessDenied, secureConnection, unavailable

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
        if value.contains("risk=ustc-token") { return .authenticationRestricted }
        if value.contains("初始化webvpn验证失败") || value.contains("jxzxehall: 解析 service url 失败") {
            return .authenticationChannel
        }
        return schoolResponse(message)
    }

    public static func schoolResponse(_ message: String) -> Self? {
        if message.contains("无权访问该资源") { return .accessDenied }
        if message.contains("会话已经过期") { return .sessionExpired }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .authenticationChannel:
            "学校认证通道暂时无法完成请求。请稍后重试，也可通过学校官方入口核对服务状态。"
        case .authenticationRestricted:
            "学校统一认证拒绝了本次认证请求。请通过学校官方入口核对账号与验证要求，稍后重试。"
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

    public var id: String { challengeID }

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
        nativeSession: SchoolAuthenticatedSession? = nil
    ) {
        self.challengeID = challengeID
        self.accessToken = accessToken
        self.status = status
        self.maskedPhone = maskedPhone
        self.expiresIn = expiresIn
        self.receivedAt = receivedAt
        self.ownerIdentity = ownerIdentity
        self.nativeSession = nativeSession
    }
}

/// 表示 bit-login 为学校 JWB 系列业务创建的短期统一认证挑战。
///
/// `accessToken` 的生命周期限于内存，UserDefaults 与 Keychain 承载长期凭据。

public struct BITLoginSMSCodeRequest: Encodable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case status, error
        case challengeID = "challenge_id"
        case accessToken = "access_token"
        case maskedPhone = "masked_phone"
        case expiresIn = "expires_in"
    }
}

/// `BITLoginChallengeSupport` 共享成绩和课表的 bit-login 协议细节，各业务维护自己的会话与错误语义。
public enum BITLoginChallengeSupport {
    private struct PollDeadlineReached: Error {}

    private final class FetchOperation: Sendable {
        let call: @Sendable (String) async throws -> BITLoginChallengePayload

        init(call: @escaping @Sendable (String) async throws -> BITLoginChallengePayload) {
            self.call = call
        }
    }

    private final class FetchResult: Sendable {
        let payload: BITLoginChallengePayload

        nonisolated init(payload: BITLoginChallengePayload) {
            self.payload = payload
        }
    }

    public nonisolated static func decodePayload(from data: Data) throws -> BITLoginChallengePayload {
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
        let fetchOperation = FetchOperation(call: fetch)

        while ["running", "processing"].contains(payload.status) {
            let remaining = deadline - clock.now
            guard remaining > .zero else { break }

            try await Task.sleep(for: min(interval, remaining))

            guard clock.now < deadline else { break }

            let challengeID = payload.challengeID
            do {
                let result = try await withThrowingTaskGroup(of: FetchResult.self) { group in
                    group.addTask {
                        FetchResult(payload: try await fetchOperation.call(challengeID))
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
                payload = result.payload
            } catch is PollDeadlineReached {
                break
            }
        }
        return payload
    }

    public static func challenge(
        from payload: BITLoginChallengePayload,
        accessToken: String,
        ownerIdentity: SchoolSessionIdentity? = nil,
        nativeSession: SchoolAuthenticatedSession? = nil
    ) -> BITLoginAuthenticationChallenge {
        BITLoginAuthenticationChallenge(
            challengeID: payload.challengeID,
            accessToken: accessToken,
            status: payload.status,
            maskedPhone: payload.maskedPhone,
            expiresIn: payload.expiresIn,
            ownerIdentity: ownerIdentity
        )
    }

    private nonisolated static func firstNonEmptyString(
        in object: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    public nonisolated static func errorMessage(from data: Data) -> String? {
        HTTPClient.errorMessage(from: data)
    }
}
