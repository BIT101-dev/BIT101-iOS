import Foundation

/// 学校 JWB 系列业务由 bit-login 创建的短期统一认证挑战。
///
/// `accessToken` 只保存在内存里，不会写入 UserDefaults 或 Keychain。
struct BITLoginAuthenticationChallenge: Identifiable, Equatable {
    let challengeID: String
    let accessToken: String
    let status: String
    let maskedPhone: String?
    let expiresIn: Int?
    let receivedAt: Date

    var id: String { challengeID }

    var isExpired: Bool {
        guard let expiresIn else { return false }
        return Date() >= receivedAt.addingTimeInterval(TimeInterval(expiresIn))
    }

    init(
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

struct BITLoginSMSCodeRequest: Encodable {
    let code: String
}

struct BITLoginChallengeEnvelope: Decodable {
    let detail: BITLoginChallengePayload
}

struct BITLoginChallengePayload: Decodable {
    let challengeID: String
    let accessToken: String?
    let status: String
    let maskedPhone: String?
    let expiresIn: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, error
        case challengeID = "challenge_id"
        case accessToken = "access_token"
        case maskedPhone = "masked_phone"
        case expiresIn = "expires_in"
    }
}

/// 成绩和课表共用 bit-login 的协议细节；各业务仍保留各自的会话与错误语义。
enum BITLoginChallengeSupport {
    static func decodePayload(from data: Data) throws -> BITLoginChallengePayload {
        try JSONDecoder().decode(BITLoginChallengePayload.self, from: data)
    }

    static func pollUntilActionable(
        _ initialPayload: BITLoginChallengePayload,
        timeout: TimeInterval,
        interval: Duration,
        fetch: (String) async throws -> BITLoginChallengePayload
    ) async throws -> BITLoginChallengePayload {
        var payload = initialPayload
        let deadline = Date().addingTimeInterval(timeout)

        while ["running", "processing"].contains(payload.status), Date() < deadline {
            try await Task.sleep(for: interval)
            payload = try await fetch(payload.challengeID)
        }
        return payload
    }

    static func challenge(
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

    static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
            let message = (detail["message"] as? String) ?? (detail["error"] as? String)
            if let message, !message.isEmpty {
                return message
            }
        }
        return nil
    }
}
