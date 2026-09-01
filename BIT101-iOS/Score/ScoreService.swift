import Foundation

/// 普通成绩与可信成绩单共用的错误定义。
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
/// 查询先建立短期统一认证 challenge，再复用同一会话依次获取简略与详细成绩。
/// 服务端需要二次认证时，把 challenge 交给 SwiftUI 页面收集短信验证码。
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

    private struct AuthenticationStartRequest: Encodable {
        let username: String
        let password: String
        let services: [String]
        let waitSeconds: Double

        enum CodingKeys: String, CodingKey {
            case username, password, services
            case waitSeconds = "wait_seconds"
        }
    }

    /// 可信成绩单使用独立的 `jwb_cjd` 登录服务，不能复用普通成绩查询的 jwb challenge。
    private struct TranscriptRequest: Encodable {
        let username: String?
        let password: String?
        let challengeID: String?
        let detailed = false

        enum CodingKeys: String, CodingKey {
            case username, password, detailed
            case challengeID = "challenge_id"
        }
    }

    private struct CookieResponse: Decodable {
        let cookieString: String

        enum CodingKeys: String, CodingKey {
            case cookieString = "cookie_str"
        }
    }

    private struct ScoreResponse: Decodable {
        let msg: String?
        let data: [[String]]
    }

    private let storage: LoginStorage
    private let session: URLSession
    private static let requestTimeoutSeconds: TimeInterval = 25
    /// 统一认证首次启动 OCR/下游会话时可能明显慢于普通 HTTP 请求，不能共用 25 秒单请求超时。
    private static let authenticationWaitSeconds: TimeInterval = 90
    private let endpointBaseURL: URL

    init(storage: LoginStorage = .shared) {
        self.storage = storage
        session = NetworkSessionPool.scoreAuthentication

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

    /// 建立一次 JWB 会话，供简略成绩与详细成绩两个阶段复用。
    func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
        let studentID = storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = storage.currentPassword
        guard !studentID.isEmpty, !password.isEmpty else {
            throw ScoreServiceError.missingCredentials
        }

        var request = URLRequest(url: endpointBaseURL.appending(path: "api/auth/start"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.authenticationWaitSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AuthenticationStartRequest(
                username: studentID,
                password: password,
                services: ["jwb"],
                waitSeconds: 1
            )
        )

        let (data, response) = try await send(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ScoreServiceError.queryFailed(
                BITLoginChallengeSupport.errorMessage(from: data) ?? "无法启动成绩认证。"
            )
        }
        let payload = try decodeBITLoginChallengePayload(data)
        guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw ScoreServiceError.invalidResponse
        }
        let challenge = try await waitUntilActionable(payload, accessToken: accessToken)
        if challenge.status == "waiting_sms" {
            throw ScoreServiceError.secondFactorRequired(challenge)
        }
        guard challenge.status == "authenticated" else {
            throw ScoreServiceError.challengeInvalid(
                payload.error ?? "统一身份认证失败，请重新查询成绩。"
            )
        }
        return challenge
    }

    /// 使用已经认证的会话查询成绩，避免两个阶段重复统一身份认证。
    func fetchScores(
        detail: Bool,
        authenticatedBy challenge: BITLoginAuthenticationChallenge
    ) async throws -> [ScoreRow] {
        try await finishAuthentication(challenge, detail: detail)
    }

    /// 只完成短信认证；认证后的同一 challenge 仍可连续查询简略及详细成绩。
    func submitScoreSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> BITLoginAuthenticationChallenge {
        let current = try await submitSMSAuthentication(code, for: challenge)
        guard current.status == "authenticated" else {
            if current.status == "waiting_sms" {
                throw ScoreServiceError.secondFactorRequired(current)
            }
            throw ScoreServiceError.challengeInvalid("统一身份认证失败，请重新查询成绩。")
        }
        return current
    }

    /// 向 bit-login 的 `jwb_cjd` 服务申请由学校实时生成的可信成绩单。
    func fetchTrustedTranscriptPages() async throws -> [Data] {
        let studentID = storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = storage.currentPassword
        guard !studentID.isEmpty, !password.isEmpty else {
            throw ScoreServiceError.missingCredentials
        }

        return try await performTranscriptRequest(
            body: TranscriptRequest(
                username: studentID,
                password: password,
                challengeID: nil
            ),
            authorization: nil
        )
    }

    /// 完成可信成绩单自己的短信挑战，并继续原申请。
    func submitTranscriptSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> [Data] {
        let current = try await submitSMSAuthentication(code, for: challenge)
        return try await finishTranscriptAuthentication(current)
    }

    /// 提交任一 JWB 系列 challenge 的短信验证码，并返回认证后的 challenge 状态。
    private func submitSMSAuthentication(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> BITLoginAuthenticationChallenge {
        guard !challenge.isExpired else {
            throw ScoreServiceError.challengeInvalid("验证码已过期，请重新发起本次操作。")
        }
        var request = URLRequest(
            url: endpointBaseURL.appending(path: "api/auth/\(challenge.challengeID)/sms")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(challenge.accessToken, forHTTPHeaderField: "X-Challenge-Token")
        request.httpBody = try JSONEncoder().encode(BITLoginSMSCodeRequest(code: code))

        let (data, response) = try await send(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            let message = BITLoginChallengeSupport.errorMessage(from: data) ?? "短信验证码验证失败。"
            if [403, 404, 409].contains(response.statusCode) {
                throw ScoreServiceError.challengeInvalid(
                    "本次验证已失效或验证码已提交，请重新发起操作。\n\(message)"
                )
            }
            throw ScoreServiceError.queryFailed(message)
        }

        let payload = try decodeBITLoginChallengePayload(data)
        let current = try await waitUntilActionable(
            payload,
            accessToken: challenge.accessToken
        )
        return current
    }

    private func performTranscriptRequest(
        body: TranscriptRequest,
        authorization: String?,
        remainingTransientRetries: Int = 2
    ) async throws -> [Data] {
        var request = URLRequest(url: endpointBaseURL.appending(path: "api/jwb/cjd/cookies"))
        request.timeoutInterval = Self.authenticationWaitSeconds
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await send(request)
        if response.statusCode == 202 {
            guard
                let envelope = try? JSONDecoder().decode(BITLoginChallengeEnvelope.self, from: data),
                let accessToken = envelope.detail.accessToken,
                !accessToken.isEmpty
            else {
                throw ScoreServiceError.invalidResponse
            }
            let current = try await waitUntilActionable(envelope.detail, accessToken: accessToken)
            return try await finishTranscriptAuthentication(current)
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            // 已完成认证后，学校生成成绩单的页面偶尔会暂时返回 5xx。复用同一个 challenge
            // 多试几次不会重复登录或重复发送短信，也比让用户从头申请安全、快速。
            if
                authorization != nil,
                remainingTransientRetries > 0,
                [500, 502, 503, 504].contains(response.statusCode)
            {
                try await Task.sleep(for: .milliseconds(800))
                return try await performTranscriptRequest(
                    body: body,
                    authorization: authorization,
                    remainingTransientRetries: remainingTransientRetries - 1
                )
            }

            if [500, 502, 503, 504].contains(response.statusCode) {
                throw ScoreServiceError.queryFailed(
                    "学校可信成绩单服务暂时不可用，请稍后重新申请。"
                )
            }
            throw ScoreServiceError.queryFailed(
                BITLoginChallengeSupport.errorMessage(from: data) ?? "可信成绩单申请失败。"
            )
        }

        let payload: CookieResponse
        do {
            payload = try JSONDecoder().decode(CookieResponse.self, from: data)
        } catch {
            throw ScoreServiceError.invalidResponse
        }
        return try await downloadTranscriptPages(cookieString: payload.cookieString)
    }

    /// 使用成绩单系统 Cookie 读取申请结果页，并下载其中全部分页图片。
    ///
    /// bit-login 的图片接口历史上只返回第一张图片；直接解析学校结果页才能在成绩较多时
    /// 保留第二页及后续页面。Cookie 与图片都仅存在于临时内存会话中。
    private func downloadTranscriptPages(cookieString: String) async throws -> [Data] {
        guard !cookieString.isEmpty else { throw ScoreServiceError.invalidResponse }

        let reportURL = URL(string: "https://jwb.bit.edu.cn/cjd/ScoreReport2/Index?GPA=1")!
        var reportRequest = URLRequest(url: reportURL)
        reportRequest.timeoutInterval = Self.authenticationWaitSeconds
        reportRequest.setValue(cookieString, forHTTPHeaderField: "Cookie")

        let report: HTTPResponse
        do {
            report = try await HTTPClient(transport: NetworkSessionPool.sensitiveDownloads)
                .send(reportRequest)
        } catch {
            throw ScoreServiceError.queryFailed("学校可信成绩单页面暂时无法访问，请重新申请。")
        }
        guard let html = String(data: report.data, encoding: .utf8) else {
            throw ScoreServiceError.invalidResponse
        }

        let pattern = #"<img\b[^>]*\bsrc\s*=\s*[\"']([^\"']*/cjd/Temp/[^\"']+)[\"']"#
        let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let htmlRange = NSRange(html.startIndex..., in: html)
        var pageURLs: [URL] = []
        for match in expression.matches(in: html, range: htmlRange) {
            guard
                let range = Range(match.range(at: 1), in: html),
                let url = URL(string: String(html[range]), relativeTo: reportURL)?.absoluteURL,
                !pageURLs.contains(url)
            else { continue }
            pageURLs.append(url)
        }
        guard !pageURLs.isEmpty else {
            throw ScoreServiceError.queryFailed("学校未返回可识别的成绩单页面，请重新申请。")
        }

        var pages: [Data] = []
        for url in pageURLs {
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.requestTimeoutSeconds
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")
            let response = try await HTTPClient(transport: NetworkSessionPool.sensitiveDownloads)
                .send(request)
            guard !response.data.isEmpty else {
                throw ScoreServiceError.invalidResponse
            }
            pages.append(response.data)
        }
        return pages
    }

    private func finishTranscriptAuthentication(
        _ challenge: BITLoginAuthenticationChallenge
    ) async throws -> [Data] {
        switch challenge.status {
        case "authenticated":
            return try await performTranscriptRequest(
                body: TranscriptRequest(
                    username: nil,
                    password: nil,
                    challengeID: challenge.challengeID
                ),
                authorization: challenge.accessToken
            )
        case "waiting_sms":
            throw ScoreServiceError.secondFactorRequired(challenge)
        case "expired":
            throw ScoreServiceError.challengeInvalid("验证码已过期，请重新申请可信成绩单。")
        case "failed":
            throw ScoreServiceError.challengeInvalid("统一身份认证失败，请重新申请可信成绩单。")
        default:
            throw ScoreServiceError.queryFailed("统一身份认证暂未完成，请稍后重试。")
        }
    }

    private func performScoreRequest(
        body: ScoreRequest,
        authorization: String?,
        detail: Bool
    ) async throws -> [ScoreRow] {
        var request = URLRequest(url: endpointBaseURL.appending(path: "api/jwb/bit101/score"))
        // 完整模式需要学校端逐门补全均分与排名，不应被普通单请求的 25 秒上限截断。
        request.timeoutInterval = detail
            ? Self.authenticationWaitSeconds
            : Self.requestTimeoutSeconds
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await send(request)
        if response.statusCode == 202 {
            let envelope = try? JSONDecoder().decode(BITLoginChallengeEnvelope.self, from: data)
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
                BITLoginChallengeSupport.errorMessage(from: data) ?? "成绩查询失败。"
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

    /// 初次 JWB 业务请求通常会在认证线程仍为 `running` 时返回，短暂轮询到可交互状态。
    private func waitUntilActionable(
        _ initialPayload: BITLoginChallengePayload,
        accessToken: String
    ) async throws -> BITLoginAuthenticationChallenge {
        // 与 Android/Web 端保持一致；1 秒轮询会在认证完成后额外平白等待最多近 1 秒。
        let payload = try await BITLoginChallengeSupport.pollUntilActionable(
            initialPayload,
            timeout: Self.authenticationWaitSeconds,
            interval: .milliseconds(350)
        ) { challengeID in
            var request = URLRequest(
                url: endpointBaseURL.appending(path: "api/auth/\(challengeID)")
            )
            request.timeoutInterval = Self.requestTimeoutSeconds
            request.setValue(accessToken, forHTTPHeaderField: "X-Challenge-Token")
            let (data, response) = try await send(request)
            guard (200 ..< 300).contains(response.statusCode) else {
                throw ScoreServiceError.queryFailed(
                    BITLoginChallengeSupport.errorMessage(from: data) ?? "无法获取统一身份认证状态。"
                )
            }
            return try decodeBITLoginChallengePayload(data)
        }

        if payload.status == "failed", let error = payload.error, !error.isEmpty {
            throw ScoreServiceError.challengeInvalid(error)
        }

        return BITLoginChallengeSupport.challenge(from: payload, accessToken: accessToken)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let response = try await HTTPClient(transport: session).send(
                request,
                accepting: 100 ..< 600
            )
            return (response.data, response.response)
        } catch let error as URLError where error.code == .timedOut {
            throw ScoreServiceError.requestTimedOut
        } catch is HTTPClientError {
            throw ScoreServiceError.invalidResponse
        }
    }

    private func decodeBITLoginChallengePayload(_ data: Data) throws -> BITLoginChallengePayload {
        do {
            return try BITLoginChallengeSupport.decodePayload(from: data)
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

}
