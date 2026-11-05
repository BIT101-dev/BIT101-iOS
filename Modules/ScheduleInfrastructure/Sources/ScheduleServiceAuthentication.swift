import ClientCore
import Foundation
import ScheduleDomain
import SchedulePorts
import TransportCore

extension ScheduleService {
    /// 同步课表、考试和首周日期。
    ///
    /// 课程与日期基准组成可用课表，考试来源独立返回状态。
    public func syncCourses(term: String? = nil) async throws -> CourseSyncPayload {
        try await withPreparedTeaching {
            try await fetchCourseSyncPayload(term: term)
        }
    }

    /// 获取学校已经开放的学期列表，供用户主动切换课表学期。
    public func fetchAvailableTerms() async throws -> [String] {
        try await withPreparedTeaching {
            let response: TermsResponse = try await sendJSONRequest(
                path: "/jwapp/sys/wdkbby/modules/jshkcb/xnxqcx.do"
            )
            return Array(
                Set(response.datas.xnxqcx.rows.map(\.code).filter { !$0.isEmpty })
            ).sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        }
    }

    /// 完成图形或短信认证，由调用方继续处理课表操作。
    ///
    /// 认证成功后由调用方清除验证挑战，再续接课表、学期列表或空教室请求。
    public func submitTeachingCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws {
        guard !challenge.isExpired else {
            throw ScheduleServiceError.challengeInvalid("验证码已过期，请重新同步课表。")
        }
        guard let owner = challenge.ownerIdentity else { throw CancellationError() }
        try validateAuthOwner(owner)
        let request = try BITLoginChallengeSupport.verificationRequest(
            code: code, for: challenge, baseURL: bitLoginBaseURL)

        let wire = try await sendObservedRequest(request)
        let data = wire.data
        let response = wire.response
        try validateAuthOwner(owner)
        guard (200..<300).contains(response.statusCode) else {
            let message = BITLoginChallengeSupport.errorMessage(from: data) ?? "验证码验证失败。"
            if [403, 404, 409].contains(response.statusCode) {
                throw ScheduleServiceError.challengeInvalid(
                    "本次验证已失效或验证码已提交，请重新同步课表。\n\(message)"
                )
            }
            throw ScheduleServiceError.authenticationFailed(message)
        }

        let payload = try await decodedChallenge(wire)
        let current = try await waitForAuthAction(
            payload,
            accessToken: challenge.accessToken,
            owner: owner
        )
        if current.status == "failed" {
            throw ScheduleServiceError.challengeInvalid(current.error ?? "验证码验证失败，请重新发起当前操作。")
        }
        try await finishTeachingAuth(current, owner: owner)
    }

    private func fetchCourseSyncPayload(term requestedTerm: String? = nil) async throws
        -> CourseSyncPayload
    {
        let owner = credentials.schoolSessionIdentity
        let normalizedTerm = requestedTerm?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let term = normalizedTerm.isEmpty ? try await fetchCurrentTerm() : normalizedTerm
        async let coursesTask = fetchParsedCourses(term: term)
        async let examsTask = fetchExamsForCourseSync(term: term)
        async let firstDayTask = fetchFirstDayString(term: term)
        let (parsedCourses, exams, firstDayString) = try await (
            coursesTask, examsTask, firstDayTask
        )
        let payload = try await Self.makeCourseSyncPayload(
            term: term, parsedCourses: parsedCourses, exams: exams.records,
            warnings: exams.warnings, firstDayString: firstDayString
        )
        try validateAuthOwner(owner)
        return payload
    }

    private func fetchExamsForCourseSync(term: String) async throws -> (
        records: [ExamRecord]?, warnings: [String]
    ) {
        do { return (try await fetchExams(term: term), []) } catch {
            if TaskCancellation.matches(error) { throw error }
            return (nil, ["课程已更新，考试数据待恢复。" + error.localizedDescription])
        }
    }

    @concurrent
    private static func makeCourseSyncPayload(
        term: String, parsedCourses: [CourseResponse.ParsedCourse], exams: [ExamRecord]?,
        warnings: [String], firstDayString: String
    ) async throws -> CourseSyncPayload {
        try Task.checkCancellation()
        let rawWeeks = parsedCourses.map(\.rawWeeks)
        let normalized = SmallTermWeekNormalizer.normalize(
            term: term, firstDayString: firstDayString,
            courses: parsedCourses.map(\.course), rawWeeksByCourse: rawWeeks
        )
        try Task.checkCancellation()
        return CourseSyncPayload(
            term: term,
            firstDayString: normalized.firstDayString,
            sourceFirstDayString: firstDayString,
            normalizationOffset: normalized.offset,
            rawWeeksByCourse: rawWeeks,
            sourceDisplayWeeksByCourse: parsedCourses.map(\.sourceDisplayWeeks),
            courses: normalized.courses,
            exams: exams,
            warnings: warnings
        )
    }

