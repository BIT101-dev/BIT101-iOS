import Foundation

/// 成绩查询过程中由服务端创建的短期统一认证挑战。
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

/// 原生成绩查询的统一错误定义。
enum ScoreServiceError: LocalizedError {
    case missingCredentials
    case invalidResponse
    case requestTimedOut
    case secondFactorRequired(BITLoginAuthenticationChallenge)
    case challengeInvalid(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "未找到已保存的学号和密码，请先重新登录。"
        case .invalidResponse:
            return "成绩服务返回了无法识别的数据。"
        case .requestTimedOut:
            return "请求超时，请稍后重试。"
        case .secondFactorRequired:
            return "需要短信验证码才能继续查询成绩。"
        case let .challengeInvalid(message):
            return message
        case let .queryFailed(message):
            return message
        }
    }
}

/// 成绩接口层。
///
/// 首次查询仍直接提交已保存的统一认证账号密码。服务端若返回 `202`，则把短期挑战交给
/// SwiftUI 页面收集短信验证码；验证成功后改用 Bearer challenge 获取成绩。
struct ScoreService {
    private struct ScoreRequest: Encodable {
        let username: String?
        let password: String?
        let challengeID: String?
        let detail: Bool

        enum CodingKeys: String, CodingKey {
            case username, password, detail
            case challengeID = "challenge_id"
        }
    }

    private struct SMSCodeRequest: Encodable {
        let code: String
    }

    private struct ScoreResponse: Decodable {
        let msg: String?
        let data: [[String]]
    }

    private struct ChallengeEnvelope: Decodable {
        let detail: ChallengePayload
    }

    private struct ChallengePayload: Decodable {
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

    private let storage: LoginStorage
    private let session: URLSession
    private static let requestTimeoutSeconds: TimeInterval = 25
    /// 统一认证首次启动 OCR/下游会话时可能明显慢于普通 HTTP 请求，不能共用 25 秒单请求超时。
    private static let authenticationWaitSeconds: TimeInterval = 90
    private let endpointBaseURL: URL

    init(storage: LoginStorage = .shared) {
        self.storage = storage
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = Self.requestTimeoutSeconds
        self.session = URLSession(configuration: configuration)

        if
            let configured = Bundle.main.object(forInfoDictionaryKey: "BIT101BitLoginURL") as? String,
            let url = URL(string: configured.trimmingCharacters(in: .whitespacesAndNewlines)),
            !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            endpointBaseURL = url
        } else {
            endpointBaseURL = URL(string: "https://login.bit101.flwfdd.xyz")!
        }
    }

    /// 用账号密码发起成绩查询；需要二次认证时抛出携带短期挑战的错误。
    func fetchScores(detail: Bool) async throws -> [ScoreRow] {
        let studentID = storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = storage.currentPassword

        guard !studentID.isEmpty, !password.isEmpty else {
            throw ScoreServiceError.missingCredentials
        }

        let body = ScoreRequest(
            username: studentID,
            password: password,
            challengeID: nil,
            detail: detail
        )
        return try await performScoreRequest(body: body, authorization: nil, detail: detail)
    }

