import ScoreDomain
import ScorePorts
import TransportCore
import ClientCore
import Foundation

/// 成绩接口层。
///
/// 查询先建立短期统一认证 challenge，再复用同一会话依次获取简略与详细成绩。
/// 服务端需要二次认证时，把 challenge 交给 SwiftUI 页面收集图形或短信验证码。
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

    private let nativeAuthenticator: (any SchoolServiceAuthenticating)?
    private let nativeHTTPClient: HTTPClient
    private let nativeQueries = NativeSchoolScoreQueries()
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
        transcriptLimits: TrustedTranscriptResourceLimits = .init(),
        nativeAuthenticator: (any SchoolServiceAuthenticating)? = nil,
        nativeHTTPClient: HTTPClient? = nil
    ) {
        self.nativeAuthenticator = nativeAuthenticator
        self.nativeHTTPClient = nativeHTTPClient ?? httpClient
        self.credentials = credentials
        self.httpClient = httpClient
        self.sensitiveHTTPClient = sensitiveHTTPClient
        self.endpointBaseURL = endpointBaseURL
        self.transcriptLimits = transcriptLimits
    }

    /// 建立一次 JWB 会话，供简略成绩与详细成绩两个阶段复用。
    public func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
        if let nativeAuthenticator {
            let owner = credentials.schoolSessionIdentity
            do {
                let session = try await nativeAuthenticator.authenticate(.grades)
                try validateOwner(owner)
                guard session.owner == owner else { throw CancellationError() }
                return BITLoginAuthenticationChallenge(challengeID: "local-jwb", accessToken: "", status: "authenticated",
                    maskedPhone: nil, expiresIn: 300, ownerIdentity: owner, nativeSession: session)
            } catch {
                try validateOwner(owner)
                guard NativeSchoolAuthenticator.permitsFallback(error) else { throw error }
            }
        }
        return try await startRemoteScoreChallenge()
    }

    private func startRemoteScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
        try await credentials.prepareSchoolCredentials()
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

        let wire = try await send(request, owner: owner)
        let data = wire.data, response = wire.response
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ScoreServiceError.queryFailed(
                BITLoginChallengeSupport.errorMessage(from: data) ?? "无法启动成绩认证。"
            )
        }
        let payload = try await decodedChallenge(wire)
        guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw ScoreServiceError.invalidResponse
        }
        let challenge = try await waitUntilActionable(payload, accessToken: accessToken, owner: owner)
        if challenge.requiresVerification {
            throw ScoreServiceError.secondFactorRequired(challenge)
        }
        guard challenge.status == "authenticated" else {
            throw ScoreServiceError.challengeInvalid(
                challenge.error ?? "统一身份认证失败，请重新查询成绩。"
            )
        }
        return challenge
    }

    /// 使用已经认证的会话查询成绩，让简略成绩与详细成绩共享一次统一身份认证。
    public func fetchScores(
        detail: Bool,
        authenticatedBy challenge: BITLoginAuthenticationChallenge
    ) async throws -> [ScoreRow] {
        if let session = challenge.nativeSession {
            let owner = try authenticationOwner(challenge)
            guard session.owner == owner else { throw CancellationError() }
            let query = nativeQueries.query(for: challenge)
            if let remote = query.remoteChallenge, !remote.isExpired {
                return try await finishAuthentication(remote, detail: detail)
            }
            do {
                return try await NativeSchoolScoreReader(client: nativeHTTPClient,
                    validate: { try validateOwner(owner) }, query: query,
                    deadline: .now.advanced(by: .seconds(detail ? Self.authenticationWaitSeconds : Self.requestTimeoutSeconds)))
                    .fetch(detail: detail, session: session)
            } catch {
                try validateOwner(owner)
                if TaskCancellation.matches(error) || error is PartialScoreResult || SchoolServiceFailure.from(error) != nil { throw error }
                let fallback = try await startRemoteScoreChallenge()
                query.remoteChallenge = fallback
                return try await finishAuthentication(fallback, detail: detail)
            }
        }
        return try await finishAuthentication(challenge, detail: detail)
    }

    /// 完成验证，并返回可继续查询简略及详细成绩的 challenge 状态。
    public func submitScoreVerificationCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> BITLoginAuthenticationChallenge {
        let current = try await submitVerificationAuthentication(code, for: challenge)
        guard current.status == "authenticated" else {
            if current.requiresVerification {
                throw ScoreServiceError.secondFactorRequired(current)
            }
            throw ScoreServiceError.challengeInvalid(current.error ?? "统一身份认证失败，请重新查询成绩。")
        }
        return current
    }

    /// 向 bit-login 的 `jwb_cjd` 服务申请由学校实时生成的可信成绩单。
    public func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
        if let nativeAuthenticator {
            let owner = credentials.schoolSessionIdentity
            let session: SchoolAuthenticatedSession
            do {
                session = try await nativeAuthenticator.authenticate(.transcript)
                try validateOwner(owner)
                guard session.owner == owner, session.baseURL == SchoolServiceTarget.transcript.baseURL else { throw CancellationError() }
            } catch {
                try validateOwner(owner)
                guard NativeSchoolAuthenticator.permitsFallback(error) else { throw error }
                return try await fetchRemoteTranscriptPages(onPage: onPage)
            }
            var delivered = false
            let forward: TrustedTranscriptPageDelivery = { pages in
                delivered = true
                try await onPage?(pages)
            }
            do {
                return try await downloadTranscriptPages(cookieString: session.cookieHeader, owner: owner, onPage: forward)
            } catch {
                try validateOwner(owner)
                if TaskCancellation.matches(error) || delivered { throw error }
                return try await fetchRemoteTranscriptPages(onPage: onPage)
            }
        }
        return try await fetchRemoteTranscriptPages(onPage: onPage)
    }

    private func fetchRemoteTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
        try await credentials.prepareSchoolCredentials()
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
            owner: owner,
            onPage: onPage
        )
    }

    /// 完成可信成绩单验证挑战，返回可继续下载的认证会话。
    public func submitTranscriptVerificationCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> BITLoginAuthenticationChallenge {
        let current = try await submitVerificationAuthentication(code, for: challenge)
        guard current.status == "authenticated" else {
            if current.requiresVerification { throw ScoreServiceError.secondFactorRequired(current) }
            throw ScoreServiceError.challengeInvalid(current.error ?? "统一身份认证失败，请重新申请可信成绩单。")
        }
        return current
    }

    public func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
        try await finishTranscriptAuthentication(challenge, onPage: onPage)
    }

    /// 提交任一 JWB 系列 challenge 的图形或短信验证码，返回下一阶段状态。
    private func submitVerificationAuthentication(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> BITLoginAuthenticationChallenge {
        guard !challenge.isExpired else {
            throw ScoreServiceError.challengeInvalid("验证码已过期，请重新发起本次操作。")
        }
        let owner = try authenticationOwner(challenge)
        var request = try BITLoginChallengeSupport.verificationRequest(code: code, for: challenge, baseURL: endpointBaseURL)
        request.timeoutInterval = Self.requestTimeoutSeconds

        let wire = try await send(request, owner: owner)
        let data = wire.data, response = wire.response
        guard (200 ..< 300).contains(response.statusCode) else {
            let message = BITLoginChallengeSupport.errorMessage(from: data) ?? "验证码验证失败。"
            if [403, 404, 409].contains(response.statusCode) {
                throw ScoreServiceError.challengeInvalid(
                    "本次验证已失效或验证码已提交，请重新发起操作。\n\(message)"
                )
            }
            throw ScoreServiceError.queryFailed(message)
        }

        let payload = try await decodedChallenge(wire)
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
        onPage: TrustedTranscriptPageDelivery?,
        remainingTransientRetries: Int = 2
    ) async throws -> TrustedTranscriptPages {
        var request = URLRequest(url: endpointBaseURL.appending(path: "api/jwb/cjd/cookies"))
        request.timeoutInterval = Self.authenticationWaitSeconds
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let wire = try await send(request, owner: owner)
        let data = wire.data, response = wire.response
        if response.statusCode == 202 {
            guard authorization == nil else {
                throw ScoreServiceError.challengeInvalid("成绩单会话再次要求认证，请重新申请可信成绩单。")
            }
            let envelope = try await decodedEnvelope(wire)
            guard
                let accessToken = envelope.detail.accessToken,
                !accessToken.isEmpty
            else {
                throw ScoreServiceError.invalidResponse
            }
            let current = try await waitUntilActionable(envelope.detail, accessToken: accessToken, owner: owner)
            return try await finishTranscriptAuthentication(current, onPage: onPage)
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
                    onPage: onPage,
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

        let payload: CookieResponse = try await wire.validated { data, _ in
            do { return try JSONDecoder().decode(CookieResponse.self, from: data) }
            catch { throw ScoreServiceError.invalidResponse.caused(by: error) }
        }
        let cookieString = payload.cookieString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookieString.isEmpty else {
            throw ScoreServiceError.invalidResponse
        }
        return try await downloadTranscriptPages(cookieString: cookieString, owner: owner, onPage: onPage)
    }

    /// 使用成绩单系统 Cookie 读取申请结果页，并下载其中全部分页图片。
    ///
    /// 解析学校结果页中的全部分页图片，覆盖成绩较多时的多页结果。Cookie 与图片的生命周期属于临时内存会话。
    private func downloadTranscriptPages(cookieString: String, owner: SchoolSessionIdentity,
                                         onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
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
            throw ScoreServiceError.queryFailed("学校可信成绩单页面暂时无法访问，请重试。").caused(by: error)
        }
        guard (200 ..< 300).contains(report.response.statusCode) else {
            throw ScoreServiceError.queryFailed("学校可信成绩单页面暂时无法访问，请重新申请。")
        }
        try validateTranscriptSource(report.response, requestedURL: reportURL)
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
                (url.port ?? 443) == 443,
                url.path.hasPrefix("/cjd/Temp/"),
                !pageURLs.contains(url)
            else { return }
            pageURLs.append(url)
            if pageURLs.count > transcriptLimits.maximumPageCount { stop.pointee = true }
        }
        guard pageURLs.count <= transcriptLimits.maximumPageCount else { throw HTTPClientError.responseTooLarge }
        guard !pageURLs.isEmpty else {
            throw ScoreServiceError.queryFailed("学校未返回可识别的成绩单页面，请重新申请。")
        }

        let session = TrustedTranscriptReport(pageCount: pageURLs.count, timeout: transcriptLimits.maximumWait) { [self, pageURLs] number, maximumBytes in
            let url = pageURLs[number - 1]
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.requestTimeoutSeconds
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")
            let response: HTTPResponse
            do {
                response = try await ownedResponse(request, using: sensitiveHTTPClient, owner: owner, maximumBytes: maximumBytes)
            } catch let HTTPClientError.unacceptableStatus(code, message) where [401, 403, 404, 410].contains(code) {
                throw TrustedTranscriptReport.Failure.invalidSource(HTTPClientError.unacceptableStatus(code: code, message: message))
            } catch {
                if TaskCancellation.matches(error) { throw CancellationError() }
                throw error
            }
            do { try validateTranscriptSource(response.response, requestedURL: url) }
            catch { throw TrustedTranscriptReport.Failure.invalidSource(error) }
            return response.data
        }
        return try await session.loadPages(maximumBytes: transcriptLimits.maximumEncodedBytes, onPage: onPage)
    }

    private func validateTranscriptSource(_ response: HTTPURLResponse, requestedURL: URL) throws {
        guard let finalURL = response.url, finalURL.scheme == "https", finalURL.host == "jwb.bit.edu.cn",
              (finalURL.port ?? 443) == 443, finalURL.path == requestedURL.path else {
            throw ScoreServiceError.invalidResponse
        }
    }

    private func finishTranscriptAuthentication(
        _ challenge: BITLoginAuthenticationChallenge,
        onPage: TrustedTranscriptPageDelivery?
    ) async throws -> TrustedTranscriptPages {
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
                owner: owner,
                onPage: onPage
            )
        case "waiting_sms", "waiting_captcha":
            throw ScoreServiceError.secondFactorRequired(challenge)
        case "expired":
            throw ScoreServiceError.challengeInvalid("验证码已过期，请重新申请可信成绩单。")
        case "failed":
            throw ScoreServiceError.challengeInvalid(challenge.error ?? "统一身份认证失败，请重新申请可信成绩单。")
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

        let wire = try await send(request, owner: owner)
        let data = wire.data, response = wire.response
        if response.statusCode == 202 {
            guard authorization == nil else {
                throw ScoreServiceError.challengeInvalid("成绩查询会话再次要求认证，请重新查询成绩。")
            }
            let payload = try await decodedEnvelope(wire).detail
            guard
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
        let rows = try await wire.validated { data, _ in try await Self.decodeScoreRowsOffMain(data) }
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
        case "waiting_sms", "waiting_captcha":
            throw ScoreServiceError.secondFactorRequired(challenge)
        case "expired":
            throw ScoreServiceError.challengeInvalid("验证码已过期，请重新查询成绩。")
        case "failed":
            throw ScoreServiceError.challengeInvalid(challenge.error ?? "统一身份认证失败，请重新查询成绩。")
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
            let wire = try await send(request, owner: owner)
            let data = wire.data, response = wire.response
            guard (200 ..< 300).contains(response.statusCode) else {
                throw ScoreServiceError.queryFailed(
                    BITLoginChallengeSupport.errorMessage(from: data) ?? "无法获取统一身份认证状态。"
                )
            }
            return try await decodedChallenge(wire)
        }

        try validateOwner(owner)
        return BITLoginChallengeSupport.challenge(from: payload, accessToken: accessToken, ownerIdentity: owner)
    }

    private func send(_ request: URLRequest, owner: SchoolSessionIdentity) async throws -> HTTPResponse {
        do {
            let response = try await ownedResponse(request, using: httpClient, owner: owner, accepting: 100 ..< 600)
            return response
        } catch let error as URLError where error.code == .timedOut {
            throw ScoreServiceError.requestTimedOut.caused(by: error)
        } catch let error as HTTPClientError {
            throw ScoreServiceError.invalidResponse.caused(by: error)
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

    private func decodedChallenge(_ wire: HTTPResponse) async throws -> BITLoginChallengePayload {
        let payload = try await wire.validated { data, _ in try decodeBITLoginChallengePayload(data) }
        if payload.status == "failed" {
            await wire.reportValidationFailure(ScoreServiceError.challengeInvalid(payload.error ?? "统一身份认证失败。"))
        }
        return payload
    }

    private func decodedEnvelope(_ wire: HTTPResponse) async throws -> BITLoginChallengeEnvelope {
        let envelope = try await wire.validated { data, _ in
            let envelope = try decodeChallengeEnvelope(data)
            guard envelope.detail.accessToken?.isEmpty == false else { throw ScoreServiceError.invalidResponse }
            return envelope
        }
        if envelope.detail.status == "failed" {
            await wire.reportValidationFailure(ScoreServiceError.challengeInvalid(envelope.detail.error ?? "统一身份认证失败。"))
        }
        return envelope
    }

    private nonisolated func decodeChallengeEnvelope(_ data: Data) throws -> BITLoginChallengeEnvelope {
        do { return try JSONDecoder().decode(BITLoginChallengeEnvelope.self, from: data) }
        catch { throw ScoreServiceError.invalidResponse.caused(by: error) }
    }

    private nonisolated func decodeBITLoginChallengePayload(_ data: Data) throws -> BITLoginChallengePayload {
        do {
            return try BITLoginChallengeSupport.decodePayload(from: data)
        } catch {
            throw ScoreServiceError.invalidResponse.caused(by: error)
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
            throw ScoreServiceError.invalidResponse.caused(by: error)
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
        guard Set(headers).isSuperset(of: ScoreRow.requiredHeaderNames),
              headers.allSatisfy({ !$0.isEmpty }), Set(headers).count == headers.count,
              payload.data.dropFirst().allSatisfy({ $0.count == headers.count })
        else { throw ScoreServiceError.invalidResponse }
        var rows: [ScoreRow] = []
        rows.reserveCapacity(payload.data.count - 1)
        for (index, row) in payload.data.dropFirst().enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let record = ScoreRow(index: index, headers: headers, values: row)
            guard record.hasValidCourseIdentity else { throw ScoreServiceError.invalidResponse }
            rows.append(record)
        }
        return rows
    }

}

extension ScoreService: ScoreListServicing, TrustedTranscriptServicing {}