    /// 通过新版 bit-login challenge 获取教学中心的 WebVPN Cookie。
    func ensureTeachingAuth(force: Bool = false) async throws {
        let owner = credentials.schoolSessionIdentity
        let username = credentials.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = credentials.currentPassword
        guard !username.isEmpty, !password.isEmpty else {
            throw ScheduleServiceError.notLoggedIn
        }

        teachingCenterState.selectOwner(owner)
        if !force, teachingCenterState.hasUsableSession(for: username) { return }
        try await teachingCenterState.authenticationRecovery.refresh(identity: owner) { [self] in
            try validateAuthOwner(owner)
            if !force, teachingCenterState.hasUsableSession(for: username) { return }
            if force { teachingCenterState.invalidate() }
            try await restoreTeachingAuth(owner: owner, username: username, password: password)
        }
        try validateAuthOwner(owner)
    }

    private func restoreTeachingAuth(
        owner: SchoolSessionIdentity, username: String, password: String
    ) async throws {
        let body = AuthenticationCredentials(
            username: username,
            password: password,
            challengeID: nil
        )
        do {
            try await requestTeachingCookies(body: body, accessToken: nil, owner: owner)
        } catch {
            let shouldRetry: Bool
            switch error {
            case ScheduleServiceError.authenticationFailed(let message),
                ScheduleServiceError.challengeInvalid(let message):
                shouldRetry = isTransientAuthFailure(message)
            default:
                shouldRetry = isScheduleNetworkError(error)
            }
            guard shouldRetry else { throw error }
            // bit-login 到 WebVPN 的单次请求可能被学校侧 25 秒读超时打断；等待 2 秒后重试一次。
            try await Task.sleep(for: .seconds(2))
            try await requestTeachingCookies(body: body, accessToken: nil, owner: owner)
        }
    }