    /// 提交系统短信自动填充得到的验证码，并在认证完成后继续原成绩请求。
    func submitSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge,
        detail: Bool
    ) async throws -> [ScoreRow] {
        guard !challenge.isExpired else {
            throw ScoreServiceError.challengeInvalid("验证码已过期，请重新查询成绩。")
        }
        var request = URLRequest(
            url: endpointBaseURL.appending(path: "api/auth/\(challenge.challengeID)/sms")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(challenge.accessToken, forHTTPHeaderField: "X-Challenge-Token")
        request.httpBody = try JSONEncoder().encode(SMSCodeRequest(code: code))

        let (data, response) = try await send(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            let message = messageFromErrorResponse(data) ?? "短信验证码验证失败。"
            if [403, 404, 409].contains(response.statusCode) {
                throw ScoreServiceError.challengeInvalid(
                    "本次验证已失效或验证码已提交，请重新查询成绩。\n\(message)"
                )
            }
            throw ScoreServiceError.queryFailed(message)
        }

        let payload = try decodeChallengePayload(data)
        let current = try await waitUntilActionable(
            payload,
            accessToken: challenge.accessToken
        )
        return try await finishAuthentication(current, detail: detail)
    }

    private func performScoreRequest(
        body: ScoreRequest,
        authorization: String?,
        detail: Bool
    ) async throws -> [ScoreRow] {
        var request = URLRequest(url: endpointBaseURL.appending(path: "api/jwb/bit101/score"))
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await send(request)
        if response.statusCode == 202 {
            let envelope = try? JSONDecoder().decode(ChallengeEnvelope.self, from: data)
            guard
                let payload = envelope?.detail,
                let accessToken = payload.accessToken,
                !accessToken.isEmpty
            else {
                throw ScoreServiceError.invalidResponse
            }
            let current = try await waitUntilActionable(payload, accessToken: accessToken)
            return try await finishAuthentication(current, detail: detail)
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            throw ScoreServiceError.queryFailed(
                messageFromErrorResponse(data) ?? "成绩查询失败。"
            )
        }
        return try decodeScoreRows(data)
    }

    private func finishAuthentication(
        _ challenge: BITLoginAuthenticationChallenge,
        detail: Bool
    ) async throws -> [ScoreRow] {
        switch challenge.status {
        case "authenticated":
            let body = ScoreRequest(
                username: nil,
                password: nil,
                challengeID: challenge.challengeID,
                detail: detail
            )
            return try await performScoreRequest(
                body: body,
                authorization: challenge.accessToken,
                detail: detail
            )
        case "waiting_sms":
            throw ScoreServiceError.secondFactorRequired(challenge)
        case "expired":
            throw ScoreServiceError.challengeInvalid("验证码已过期，请重新查询成绩。")
        case "failed":
            throw ScoreServiceError.challengeInvalid("统一身份认证失败，请重新查询成绩。")
        default:
            throw ScoreServiceError.queryFailed("统一身份认证暂未完成，请稍后重试。")
        }
    }

    /// 初次成绩请求通常会在认证线程仍为 `running` 时返回，短暂轮询到可交互状态。
    private func waitUntilActionable(
        _ initialPayload: ChallengePayload,
        accessToken: String
    ) async throws -> BITLoginAuthenticationChallenge {
        var payload = initialPayload
        let deadline = Date().addingTimeInterval(Self.authenticationWaitSeconds)

        while ["running", "processing"].contains(payload.status), Date() < deadline {
            try await Task.sleep(for: .seconds(1))

            var request = URLRequest(
                url: endpointBaseURL.appending(path: "api/auth/\(payload.challengeID)")
            )
            request.timeoutInterval = Self.requestTimeoutSeconds
            request.setValue(accessToken, forHTTPHeaderField: "X-Challenge-Token")
            let (data, response) = try await send(request)
            guard (200 ..< 300).contains(response.statusCode) else {
                throw ScoreServiceError.queryFailed(
                    messageFromErrorResponse(data) ?? "无法获取统一身份认证状态。"
                )
            }
            payload = try decodeChallengePayload(data)
        }

        if payload.status == "failed", let error = payload.error, !error.isEmpty {
            throw ScoreServiceError.challengeInvalid(error)
        }

        return BITLoginAuthenticationChallenge(
            challengeID: payload.challengeID,
            accessToken: accessToken,
            status: payload.status,
            maskedPhone: payload.maskedPhone,
            expiresIn: payload.expiresIn
        )
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ScoreServiceError.invalidResponse
            }
            return (data, httpResponse)
        } catch let error as URLError where error.code == .timedOut {
            throw ScoreServiceError.requestTimedOut
        }
    }

    private func decodeChallengePayload(_ data: Data) throws -> ChallengePayload {
        do {
            return try JSONDecoder().decode(ChallengePayload.self, from: data)
        } catch {
            throw ScoreServiceError.invalidResponse
        }
    }

    private func decodeScoreRows(_ data: Data) throws -> [ScoreRow] {
        let payload: ScoreResponse
        do {
            payload = try JSONDecoder().decode(ScoreResponse.self, from: data)
        } catch {
            throw ScoreServiceError.invalidResponse
        }

        guard !payload.data.isEmpty else {
            throw ScoreServiceError.queryFailed(payload.msg ?? "没有查询到成绩数据。")
        }

        let headers = payload.data[0]
        return payload.data.dropFirst().enumerated().map { index, row in
            ScoreRow(index: index, headers: headers, values: row)
        }
    }

    private func messageFromErrorResponse(_ data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return String(data: data, encoding: .utf8)
        }

        if let msg = json["msg"] as? String, !msg.isEmpty {
            return msg
        }
        if let detail = json["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if
            let detail = json["detail"] as? [String: Any],
            let message = (detail["message"] as? String) ?? (detail["error"] as? String),
            !message.isEmpty
        {
            return message
        }
        return nil
    }
}
