import Foundation

public nonisolated struct BITLoginAuthenticationChallenge: Identifiable, Equatable, Sendable {
    public let challengeID: String
    public let accessToken: String
    public let status: String
    public let maskedPhone: String?
    public let expiresIn: Int?
    public let receivedAt: Date

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
        receivedAt: Date = Date()
    ) {
        self.challengeID = challengeID
        self.accessToken = accessToken
        self.status = status
        self.maskedPhone = maskedPhone
        self.expiresIn = expiresIn
        self.receivedAt = receivedAt
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

public struct BITLoginChallengeEnvelope: Decodable, Sendable {
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
        accessToken: String
    ) -> BITLoginAuthenticationChallenge {
        BITLoginAuthenticationChallenge(
            challengeID: payload.challengeID,
            accessToken: accessToken,
            status: payload.status,
            maskedPhone: payload.maskedPhone,
            expiresIn: payload.expiresIn
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
        guard let value = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else {
            return String(data: data, encoding: .utf8)
        }
        if let message = value as? String, !message.isEmpty {
            return message
        }
        guard let json = value as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = json["msg"] as? String, !message.isEmpty {
            return message
        }
        if let detail = json["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if let detail = json["detail"] as? [String: Any] {
            if let message = firstNonEmptyString(in: detail, keys: ["message", "error"]) {
                return message
            }
        }
        if let error = json["error"] as? String, !error.isEmpty {
            return error
        }
        if let error = json["error"] as? [String: Any] {
            if let message = firstNonEmptyString(
                in: error,
                keys: ["message", "msg", "detail", "error"]
            ) {
                return message
            }
        }
        return nil
    }
}
