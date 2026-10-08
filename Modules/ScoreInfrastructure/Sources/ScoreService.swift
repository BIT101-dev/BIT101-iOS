import ScoreDomain
import TransportCore
import ClientCore
import Foundation

/// 成绩接口层。
///
/// 查询先建立短期统一认证 challenge，再复用同一会话依次获取简略与详细成绩。
/// 服务端需要二次认证时，把 challenge 交给 SwiftUI 页面收集短信验证码。
public struct ScoreService {
    public let transcriptServiceIdentity: AnyHashable = UUID()
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

    /// 可信成绩单使用独立的 `jwb_cjd` 登录服务，普通成绩查询使用 `jwb` challenge。
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

    private nonisolated struct CookieResponse: Decodable, Sendable {
        let cookieString: String

        enum CodingKeys: String, CodingKey {
            case cookieString = "cookie_str"
        }
    }

    private nonisolated struct ScoreResponse: Decodable, Sendable {
        let msg: String?
        let data: [[String]]
    }

    private let credentials: any SchoolCredentialsProviding
    private let httpClient: HTTPClient
    private let sensitiveHTTPClient: HTTPClient
    private nonisolated static let requestTimeoutSeconds: TimeInterval = 25
    /// 统一认证首次启动 OCR/下游会话时长可能超过普通 HTTP 请求，使用 90 秒认证等待时限。
    private static let authenticationWaitSeconds: TimeInterval = 90
    private let endpointBaseURL: URL
    private let transcriptLimits: TrustedTranscriptResourceLimits

    public init(
        credentials: any SchoolCredentialsProviding,
        httpClient: HTTPClient,
        sensitiveHTTPClient: HTTPClient,
        endpointBaseURL: URL,
        transcriptLimits: TrustedTranscriptResourceLimits = .init()
    ) {
        self.credentials = credentials
        self.httpClient = httpClient
        self.sensitiveHTTPClient = sensitiveHTTPClient
        self.endpointBaseURL = endpointBaseURL
        self.transcriptLimits = transcriptLimits
    }

    /// 建立一次 JWB 会话，供简略成绩与详细成绩两个阶段复用。
    public func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
        let owner = credentials.schoolSessionIdentity
        let studentID = credentials.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = credentials.currentPassword
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

