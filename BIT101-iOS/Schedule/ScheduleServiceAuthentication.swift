//
//  ScheduleServiceAuthentication.swift
//  BIT101-iOS
//
//  Teaching-center authentication and course-sync entry points.
//

import Foundation

extension ScheduleService {
    /// 同步课表、考试和首周日期。
    ///
    /// 这三个结果会同时影响课表页面、当前周计算、小组件和灵动岛，所以同步时必须成套获取。
    func syncCourses(term: String? = nil) async throws -> CourseSyncPayload {
        try await withTeachingCenterSessionRetry {
            try await fetchCourseSyncPayload(term: term)
        }
    }

    /// 获取学校已经开放的学期列表，供用户主动切换课表学期。
    func fetchAvailableTerms() async throws -> [String] {
        try await withTeachingCenterSessionRetry {
            try await prepareJXZX()
            let response: TermsResponse = try await sendJSONRequest(
                path: "/jwapp/sys/wdkbby/modules/jshkcb/xnxqcx.do"
            )
            return Array(
                Set(response.datas.xnxqcx.rows.map(\.code).filter { !$0.isEmpty })
            ).sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        }
    }

    /// 提交新版统一认证的短信验证码，并在认证成功后继续本次课表同步。
    func submitSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge,
        term: String? = nil
    ) async throws -> CourseSyncPayload {
        try await submitSMSCodeForTeachingCenterAuthentication(code, for: challenge)
        return try await withTeachingCenterSessionRetry {
            try await fetchCourseSyncPayload(term: term)
        }
    }

    /// 只完成短信认证，不附带任何课表操作。
    ///
    /// 加载学期列表触发验证时使用此入口，认证成功后由 ViewModel 自动继续加载列表，
    /// 避免仅仅打开学期页却顺手把课表切回学校当前学期。
    func submitSMSCodeForTeachingCenterAuthentication(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws {
        guard !challenge.isExpired else {
            throw ScheduleServiceError.challengeInvalid("验证码已过期，请重新同步课表。")
        }
        var request = URLRequest(
            url: bitLoginBaseURL.appending(path: "api/auth/\(challenge.challengeID)/sms")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(challenge.accessToken, forHTTPHeaderField: "X-Challenge-Token")
        request.httpBody = try JSONEncoder().encode(SMSCodeRequest(code: code))

        let (data, response) = try await sendRequest(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            let message = errorMessage(from: data) ?? "短信验证码验证失败。"
            if [403, 404, 409].contains(response.statusCode) {
                throw ScheduleServiceError.challengeInvalid(
                    "本次验证已失效或验证码已提交，请重新同步课表。\n\(message)"
                )
            }
            throw ScheduleServiceError.authenticationFailed(message)
        }

        let payload = try decodeChallengePayload(data)
        let current = try await waitUntilAuthenticationActionable(
            payload,
            accessToken: challenge.accessToken
        )
        try await finishTeachingCenterAuthentication(current)
    }

    private func fetchCourseSyncPayload(term requestedTerm: String? = nil) async throws -> CourseSyncPayload {
        try await prepareJXZX()

        let normalizedTerm = requestedTerm?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let term = normalizedTerm.isEmpty ? try await fetchCurrentTerm() : normalizedTerm
        async let coursesTask = fetchCourses(term: term)
        async let examsTask = fetchExams(term: term)
        async let firstDayTask = fetchFirstDayString(term: term)
        let (courses, exams, firstDayString) = try await (coursesTask, examsTask, firstDayTask)
        let normalized = SmallTermWeekNormalizer.normalize(
            term: term,
            firstDayString: firstDayString,
            courses: courses
        )

        return CourseSyncPayload(
            term: term,
            firstDayString: normalized.firstDayString,
            courses: normalized.courses,
            exams: exams
        )
    }

    /// 通过新版 bit-login challenge 获取教学中心的 WebVPN Cookie。
    func ensureTeachingCenterAuthentication(force: Bool = false) async throws {
        let username = storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = storage.currentPassword
        guard !username.isEmpty, !password.isEmpty else {
            throw ScheduleServiceError.notLoggedIn
        }

        if force {
            teachingCenterState.invalidate()
        } else if teachingCenterState.hasUsableSession(for: username) {
            return
        }

        let body = AuthenticationCredentials(
            username: username,
            password: password,
            challengeID: nil
        )
        do {
            try await requestTeachingCenterCookies(body: body, accessToken: nil)
        } catch ScheduleServiceError.authenticationFailed(let message)
            where isTransientAuthenticationFailure(message)
        {
            // bit-login 到 WebVPN 的单次请求可能被学校侧 25 秒读超时打断；没有拿到
            // challenge 的情况下安全地退避并重试一次，避免把瞬时抖动直接暴露给用户。
            try await Task.sleep(for: .seconds(2))
            try await requestTeachingCenterCookies(body: body, accessToken: nil)
        } catch ScheduleServiceError.challengeInvalid(let message)
            where isTransientAuthenticationFailure(message)
        {
            try await Task.sleep(for: .seconds(2))
            try await requestTeachingCenterCookies(body: body, accessToken: nil)
        }
    }

    func isTransientAuthenticationFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("timed out")
            || normalized.contains("timeout")
            || normalized.contains("连接统一身份认证服务")
            || normalized.contains("暂时不可用")
            || normalized.contains("http 500")
            || normalized.contains("http 502")
            || normalized.contains("http 503")
            || normalized.contains("http 504")
    }

    private func requestTeachingCenterCookies(
        body: AuthenticationCredentials,
        accessToken: String?
    ) async throws {
        var request = URLRequest(
            url: bitLoginBaseURL.appending(path: "api/jxzxehall/cookies")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await sendRequest(request)
        if response.statusCode == 202 {
            guard
                let envelope = try? JSONDecoder().decode(ChallengeEnvelope.self, from: data),
                let accessToken = envelope.detail.accessToken,
                !accessToken.isEmpty
            else {
                throw ScheduleServiceError.invalidResponse
            }
            let current = try await waitUntilAuthenticationActionable(
                envelope.detail,
                accessToken: accessToken
            )
            try await finishTeachingCenterAuthentication(current)
            return
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            throw ScheduleServiceError.authenticationFailed(
                errorMessage(from: data) ?? "教学中心统一认证失败。"
            )
        }
        try installTeachingCenterCookies(from: data)
    }

    private func finishTeachingCenterAuthentication(
        _ challenge: BITLoginAuthenticationChallenge
    ) async throws {
        switch challenge.status {
        case "authenticated":
            try await requestTeachingCenterCookies(
                body: AuthenticationCredentials(
                    username: nil,
                    password: nil,
                    challengeID: challenge.challengeID
                ),
                accessToken: challenge.accessToken
            )
        case "waiting_sms":
            throw ScheduleServiceError.secondFactorRequired(challenge)
        case "expired":
            throw ScheduleServiceError.challengeInvalid("验证码已过期，请重新同步课表。")
        case "failed":
            throw ScheduleServiceError.challengeInvalid("教学中心统一认证失败，请重新同步课表。")
        default:
            throw ScheduleServiceError.authenticationFailed("统一身份认证处理超时，请重试。")
        }
    }

    private func waitUntilAuthenticationActionable(
        _ initialPayload: ChallengePayload,
        accessToken: String
    ) async throws -> BITLoginAuthenticationChallenge {
        var payload = initialPayload
        let deadline = Date().addingTimeInterval(Self.authenticationWaitSeconds)

        while ["running", "processing"].contains(payload.status), Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            var request = URLRequest(
                url: bitLoginBaseURL.appending(path: "api/auth/\(payload.challengeID)")
            )
            request.setValue(accessToken, forHTTPHeaderField: "X-Challenge-Token")
            let (data, response) = try await sendRequest(request)
            guard (200 ..< 300).contains(response.statusCode) else {
                throw ScheduleServiceError.authenticationFailed(
                    errorMessage(from: data) ?? "无法获取统一认证状态。"
                )
            }
            payload = try decodeChallengePayload(data)
        }

        if payload.status == "failed", let error = payload.error, !error.isEmpty {
            throw ScheduleServiceError.challengeInvalid(error)
        }
        return BITLoginAuthenticationChallenge(
            challengeID: payload.challengeID,
            accessToken: accessToken,
            status: payload.status,
            maskedPhone: payload.maskedPhone,
            expiresIn: payload.expiresIn
        )
    }

    private func decodeChallengePayload(_ data: Data) throws -> ChallengePayload {
        do {
            return try JSONDecoder().decode(ChallengePayload.self, from: data)
        } catch {
            throw ScheduleServiceError.invalidResponse
        }
    }

    private func installTeachingCenterCookies(from data: Data) throws {
        let response: CookieResponse
        do {
            response = try JSONDecoder().decode(CookieResponse.self, from: data)
        } catch {
            throw ScheduleServiceError.invalidResponse
        }
        guard !response.data.isEmpty else {
            throw ScheduleServiceError.invalidResponse
        }

        for (name, value) in response.data {
            guard let cookie = HTTPCookie(properties: [
                .domain: "webvpn.bit.edu.cn",
                .path: "/",
                .name: name,
                .value: value,
                .secure: "TRUE",
            ]) else { continue }
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        let studentID = storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !studentID.isEmpty else {
            teachingCenterState.invalidate()
            throw ScheduleServiceError.notLoggedIn
        }
        teachingCenterState.markAuthenticated(for: studentID)
    }

    private func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let detail = json["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    /// 只查询学校标记的当前学期，不拉完整课表。
    ///
    /// 主要用于空教室页只需要学期编码但不需要整份课表时的轻量查询。
    func fetchCurrentTermOnly() async throws -> String {
        try await withTeachingCenterSessionRetry {
            try await prepareJXZX()
            return try await fetchCurrentTerm()
        }
    }
}