    func isTransientAuthFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("timed out")
            || normalized.contains("timeout")
            || normalized.contains("超时")
            || normalized.contains("连接统一身份认证服务")
            || normalized.contains("暂时不可用")
            || normalized.contains("http 500")
            || normalized.contains("http 502")
            || normalized.contains("http 503")
            || normalized.contains("http 504")
    }

    private func requestTeachingCookies(
        body: AuthenticationCredentials,
        accessToken: String?,
        owner: SchoolSessionIdentity
    ) async throws {
        try validateAuthOwner(owner)
        var request = URLRequest(
            url: bitLoginBaseURL.appending(path: "api/jxzxehall/cookies")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let wire = try await sendObservedRequest(request)
        let data = wire.data
        let response = wire.response
        try validateAuthOwner(owner)
        if response.statusCode == 202 {
            guard accessToken == nil else {
                throw ScheduleServiceError.challengeInvalid("教学中心会话再次要求认证，请重新同步课表。")
            }
            let envelope = try await wire.validated { data, _ in
                do {
                    return try JSONDecoder().decode(BITLoginChallengeEnvelope.self, from: data)
                } catch { throw ScheduleServiceError.invalidResponse.caused(by: error) }
            }
            guard let accessToken = envelope.detail.accessToken, !accessToken.isEmpty else {
                await wire.reportValidationFailure(ScheduleServiceError.invalidResponse)
                throw ScheduleServiceError.invalidResponse
            }
            let current = try await waitForAuthAction(
                envelope.detail,
                accessToken: accessToken,
                owner: owner
            )
            try await finishTeachingAuth(current, owner: owner)
            return
        }

        guard (200..<300).contains(response.statusCode) else {
            throw ScheduleServiceError.authenticationFailed(
                BITLoginChallengeSupport.errorMessage(from: data) ?? "教学中心统一认证失败。"
            )
        }
        try await wire.validated { data, _ in try installTeachingCookies(from: data, owner: owner) }
    }

    private func finishTeachingAuth(
        _ challenge: BITLoginAuthenticationChallenge,
        owner: SchoolSessionIdentity
    ) async throws {
        try validateAuthOwner(owner)
        switch challenge.status {
        case "authenticated":
            try await requestTeachingCookies(
                body: AuthenticationCredentials(
                    username: nil,
                    password: nil,
                    challengeID: challenge.challengeID
                ),
                accessToken: challenge.accessToken,
                owner: owner
            )
        case "waiting_sms", "waiting_captcha":
            throw ScheduleServiceError.secondFactorRequired(challenge)
        case "expired":
            throw ScheduleServiceError.challengeInvalid("验证码已过期，请重新同步课表。")
        case "failed":
            throw ScheduleServiceError.authenticationFailed(
                challenge.error ?? "教学中心统一认证失败，请重新同步课表。")
        default:
            throw ScheduleServiceError.authenticationFailed("统一身份认证处理超时，请重试。")
        }
    }

    private func waitForAuthAction(
        _ initialPayload: BITLoginChallengePayload,
        accessToken: String,
        owner: SchoolSessionIdentity
    ) async throws -> BITLoginAuthenticationChallenge {
        let payload = try await BITLoginChallengeSupport.pollUntilActionable(
            initialPayload,
            timeout: Self.authenticationWaitSeconds,
            interval: .seconds(1)
        ) { challengeID in
            try await validateAuthOwner(owner)
            var request = URLRequest(
                url: bitLoginBaseURL.appending(path: "api/auth/\(challengeID)")
            )
            request.setValue(accessToken, forHTTPHeaderField: "X-Challenge-Token")
            let wire = try await sendObservedRequest(request)
            let data = wire.data
            let response = wire.response
            try await validateAuthOwner(owner)
            guard (200..<300).contains(response.statusCode) else {
                throw ScheduleServiceError.authenticationFailed(
                    BITLoginChallengeSupport.errorMessage(from: data) ?? "无法获取统一认证状态。"
                )
            }
            return try await decodedChallenge(wire)
        }

        try validateAuthOwner(owner)
        return BITLoginChallengeSupport.challenge(
            from: payload, accessToken: accessToken, ownerIdentity: owner)
    }

    private func decodedChallenge(_ wire: HTTPResponse) async throws -> BITLoginChallengePayload {
        let payload = try await wire.validated { data, _ in try decodeLoginChallenge(data) }
        if payload.status == "failed" {
            await wire.reportValidationFailure(
                ScheduleServiceError.authenticationFailed(payload.error ?? "统一身份认证失败。"))
        }
        return payload
    }

    private nonisolated func decodeLoginChallenge(_ data: Data) throws -> BITLoginChallengePayload {
        do {
            return try BITLoginChallengeSupport.decodePayload(from: data)
        } catch {
            throw ScheduleServiceError.invalidResponse.caused(by: error)
        }
    }

    func validateAuthOwner(_ owner: SchoolSessionIdentity) throws {
        try Task.checkCancellation()
        guard credentials.schoolSessionIdentity == owner else { throw CancellationError() }
    }

    private func installTeachingCookies(from data: Data, owner: SchoolSessionIdentity) throws {
        try validateAuthOwner(owner)
        let response: CookieResponse
        do {
            response = try JSONDecoder().decode(CookieResponse.self, from: data)
        } catch {
            throw ScheduleServiceError.invalidResponse.caused(by: error)
        }
        guard !response.data.isEmpty else {
            throw ScheduleServiceError.invalidResponse
        }

        var installedCookieCount = 0
        for (name, value) in response.data {
            guard
                let cookie = HTTPCookie(properties: [
                    .domain: "webvpn.bit.edu.cn",
                    .path: "/",
                    .name: name,
                    .value: value,
                    .secure: "TRUE",
                ])
            else { continue }
            teachingCenterState.cookieStorage.setCookie(cookie)
            installedCookieCount += 1
        }
        guard installedCookieCount > 0 else {
            throw ScheduleServiceError.invalidResponse
        }
        let studentID = owner.accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !studentID.isEmpty else {
            teachingCenterState.invalidate()
            throw ScheduleServiceError.notLoggedIn
        }
        teachingCenterState.markAuthenticated(for: studentID)
    }

    /// 查询学校标记的当前学期编码。
    ///
    /// 空教室页通过此入口获取学期编码，保持请求轻量。
    public func fetchCurrentTermOnly() async throws -> String {
        try await withPreparedTeaching {
            return try await fetchCurrentTerm()
        }
    }
}
