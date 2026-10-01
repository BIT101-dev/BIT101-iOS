import ScoreDomain
import StorageCore
import Combine
import OSLog
import TransportCore
import ClientCore
import Foundation

/// 成绩接口层。
///
/// 查询先建立短期统一认证 challenge，再复用同一会话依次获取简略与详细成绩。
/// 服务端需要二次认证时，把 challenge 交给 SwiftUI 页面收集短信验证码。
public struct ScoreService {
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

    public init(
        credentials: any SchoolCredentialsProviding,
        httpClient: HTTPClient,
        sensitiveHTTPClient: HTTPClient,
        endpointBaseURL: URL
    ) {
        self.credentials = credentials
        self.httpClient = httpClient
        self.sensitiveHTTPClient = sensitiveHTTPClient
        self.endpointBaseURL = endpointBaseURL
    }

    /// 建立一次 JWB 会话，供简略成绩与详细成绩两个阶段复用。
    public func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
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
            authorization: nil
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
        return try await downloadTranscriptPages(cookieString: cookieString)
    }

    /// 使用成绩单系统 Cookie 读取申请结果页，并下载其中全部分页图片。
    ///
    /// 解析学校结果页中的全部分页图片，覆盖成绩较多时的多页结果。Cookie 与图片的生命周期属于临时内存会话。
    private func downloadTranscriptPages(cookieString: String) async throws -> [Data] {
        guard !cookieString.isEmpty else { throw ScoreServiceError.invalidResponse }

        let reportURL = AppURL.required("https://jwb.bit.edu.cn/cjd/ScoreReport2/Index?GPA=1")
        var reportRequest = URLRequest(url: reportURL)
        reportRequest.timeoutInterval = Self.authenticationWaitSeconds
        reportRequest.setValue(cookieString, forHTTPHeaderField: "Cookie")

        let report: HTTPResponse
        do {
            report = try await sensitiveHTTPClient
                .send(reportRequest)
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
        for match in expression.matches(in: html, range: htmlRange) {
            guard
                let range = Range(match.range(at: 1), in: html),
                let url = URL(string: String(html[range]), relativeTo: reportURL)?.absoluteURL,
                url.scheme == reportURL.scheme,
                url.host == reportURL.host,
                url.port == reportURL.port,
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
            let response = try await sensitiveHTTPClient
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
        return try await Self.decodeScoreRowsOffMain(data)
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
            let response = try await httpClient.send(
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

    private nonisolated func decodeBITLoginChallengePayload(_ data: Data) throws -> BITLoginChallengePayload {
        do {
            return try BITLoginChallengeSupport.decodePayload(from: data)
        } catch {
            throw ScoreServiceError.invalidResponse
        }
    }

    nonisolated private static func decodeScoreRowsOffMain(_ data: Data) async throws -> [ScoreRow] {
        let decodingTask = Task.detached(priority: .utility) {
            try decodeScoreRows(data)
        }
        return try await withTaskCancellationHandler {
            try await decodingTask.value
        } onCancel: {
            decodingTask.cancel()
        }
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

        guard !payload.data.isEmpty else {
            if payload.msg?.contains("查询成功") == true {
                return []
            }
            throw ScoreServiceError.queryFailed(payload.msg ?? "没有查询到成绩数据。")
        }

        let headers = payload.data[0]
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


nonisolated struct ScoreCacheLegacyData: Sendable {
    let rows: Data?
    let updatedAt: Data?
    let detailedUpdatedAt: Data?

    static let empty = ScoreCacheLegacyData(rows: nil, updatedAt: nil, detailedUpdatedAt: nil)
}

nonisolated enum ScoreCacheDiskReadResult: Sendable {
    case loaded(ScoreCacheSnapshot, migratedLegacy: Bool)
    case missing
    case unreadable

    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
}

nonisolated enum ScoreCacheMutation: Sendable {
    case rows([ScoreRow])
    case detailedRows([ScoreRow])
    case markChecked
    case synced(ScoreCacheSyncPayload)
}

nonisolated enum ScoreCacheDiskWriteResult: Sendable {
    case saved(ScoreCacheSnapshot)
    case unreadable
    case failed

    var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }

    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
}

/// 成绩缓存仓库。
///
/// 按学号隔离；文件读写、JSON 编解码和变更串行化均在专用 actor 执行。
public final class ScoreCacheStore: ScoreCaching {
    private let changeSubject = PassthroughSubject<AppStorageSession, Never>()
    public var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
    private let saveSubject = PassthroughSubject<AppStorageSession, Never>()
    public var localSaves: AnyPublisher<AppStorageSession, Never> { saveSubject.eraseToAnyPublisher() }
    private nonisolated static let logger = Logger(subsystem: "BIT101", category: "ScoreCache")
    private let repository: ScoreCacheDiskRepository
    private let defaults: UserDefaults
    private let currentSession: () -> AppStorageSession

    public init(files: any AppFileService, storageRoot: URL, defaults: UserDefaults, session: @escaping () -> AppStorageSession) {
        self.repository = ScoreCacheDiskRepository(files: files, storageRoot: storageRoot)
        self.defaults = defaults
        self.currentSession = session
    }

    public func loadSnapshot(for session: AppStorageSession? = nil) async -> ScoreCacheSnapshot? {
        let session = session ?? currentSession()
        let result = await repository.load(for: session, legacyData: legacyData(for: session))
        switch result {
        case .loaded(let snapshot, let migratedLegacy):
            if migratedLegacy { clearLegacyDefaults(for: session) }
            return snapshot
        case .missing, .unreadable:
            return nil
        }
    }

    public func loadRows(for session: AppStorageSession? = nil) async -> [ScoreRow]? {
        await loadSnapshot(for: session)?.rows
    }

    public func loadUpdatedAt(for session: AppStorageSession? = nil) async -> Date? {
        await loadSnapshot(for: session)?.updatedAt
    }

    public func loadDetailedUpdatedAt(for session: AppStorageSession? = nil) async -> Date? {
        await loadSnapshot(for: session)?.detailedUpdatedAt
    }

    @discardableResult
    public func save(rows: [ScoreRow], for session: AppStorageSession? = nil) async -> Date? {
        let session = session ?? currentSession()
        let result = await repository.mutate(
            .rows(rows),
            for: session,
            legacyData: legacyData(for: session)
        )
        return finishWrite(result, for: session, syncPreference: true)
    }

    @discardableResult
    public func saveDetailed(rows: [ScoreRow], for session: AppStorageSession? = nil) async -> Date? {
        let session = session ?? currentSession()
        let result = await repository.mutate(
            .detailedRows(rows),
            for: session,
            legacyData: legacyData(for: session)
        )
        return finishWrite(result, for: session, syncPreference: true)
    }

    /// 一次成功的简略比较更新可见的新鲜度时间戳，并保留缓存中更完整的成绩行。
    @discardableResult
    public func markChecked(for session: AppStorageSession? = nil) async -> Date? {
        let session = session ?? currentSession()
        let result = await repository.mutate(
            .markChecked,
            for: session,
            legacyData: legacyData(for: session)
        )
        return finishWrite(result, for: session, syncPreference: true)
    }

    /// 文件损坏时返回 nil，使同步协调暂停该域，避免把空快照上传覆盖云端数据。
    public func syncPayload(for session: AppStorageSession? = nil) async -> ScoreCacheSyncPayload? {
        let session = session ?? currentSession()
        let result = await repository.load(for: session, legacyData: legacyData(for: session))
        switch result {
        case .loaded(let snapshot, let migratedLegacy):
            if migratedLegacy { clearLegacyDefaults(for: session) }
            return ScoreCacheSyncPayload(
                rows: snapshot.rows ?? [],
                updatedAt: snapshot.updatedAt,
                detailedUpdatedAt: snapshot.detailedUpdatedAt
            )
        case .missing:
            return ScoreCacheSyncPayload(rows: [], updatedAt: nil, detailedUpdatedAt: nil)
        case .unreadable:
            return nil
        }
    }

    /// 写入来自 iCloud 的成绩缓存；损坏的本地文件保留原样，等待明确恢复。
    @discardableResult
    public func applySynced(
        _ payload: ScoreCacheSyncPayload,
        for session: AppStorageSession? = nil
    ) async -> Bool {
        guard !payload.rows.isEmpty else { return false }
        let session = session ?? currentSession()
        let result = await repository.mutate(
            .synced(payload),
            for: session,
            legacyData: legacyData(for: session)
        )
        guard result.isSaved else {
            _ = finishWrite(result, for: session, syncPreference: false)
            return false
        }
        _ = finishWrite(result, for: session, syncPreference: false)
        return true
    }

    private func finishWrite(
        _ result: ScoreCacheDiskWriteResult,
        for session: AppStorageSession,
        syncPreference: Bool
    ) -> Date? {
        guard case .saved(let snapshot) = result else {
            if result.isUnreadable {
                Self.logger.error("保留无法读取的成绩缓存，跳过保存")
            }
            return nil
        }

        clearLegacyDefaults(for: session)
        if syncPreference {
            saveSubject.send(session)
        }
        changeSubject.send(session)
        return snapshot.updatedAt
    }

    private func legacyData(for session: AppStorageSession) -> ScoreCacheLegacyData {
        func value(_ prefix: String) -> Data? {
            defaults.data(forKey: session.key(prefix))
                ?? defaults.data(forKey: session.legacyKey(prefix))
        }
        return ScoreCacheLegacyData(
            rows: value("score.detail.cache"),
            updatedAt: value("score.detail.cache.updated-at"),
            detailedUpdatedAt: value("score.detail.cache.full-updated-at")
        )
    }

    private func clearLegacyDefaults(for session: AppStorageSession) {
        for prefix in ["score.detail.cache", "score.detail.cache.updated-at", "score.detail.cache.full-updated-at"] {
            defaults.removeObject(forKey: session.key(prefix))
            defaults.removeObject(forKey: session.legacyKey(prefix))
        }
    }
}

/// 对账号成绩文件的全部操作都在 actor 内同步执行，避免主线程 I/O 与并发读改写丢失。
actor ScoreCacheDiskRepository {
    nonisolated private static let logger = Logger(subsystem: "BIT101", category: "ScoreCache")

    private let files: any AppFileService
    private let storageRoot: URL

    init(files: any AppFileService, storageRoot: URL) {
        self.files = files
        self.storageRoot = storageRoot
    }

    func load(for session: AppStorageSession, legacyData: ScoreCacheLegacyData) -> ScoreCacheDiskReadResult {
        switch readFile(for: session) {
        case .loaded(let snapshot):
            return .loaded(snapshot, migratedLegacy: false)
        case .unreadable:
            return .unreadable
        case .missing:
            guard let snapshot = decodeLegacy(legacyData), snapshot.containsData else { return .missing }
            do {
                try write(snapshot, for: session)
                return .loaded(snapshot, migratedLegacy: true)
            } catch {
                Self.logger.error("成绩缓存迁移写入失败：\(String(describing: error), privacy: .public)")
                return .loaded(snapshot, migratedLegacy: false)
            }
        }
    }

    func mutate(
        _ mutation: ScoreCacheMutation,
        for session: AppStorageSession,
        legacyData: ScoreCacheLegacyData
    ) -> ScoreCacheDiskWriteResult {
        var snapshot: ScoreCacheSnapshot
        switch readFile(for: session) {
        case .loaded(let stored):
            snapshot = stored
        case .missing:
            snapshot = decodeLegacy(legacyData) ?? ScoreCacheSnapshot()
        case .unreadable:
            return .unreadable
        }

        switch mutation {
        case .rows(let rows):
            snapshot.rows = rows
            snapshot.updatedAt = Date()
            if rows.isEmpty { snapshot.detailedUpdatedAt = nil }
        case .detailedRows(let rows):
            let now = Date()
            snapshot.rows = rows
            snapshot.updatedAt = now
            snapshot.detailedUpdatedAt = now
        case .markChecked:
            snapshot.updatedAt = Date()
        case .synced(let payload):
            snapshot = ScoreCacheSnapshot(
                rows: payload.rows,
                updatedAt: payload.updatedAt,
                detailedUpdatedAt: payload.detailedUpdatedAt
            )
        }

        do {
            try write(snapshot, for: session)
            removeLegacyFile(for: session)
            return .saved(snapshot)
        } catch {
            Self.logger.error("保存成绩缓存失败：\(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    private enum ExistingFileResult {
        case loaded(ScoreCacheSnapshot)
        case missing
        case unreadable
    }

    private func readFile(for session: AppStorageSession) -> ExistingFileResult {
        let url = fileURL(for: session)
        guard files.fileExists(at: url) else {
            let legacyURL = legacyFileURL(for: session)
            guard legacyURL != url, files.fileExists(at: legacyURL) else { return .missing }
            let legacyResult = readFile(at: legacyURL)
            guard case .loaded(let snapshot) = legacyResult else { return legacyResult }
            do {
                try write(snapshot, for: session)
                removeLegacyFile(for: session)
            } catch {
                Self.logger.error("成绩缓存迁移写入失败：\(String(describing: error), privacy: .public)")
            }
            return .loaded(snapshot)
        }
        return readFile(at: url)
    }

    private func readFile(at url: URL) -> ExistingFileResult {
        try? files.setPrivateFileProtection(at: url)
        guard let data = try? files.readData(at: url),
              let snapshot = try? JSONDecoder().decode(ScoreCacheSnapshot.self, from: data)
        else {
            Self.logger.error("成绩缓存无法读取，保留原文件：\(url.lastPathComponent, privacy: .public)")
            return .unreadable
        }
        return .loaded(snapshot)
    }

    private func decodeLegacy(_ legacyData: ScoreCacheLegacyData) -> ScoreCacheSnapshot? {
        let decoder = JSONDecoder()
        let snapshot = ScoreCacheSnapshot(
            rows: legacyData.rows.flatMap { try? decoder.decode([ScoreRow].self, from: $0) },
            updatedAt: legacyData.updatedAt.flatMap { try? decoder.decode(Date.self, from: $0) },
            detailedUpdatedAt: legacyData.detailedUpdatedAt.flatMap { try? decoder.decode(Date.self, from: $0) }
        )
        return snapshot.containsData ? snapshot : nil
    }

    private func write(_ snapshot: ScoreCacheSnapshot, for session: AppStorageSession) throws {
        let url = fileURL(for: session)
        try files.createDirectory(at: url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(snapshot)
        try files.writeData(
            data,
            to: url,
            options: AppFileSystem.protectedDataWritingOptions
        )
    }

    private func fileURL(for session: AppStorageSession) -> URL {
        storageRoot
            .appending(path: session.accountStorageIdentifier, directoryHint: .isDirectory)
            .appending(path: "score-cache.json")
    }

    private func legacyFileURL(for session: AppStorageSession) -> URL {
        storageRoot
            .appending(path: session.legacyAccountDirectoryNameForMigration, directoryHint: .isDirectory)
            .appending(path: "score-cache.json")
    }

    private func removeLegacyFile(for session: AppStorageSession) {
        let url = legacyFileURL(for: session)
        guard url != fileURL(for: session), files.fileExists(at: url),
              let data = try? files.readData(at: url),
              (try? JSONDecoder().decode(ScoreCacheSnapshot.self, from: data)) != nil
        else { return }
        try? files.removeItem(at: url)
        let directory = url.deletingLastPathComponent()
        if (try? files.contentsOfDirectory(at: directory, options: []).isEmpty) == true {
            try? files.removeItem(at: directory)
        }
    }
}



public final class ScoreFilterPreferenceStore: ScoreFilterPreferencesStoring {
    private let changeSubject = PassthroughSubject<AppStorageSession, Never>()
    public var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
    private let saveSubject = PassthroughSubject<AppStorageSession, Never>()
    public var localSaves: AnyPublisher<AppStorageSession, Never> { saveSubject.eraseToAnyPublisher() }
    private let session: () -> AppStorageSession
    private let store: AccountScopedCodableStore<ScoreFilterPreferenceSnapshot>

    public init(defaults: UserDefaults, session: @escaping () -> AppStorageSession) {
        self.session = session
        store = AccountScopedCodableStore(
            keyPrefix: "score.filter.preferences", defaults: defaults, sessionProvider: session
        )
    }

    public func load() -> ScoreFilterPreferenceSnapshot? {
        store.load()
    }

    public func save(
        selectedTerms: Set<String>,
        selectedCourseTypes: Set<String>,
        sortIndex: ScoreSortIndex,
        sortOrder: ScoreSortOrder
    ) {
        let snapshot = ScoreFilterPreferenceSnapshot(
            selectedTerms: selectedTerms.sorted(),
            selectedCourseTypes: selectedCourseTypes.sorted(),
            sortIndex: sortIndex.rawValue,
            sortOrder: sortOrder.rawValue
        )
        store.save(snapshot)
        saveSubject.send(session())
        changeSubject.send(session())
    }

    /// 将 iCloud 筛选偏好写入本地存储，并发布所属账号的变更。
    public func applySynced(_ snapshot: ScoreFilterPreferenceSnapshot) {
        store.save(snapshot)
        changeSubject.send(session())
    }
}