        let (data, response) = try await send(request, owner: owner)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ScoreServiceError.queryFailed(
                BITLoginChallengeSupport.errorMessage(from: data) ?? "无法启动成绩认证。"
            )
        }
        let payload = try decodeBITLoginChallengePayload(data)
        guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw ScoreServiceError.invalidResponse
        }
        let challenge = try await waitUntilActionable(payload, accessToken: accessToken, owner: owner)
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

    /// 使用已经认证的会话查询成绩，让简略成绩与详细成绩共享一次统一身份认证。
    public func fetchScores(
        detail: Bool,
        authenticatedBy challenge: BITLoginAuthenticationChallenge
    ) async throws -> [ScoreRow] {
        try await finishAuthentication(challenge, detail: detail)
    }

    /// 完成短信认证，并返回可继续查询简略及详细成绩的 challenge 状态。
    public func submitScoreSMSCode(
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
    public func fetchTrustedTranscriptPages() async throws -> [Data] {
        let owner = credentials.schoolSessionIdentity
        let studentID = credentials.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = credentials.currentPassword
        guard !studentID.isEmpty, !password.isEmpty else {
            throw ScoreServiceError.missingCredentials
        }

        return try await performTranscriptRequest(
            body: TranscriptRequest(
                username: studentID,
                password: password,
                challengeID: nil
            ),
            authorization: nil,
            owner: owner
        )
    }

    /// 完成可信成绩单自己的短信挑战，并继续原申请。
    public func submitTranscriptSMSCode(
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
        let owner = try authenticationOwner(challenge)
        var request = URLRequest(
            url: endpointBaseURL.appending(path: "api/auth/\(challenge.challengeID)/sms")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(challenge.accessToken, forHTTPHeaderField: "X-Challenge-Token")
        request.httpBody = try JSONEncoder().encode(BITLoginSMSCodeRequest(code: code))

        let (data, response) = try await send(request, owner: owner)
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
            accessToken: challenge.accessToken,
            owner: owner
        )
        return current
    }

    private func performTranscriptRequest(
        body: TranscriptRequest,
        authorization: String?,
        owner: SchoolSessionIdentity,
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

        let (data, response) = try await send(request, owner: owner)
        if response.statusCode == 202 {
            guard
                let envelope = try? JSONDecoder().decode(BITLoginChallengeEnvelope.self, from: data),
                let accessToken = envelope.detail.accessToken,
                !accessToken.isEmpty
            else {
                throw ScoreServiceError.invalidResponse
            }
            let current = try await waitUntilActionable(envelope.detail, accessToken: accessToken, owner: owner)
            return try await finishTranscriptAuthentication(current)
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            // 已完成认证后，学校生成成绩单的页面偶尔会暂时返回 5xx。复用同一个 challenge
            // 进行重试，沿用已完成的认证与短信状态，保持当前申请流程连续。
            if
                authorization != nil,
                remainingTransientRetries > 0,
                [500, 502, 503, 504].contains(response.statusCode)
            {
                try await Task.sleep(for: .milliseconds(800))
                return try await performTranscriptRequest(
                    body: body,
                    authorization: authorization,
                    owner: owner,
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
        let cookieString = payload.cookieString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookieString.isEmpty else {
            throw ScoreServiceError.invalidResponse
        }
        return try await downloadTranscriptPages(cookieString: cookieString, owner: owner)
    }

    /// 使用成绩单系统 Cookie 读取申请结果页，并下载其中全部分页图片。
    ///
    /// 解析学校结果页中的全部分页图片，覆盖成绩较多时的多页结果。Cookie 与图片的生命周期属于临时内存会话。
    private func downloadTranscriptPages(cookieString: String, owner: SchoolSessionIdentity) async throws -> [Data] {
        guard !cookieString.isEmpty else { throw ScoreServiceError.invalidResponse }

        let reportURL = AppURL.required("https://jwb.bit.edu.cn/cjd/ScoreReport2/Index?GPA=1")
        var reportRequest = URLRequest(url: reportURL)
        reportRequest.timeoutInterval = Self.authenticationWaitSeconds
        reportRequest.setValue(cookieString, forHTTPHeaderField: "Cookie")

        let report: HTTPResponse
        do {
            report = try await ownedResponse(reportRequest, using: sensitiveHTTPClient, owner: owner,
                maximumBytes: transcriptLimits.maximumEncodedBytes)
        } catch {
            if TaskCancellation.matches(error) { throw error }
            throw ScoreServiceError.queryFailed("学校可信成绩单页面暂时无法访问，请重新申请。")
        }
        guard (200 ..< 300).contains(report.response.statusCode) else {
            throw ScoreServiceError.queryFailed("学校可信成绩单页面暂时无法访问，请重新申请。")
        }
        guard let html = String(data: report.data, encoding: .utf8) else {
            throw ScoreServiceError.invalidResponse
        }

        let pattern = #"<img\b[^>]*\bsrc\s*=\s*[\"']([^\"']*/cjd/Temp/[^\"']+)[\"']"#
        let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let htmlRange = NSRange(html.startIndex..., in: html)
        var pageURLs: [URL] = []
        expression.enumerateMatches(in: html, range: htmlRange) { match, _, stop in
            guard
                let match,
                let range = Range(match.range(at: 1), in: html),
                let url = URL(string: String(html[range]), relativeTo: reportURL)?.absoluteURL,
                url.scheme == reportURL.scheme,
                url.host == reportURL.host,
                url.port == reportURL.port,
                !pageURLs.contains(url)
            else { return }
            pageURLs.append(url)
            if pageURLs.count > transcriptLimits.maximumPageCount { stop.pointee = true }
        }
        guard pageURLs.count <= transcriptLimits.maximumPageCount else { throw HTTPClientError.responseTooLarge }
        guard !pageURLs.isEmpty else {
            throw ScoreServiceError.queryFailed("学校未返回可识别的成绩单页面，请重新申请。")
        }

        var pages: [Data] = []
        var remainingBytes = transcriptLimits.maximumEncodedBytes
        for url in pageURLs {
            guard remainingBytes > 0 else { throw HTTPClientError.responseTooLarge }
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.requestTimeoutSeconds
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")
            let response = try await ownedResponse(request, using: sensitiveHTTPClient, owner: owner, maximumBytes: remainingBytes)
            guard !response.data.isEmpty else {
                throw ScoreServiceError.invalidResponse
            }
            pages.append(response.data)
            remainingBytes -= response.data.count
        }
        return pages
    }

    private func finishTranscriptAuthentication(
        _ challenge: BITLoginAuthenticationChallenge
    ) async throws -> [Data] {
        let owner = try authenticationOwner(challenge)
        switch challenge.status {
        case "authenticated":
            return try await performTranscriptRequest(
                body: TranscriptRequest(
                    username: nil,
                    password: nil,
                    challengeID: challenge.challengeID
                ),
                authorization: challenge.accessToken,
                owner: owner
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
        owner: SchoolSessionIdentity,
        detail: Bool
    ) async throws -> [ScoreRow] {
        var request = URLRequest(url: endpointBaseURL.appending(path: "api/jwb/bit101/score"))
        // 完整模式需要学校端逐门补全均分与排名，使用独立的 90 秒请求时限。
        request.timeoutInterval = detail
            ? Self.authenticationWaitSeconds
            : Self.requestTimeoutSeconds
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await send(request, owner: owner)
        if response.statusCode == 202 {
            let envelope = try? JSONDecoder().decode(BITLoginChallengeEnvelope.self, from: data)
            guard
                let payload = envelope?.detail,
                let accessToken = payload.accessToken,
                !accessToken.isEmpty
            else {
                throw ScoreServiceError.invalidResponse
            }
            let current = try await waitUntilActionable(payload, accessToken: accessToken, owner: owner)
            return try await finishAuthentication(current, detail: detail)
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            throw ScoreServiceError.queryFailed(
                BITLoginChallengeSupport.errorMessage(from: data) ?? "成绩查询失败。"
            )
        }
        let rows = try await Self.decodeScoreRowsOffMain(data)
        try validateOwner(owner)
        return rows
    }

    private func finishAuthentication(
        _ challenge: BITLoginAuthenticationChallenge,
        detail: Bool
    ) async throws -> [ScoreRow] {
        let owner = try authenticationOwner(challenge)
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
                owner: owner,
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
        accessToken: String,
        owner: SchoolSessionIdentity
    ) async throws -> BITLoginAuthenticationChallenge {
        // 以 350ms 间隔轮询认证状态，服务端完成认证后衔接成绩查询。
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
            let (data, response) = try await send(request, owner: owner)
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

        try validateOwner(owner)
        return BITLoginChallengeSupport.challenge(from: payload, accessToken: accessToken, ownerIdentity: owner)
    }

    private func send(_ request: URLRequest, owner: SchoolSessionIdentity) async throws -> (Data, HTTPURLResponse) {
        do {
            let response = try await ownedResponse(request, using: httpClient, owner: owner, accepting: 100 ..< 600)
            return (response.data, response.response)
        } catch let error as URLError where error.code == .timedOut {
            throw ScoreServiceError.requestTimedOut
        } catch is HTTPClientError {
            throw ScoreServiceError.invalidResponse
        }
    }

    private func validateOwner(_ owner: SchoolSessionIdentity) throws {
        try Task.checkCancellation()
        guard credentials.schoolSessionIdentity == owner else { throw CancellationError() }
    }

    private func authenticationOwner(_ challenge: BITLoginAuthenticationChallenge) throws -> SchoolSessionIdentity {
        guard let owner = challenge.ownerIdentity else {
            throw ScoreServiceError.challengeInvalid("账号会话已更新，请重新发起本次操作。")
        }
        try validateOwner(owner)
        return owner
    }

    private func ownedResponse(_ request: URLRequest, using client: HTTPClient, owner: SchoolSessionIdentity,
        accepting: Range<Int> = 200 ..< 300, maximumBytes: Int? = nil) async throws -> HTTPResponse {
        try validateOwner(owner)
        do {
            let response = try await client.send(request, accepting: accepting, maximumBytes: maximumBytes)
            try validateOwner(owner)
            return response
        } catch {
            try validateOwner(owner)
            throw error
        }
    }

    private nonisolated func decodeBITLoginChallengePayload(_ data: Data) throws -> BITLoginChallengePayload {
        do {
            return try BITLoginChallengeSupport.decodePayload(from: data)
        } catch {
            throw ScoreServiceError.invalidResponse
        }
    }

    @concurrent
    private static func decodeScoreRowsOffMain(_ data: Data) async throws -> [ScoreRow] {
        try decodeScoreRows(data)
    }

    nonisolated static func decodeScoreRows(_ data: Data) throws -> [ScoreRow] {
        try Task.checkCancellation()
        let payload: ScoreResponse
        do {
            payload = try JSONDecoder().decode(ScoreResponse.self, from: data)
        } catch {
            throw ScoreServiceError.invalidResponse
        }
        try Task.checkCancellation()

        if let message = payload.msg, !message.hasPrefix("查询成功") {
            throw ScoreServiceError.queryFailed(message)
        }
        guard !payload.data.isEmpty else {
            if payload.msg?.hasPrefix("查询成功") == true {
                return []
            }
            throw ScoreServiceError.queryFailed(payload.msg ?? "没有查询到成绩数据。")
        }

        let headers = payload.data[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(headers).isSuperset(of: ["课程名称", "成绩"]),
              headers.allSatisfy({ !$0.isEmpty }), Set(headers).count == headers.count,
              payload.data.dropFirst().allSatisfy({ $0.count == headers.count })
        else { throw ScoreServiceError.invalidResponse }
        var rows: [ScoreRow] = []
        rows.reserveCapacity(payload.data.count - 1)
        for (index, row) in payload.data.dropFirst().enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            rows.append(ScoreRow(index: index, headers: headers, values: row))
        }
        return rows
    }

}

extension ScoreService: ScoreListServicing, TrustedTranscriptServicing {}
