//
//  ScheduleService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation


/// 日程同步过程中的统一错误。
///
/// 这层错误枚举主要服务 UI 展示；更底层的接口差异、字段缺失等问题会在这里统一折叠成少量用户可理解的文案。
enum ScheduleServiceError: LocalizedError {
    case notLoggedIn
    case secondFactorRequired(BITLoginAuthenticationChallenge)
    case challengeInvalid(String)
    case teachingCenterSessionExpired
    case authenticationFailed(String)
    case invalidResponse
    case invalidLexuePage
    case invalidCalendarURL
    case invalidCalendarData

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效，请重新登录后再同步日程。"
        case .secondFactorRequired:
            return "需要短信验证码才能继续访问学校教务服务。"
        case let .challengeInvalid(message):
            return message
        case .teachingCenterSessionExpired:
            return "学校会话自动恢复失败，请稍后重试；无需退出 App 或重新登录。"
        case let .authenticationFailed(message):
            return message
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .invalidLexuePage:
            return "无法从乐学页面提取日历订阅信息。"
        case .invalidCalendarURL:
            return "乐学日历订阅链接无效。"
        case .invalidCalendarData:
            return "乐学日历数据解析失败。"
        }
    }
}

/// 同步课程表和考试后的组合结果。
///
/// 课程、考试和首周日期来自不同接口，但在“同步课表”这个业务动作里必须一起更新，所以组合成一个返回体。
struct CourseSyncPayload {
    let term: String
    let firstDayString: String
    let courses: [CourseRecord]
    let exams: [ExamRecord]
}

/// 校正上半学期中由小学期产生的周次整体偏移。
///
/// 教务接口的 `SKZC` 有时仍以完整校历计数，而 `YPSJDD` 已按小学期重新从第 1 周
/// 标注。只有 `-1` 学期允许校正，并且必须由所有可解析课程共同证明同一个偏移量；
/// 这样不会把普通学期或单条异常数据误判成小学期。
nonisolated enum SmallTermWeekNormalizer {
    struct Result {
        let firstDayString: String
        let courses: [CourseRecord]
        let offset: Int
    }

    static func normalize(
        term: String,
        firstDayString: String,
        courses: [CourseRecord]
    ) -> Result {
        let unchanged = Result(firstDayString: firstDayString, courses: courses, offset: 0)
        guard term.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-1"),
              !courses.isEmpty
        else { return unchanged }

        struct CourseGroup {
            var rawWeeks = Set<Int>()
            var describedWeeks = Set<Int>()
        }

        var groups: [String: CourseGroup] = [:]
        for course in courses {
            let described = weeksDescribed(in: course.description)
            guard !described.isEmpty else { continue }
            let key = "\(course.number)|\(course.name)|\(course.description)"
            var group = groups[key, default: CourseGroup()]
            group.rawWeeks.formUnion(course.weeks)
            group.describedWeeks.formUnion(described)
            groups[key] = group
        }
        guard !groups.isEmpty else { return unchanged }

        var offsets = Set<Int>()
        for group in groups.values {
            let raw = group.rawWeeks.sorted()
            let described = group.describedWeeks.sorted()
            guard raw.count == described.count, raw.count >= 2 else { return unchanged }
            let differences = Set(zip(raw, described).map(-))
            guard differences.count == 1, let difference = differences.first else { return unchanged }
            offsets.insert(difference)
        }

        guard offsets.count == 1,
              let offset = offsets.first,
              (1 ... 8).contains(offset),
              courses.allSatisfy({ $0.weeks.allSatisfy { $0 > offset } }),
              let firstDay = parseDate(firstDayString),
              let shiftedFirstDay = calendar.date(byAdding: .day, value: offset * 7, to: firstDay)
        else { return unchanged }

        return Result(
            firstDayString: formatDate(shiftedFirstDay),
            courses: courses.map { shiftingWeeks(of: $0, by: -offset) },
            offset: offset
        )
    }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return value
    }

    private static func parseDate(_ string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: parts[0],
            month: parts[1],
            day: parts[2]
        ))
    }

    private static func formatDate(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func weeksDescribed(in text: String) -> Set<Int> {
        let pattern = #"(\d{1,2})\s*(?:[-－—~～至]\s*(\d{1,2}))?\s*周"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var result = Set<Int>()
        for match in expression.matches(in: text, range: range) {
            guard let lowerRange = Range(match.range(at: 1), in: text),
                  let lower = Int(text[lowerRange])
            else { continue }
            if match.range(at: 2).location != NSNotFound,
               let upperRange = Range(match.range(at: 2), in: text),
               let upper = Int(text[upperRange]),
               upper >= lower
            {
                result.formUnion(lower ... upper)
            } else {
                result.insert(lower)
            }
        }
        return result
    }

    private static func shiftingWeeks(of course: CourseRecord, by delta: Int) -> CourseRecord {
        CourseRecord(
            id: course.id,
            term: course.term,
            name: course.name,
            teacher: course.teacher,
            classroom: course.classroom,
            description: course.description,
            weeks: course.weeks.map { $0 + delta },
            weekday: course.weekday,
            startSection: course.startSection,
            endSection: course.endSection,
            campus: course.campus,
            number: course.number,
            credit: course.credit,
            hour: course.hour,
            type: course.type,
            category: course.category,
            department: course.department
        )
    }
}

/// 同步 DDL 后的组合结果。
///
/// 乐学同步除了事件列表外，还可能拿到新的订阅 URL，因此一起返回给上层缓存。
struct DDLSyncPayload {
    let url: String
    let events: [DDLEventRecord]
}

/// 日程模块网络层。
///
/// 负责四类事情：
/// 1. bit-login challenge、短信验证与教学中心会话恢复
/// 2. 指定学期的课表 / 考试 / 首周日期，以及空教室
/// 3. 乐学日历订阅地址解析与 ICS 下载
/// 4. ATS 相关的 HTTP -> HTTPS 升级
struct ScheduleService {
    private let schoolBaseURL = URL(string: "https://jxzxehallapp.bit.edu.cn")!
    private let webVPNSchoolBaseURL = URL(
        string: "https://webvpn.bit.edu.cn/https/77726476706e69737468656265737421faef5b842238695c720999bcd6572a216b231105adc27d"
    )!
    private let bitLoginBaseURL = URL(string: "https://login.bit101.flwfdd.xyz")!
    private let lexueBaseURL = URL(string: "https://lexue.bit.edu.cn")!
    private let storage = LoginStorage.shared
    private let teachingCenterState = TeachingCenterSessionState.shared
    private let session: URLSession
    private let redirectDelegate = HTTPSUpgradingRedirectDelegate()
    private static let authenticationWaitSeconds: TimeInterval = 90
    fileprivate static let decoder = JSONDecoder()

    private struct AuthenticationCredentials: Encodable {
        let username: String?
        let password: String?
        let challengeID: String?

        enum CodingKeys: String, CodingKey {
            case username, password
            case challengeID = "challenge_id"
        }
    }

    private struct SMSCodeRequest: Encodable {
        let code: String
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

    private struct CookieResponse: Decodable {
        let data: [String: String]
    }
    /// 构造带共享 cookie 与 HTTPS 升级能力的会话。
    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

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
    private func ensureTeachingCenterAuthentication(force: Bool = false) async throws {
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

    private func isTransientAuthenticationFailure(_ message: String) -> Bool {
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

    /// 同步乐学 DDL，并尽量复用已缓存的订阅地址。
    ///
    /// 订阅 URL 一般比较稳定，因此优先复用缓存；只有缓存不存在时才回退到网页抓取。
    func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String) async throws -> DDLSyncPayload {
        try await ensureSchoolSession()

        // 乐学同步允许复用已缓存的订阅链接，只有没有链接时才回到网页里重新抓取。
        let finalURL = try await resolveLexueCalendarURL(storedURL: storedURL)
        let remoteEvents = try await fetchLexueEvents(urlString: finalURL)

        let existingDoneMap = Dictionary(uniqueKeysWithValues: existingEvents.map { ($0.id, $0.done) })
        let merged = remoteEvents.map { event in
            return DDLEventRecord(
                id: event.id,
                group: event.group,
                title: event.title,
                text: event.text,
                dueAt: event.dueAt,
                done: existingDoneMap[event.id] ?? event.done
            )
        }

        return DDLSyncPayload(url: finalURL, events: merged)
    }

    /// 强制重新抓取乐学订阅地址。
    func refreshLexueCalendarURL() async throws -> String {
        try await ensureSchoolSession()
        return try await resolveLexueCalendarURL(storedURL: "")
    }

    /// 查询空教室页可选校区列表。
    ///
    /// 这一步相当于空教室查询的元数据预热，不涉及具体教室占用。
    func fetchCampuses() async throws -> [CampusRecord] {
        try await withTeachingCenterSessionRetry {
            try await prepareJXZX()
            return try await fetchCampusesDirect()
        }
    }

    /// 查询某个校区下的教学楼列表。
    ///
    /// 教学楼会在进入空教室页时结合“最近下一节课的楼宇”做自动匹配。
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] {
        try await withTeachingCenterSessionRetry {
            try await prepareJXZX()
            return try await fetchBuildingsDirect(campusCode: campusCode)
        }
    }

    /// 查询某个教学楼当天的教室占用情况。
    ///
    /// 空教室接口以“当天 + 教学楼”为粒度返回占用节次，后续再在 ViewModel 层按选中的时段块格式化。
    func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord] {
        try await withTeachingCenterSessionRetry {
            try await prepareJXZX()
            return try await fetchClassroomsDirect(buildingID: buildingID, term: term)
        }
    }

    /// 所有教学中心业务请求共用的会话入口。
    ///
    /// 首次请求前确保存在与当前账号绑定的 WebVPN Cookie；如果业务请求明确返回登录页、
    /// 401/403 或其他会话失效信号，只清理教学中心状态并重新走 bit-login。当前最多执行
    /// 两轮恢复（共三次业务尝试），之后直接向上抛出，避免无限认证循环。
    private func withTeachingCenterSessionRetry<T>(
        operation: () async throws -> T
    ) async throws -> T {
        try await ensureTeachingCenterAuthentication()

        // 学校 WebVPN 偶尔会接受新 Cookie，却在紧接着的第一笔业务请求中仍返回登录页。
        // 全程自动恢复，最多做两轮重新认证；用户只在确实需要短信验证码时参与。
        for recoveryAttempt in 0 ... 2 {
            do {
                return try await operation()
            } catch ScheduleServiceError.teachingCenterSessionExpired {
                teachingCenterState.invalidate()
                guard recoveryAttempt < 2 else {
                    throw ScheduleServiceError.teachingCenterSessionExpired
                }
                if recoveryAttempt > 0 {
                    try await Task.sleep(for: .seconds(1))
                }
                try await ensureTeachingCenterAuthentication(force: true)
            } catch {
                if isCancellationError(error) {
                    throw error
                }
                throw error
            }
        }

        throw ScheduleServiceError.teachingCenterSessionExpired
    }

    /// 确保学校侧登录态仍然有效。
    ///
    /// 日程模块大量依赖学校接口，但登录状态检查本身只是前置探测，不应该成为课表 / DDL / 空教室
    /// 真实业务请求之前的额外失败弹窗来源。
    ///
    /// 因此这里仅在远端明确判断当前会话无效时阻断；网络抖动、学校登录页异常等“检查失败”
    /// 会静默放行，让后续业务请求给出更贴近场景的错误。
    private func ensureSchoolSession() async throws {
        do {
            guard try await LoginService().checkLogin() != nil else {
                throw ScheduleServiceError.notLoggedIn
            }
        } catch let error as ScheduleServiceError {
            throw error
        } catch {
            return
        }
    }

    /// 直连学校接口获取校区列表。
    private func fetchCampusesDirect() async throws -> [CampusRecord] {
        let response: CampusListResponse = try await sendJSONRequest(
            path: "/jwapp/sys/kxjasbyMobile/modules/jxllb/ggzdpx.do?dicCode=48682&SFSY=1&order=%2BDM"
        )

        return response.datas.ggzdpx.rows.map {
            CampusRecord(id: $0.code, name: $0.displayName, code: $0.code)
        }
    }

    /// 直连学校接口获取教学楼列表。
    private func fetchBuildingsDirect(campusCode: String?) async throws -> [BuildingRecord] {
        let query: String
        if let campusCode, !campusCode.isEmpty {
            query = "?XXXQDM=\(urlEncode(campusCode))"
        } else {
            query = ""
        }

        let response: BuildingListResponse = try await sendJSONRequest(
            path: "/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do\(query)"
        )

        return response.datas.cxjxl.rows.map {
            BuildingRecord(
                id: $0.buildingCode,
                name: $0.buildingName,
                buildingCode: $0.buildingCode,
                campusName: $0.campusName,
                campusCode: $0.campusCode
            )
        }
    }

    /// 直连学校接口获取教室占用情况。
    private func fetchClassroomsDirect(buildingID: String, term: String) async throws -> [ClassroomRecord] {
        let termParts = term.split(separator: "-")
        let termID = termParts.last.map(String.init) ?? ""
        let termYearCode = termParts.dropLast().joined(separator: "-")
        let dateString = ScheduleDateCodec.formatDate(Date())

        let response: ClassroomListResponse = try await sendJSONRequest(
            path: "/jwapp/sys/kxjasbyMobile/kxjasbyController/cxkxjasqk.do",
            method: "POST",
            body: [
                ("XQDM", String(termID)),
                ("JXLDM", buildingID),
                ("RQ", dateString),
                ("XNXQDM", term),
                ("XNDM", String(termYearCode)),
            ]
        )

        return response.datas.cxkxjasqk.rows.map {
            ClassroomRecord(
                id: $0.classroomName,
                name: $0.classroomName,
                busyTimeCodes: $0.busyTimeString?
                    .split(separator: ",")
                    .compactMap { Int($0) }
                    .sorted() ?? []
            )
        }
    }

    /// 教务系统接口请求前的预热步骤。
    ///
    /// 学校教务接口存在“未预热直接请求会失败”的历史行为，因此这里保留一组轻量预热访问。
    private func prepareJXZX() async throws {
        let studentID = storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !studentID.isEmpty else { throw ScheduleServiceError.notLoggedIn }
        guard !teachingCenterState.isPrepared(for: studentID) else { return }

        // 学校教务接口依赖若干预热请求，否则后续接口会直接返回未初始化状态。
        _ = try await sendStringRequest(path: "/jwapp/sys/funauthapp/api/getAppConfig/wdkbby-5959167891382285.do")
        _ = try await sendStringRequest(path: "/jwapp/i18n.do?appName=wdkbby&EMAP_LANG=zh")
        teachingCenterState.markPrepared(for: studentID)
    }

    /// 获取学校标记的当前学期编码。
    private func fetchCurrentTerm() async throws -> String {
        let response: CurrentTermResponse = try await sendJSONRequest(
            path: "/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do"
        )

        guard let term = response.datas.dqxnxq.rows.first?.code, !term.isEmpty else {
            throw ScheduleServiceError.invalidResponse
        }

        return term
    }

    /// 拉取指定目标学期的课程表。
    ///
    /// 这里会把学校接口里稀疏且命名古老的字段，统一规整成 iOS 端自己的 `CourseRecord`。
    private func fetchCourses(term: String) async throws -> [CourseRecord] {
        let response: CourseResponse = try await sendJSONRequest(
            path: "/jwapp/sys/wdkbby/modules/xskcb/cxxszhxqkb.do",
            method: "POST",
            body: [("XNXQDM", term)]
        )

        return response.datas.cxxszhxqkb.rows.map { row in
            let weeks = (row.rawWeeks ?? "").enumerated().compactMap { index, flag in
                flag == "1" ? index + 1 : nil
            }

            return CourseRecord(
                id: "\(row.term ?? "")-\(row.courseNumber ?? "")-\(row.weekday ?? 0)-\(row.startSection ?? 0)-\(row.endSection ?? 0)-\(row.classroom ?? "")",
                term: row.term ?? "",
                name: row.name ?? "",
                teacher: row.teacher ?? "",
                classroom: row.classroom ?? "",
                description: row.scheduleDescription ?? "",
                weeks: weeks,
                weekday: row.weekday ?? 0,
                startSection: row.startSection ?? 0,
                endSection: row.endSection ?? 0,
                campus: row.campus ?? "",
                number: row.courseNumber ?? "",
                credit: row.credit ?? 0,
                hour: row.hour ?? 0,
                type: row.type ?? "",
                category: row.category ?? "",
                department: row.department ?? ""
            )
        }
    }

    /// 拉取指定目标学期的考试安排。
    private func fetchExams(term: String) async throws -> [ExamRecord] {
        let response: ExamResponse = try await sendJSONRequest(
            path: "/jwapp/sys/wdksapMobile/modules/ksap/cxxsksap.do",
            method: "POST",
            body: [("XNXQDM", term), ("*order", "-KSRQ")]
        )

        return response.datas.cxxsksap.rows.map { row in
            let rawCourseName = row.courseName ?? ""
            let name = rawCourseName
                .split(separator: "]")
                .first?
                .split(separator: "[")
                .last
                .map(String.init) ?? rawCourseName

            let times = row.timeDescription.captureGroups(pattern: #"(\d{2}:\d{2})-(\d{2}:\d{2})"#)
            let beginTime = times.first ?? ""
            let endTime = times.dropFirst().first ?? ""

            return ExamRecord(
                id: "\(row.termCode ?? "")-\(row.courseID ?? "")-\(row.dateString ?? "")-\(row.timeDescription)",
                term: row.termCode ?? "",
                name: name,
                courseID: row.courseID ?? "",
                teacher: row.teacherName ?? "",
                classroom: row.location ?? "",
                dateString: (row.dateString ?? "").split(separator: " ").first.map(String.init) ?? (row.dateString ?? ""),
                beginTime: beginTime,
                endTime: endTime,
                examMode: row.examMode ?? "",
                seatID: row.seatID ?? ""
            )
        }
    }

    /// 获取指定目标学期的第一周起始日期。
    ///
    /// 课表当前周数、小组件时间线和灵动岛课程推导都依赖这个日期基准。
    private func fetchFirstDayString(term: String) async throws -> String {
        let requestParam = #"{"XNXQDM":"\#(term)","ZC":"1"}"#
        let response: WeekDateResponse = try await sendJSONRequest(
            path: "/jwapp/sys/wdkbby/wdkbByController/cxzkbrq.do",
            method: "POST",
            body: [("requestParamStr", requestParam)]
        )

        guard let firstDay = response.data.first(where: { $0.week == 1 })?.date else {
            throw ScheduleServiceError.invalidResponse
        }

        return firstDay
    }

    /// 解析乐学日历订阅 URL。
    ///
    /// 乐学页面会把真正的订阅链接埋在 HTML 中，而且可能混用 `webcal://`、`http://` 与 HTML 转义，
    /// 所以这里要做一整套兜底提取。
    private func resolveLexueCalendarURL(storedURL: String) async throws -> String {
        if !storedURL.isEmpty {
            return storedURL
        }

        let indexHTML = try await sendStringRequest(
            baseURL: lexueBaseURL,
            path: "/",
            requiresTeachingCenterSession: false
        )
        guard
            let sesskey = indexHTML.captureGroups(pattern: #"[\"']sesskey[\"']:[\"']([^\"']+)[\"']"#).first,
            !sesskey.isEmpty
        else {
            throw ScheduleServiceError.invalidLexuePage
        }

        let calendarHTML = try await sendStringRequest(
            baseURL: lexueBaseURL,
            path: "/calendar/export.php",
            method: "POST",
            body: [
                ("sesskey", sesskey),
                ("_qf__core_calendar_export_form", "1"),
                ("events[exportevents]", "all"),
                ("period[timeperiod]", "recentupcoming"),
                ("generateurl", "获取日历网址"),
            ],
            requiresTeachingCenterSession: false
        )

        let fullURL =
            extractCalendarURL(from: calendarHTML, pattern: #"class=["'][^"']*calendarurl[^"']*["'][^>]*>[\s\S]*?(https?://[^<"'\s]+)"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"class=["'][^"']*calendarurl[^"']*["'][^>]*>[\s\S]*?(webcal://[^<"'\s]+)"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"value=["'](https?://[^"']+)["']"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"value=["'](webcal://[^"']+)["']"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"href=["'](https?://[^"']+)["']"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"href=["'](webcal://[^"']+)["']"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"https?://[^\s"'<]+"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"webcal://[^\s"'<]+"#)

        guard let fullURL else {
            throw ScheduleServiceError.invalidCalendarURL
        }

        return ScheduleURLUpgrade.upgradedURLString(from: fullURL)
    }

    /// 下载并解析乐学 ICS 数据。
    private func fetchLexueEvents(urlString: String) async throws -> [DDLEventRecord] {
        // 订阅链接可能以 webcal:// 或 http:// 返回，这里统一标准化后再拉取 ICS。
        let secureURLString = ScheduleURLUpgrade.upgradedURLString(from: urlString)

        guard let url = URL(string: secureURLString) else {
            throw ScheduleServiceError.invalidCalendarURL
        }

        let request = URLRequest(url: url)
        let ics = try await sendStringRequest(request)
        return try ScheduleICSParser.parse(ics)
    }

    /// 发送教务/乐学 JSON 请求并自动解码响应。
    ///
    /// 学校接口大量使用表单 POST + JSON 返回，因此这里统一封装。
    private func sendJSONRequest<Response: Decodable>(
        baseURL: URL? = nil,
        path: String,
        method: String = "GET",
        body: [(String, String)] = []
    ) async throws -> Response {
        var request = URLRequest(url: buildURL(baseURL: baseURL ?? activeSchoolBaseURL, path: path))
        request.httpMethod = method
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        if method == "POST" {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(body)
        }

        let (data, response) = try await sendRequest(request)
        if isTeachingCenterAuthenticationFailure(data: data, response: response) {
            throw ScheduleServiceError.teachingCenterSessionExpired
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw httpError(response.statusCode)
        }

        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            // 登录页 HTML 已在上方按内容特征识别。其余无法解码的 2xx 响应可能只是学校
            // 网关故障或接口改版，不能误导用户说“登录失效”。
            throw ScheduleServiceError.invalidResponse
        }
    }

    /// 发送返回字符串正文的请求，主要用于 HTML 页和 ICS 文件。
    private func sendStringRequest(
        baseURL: URL? = nil,
        path: String,
        method: String = "GET",
        body: [(String, String)] = [],
        requiresTeachingCenterSession: Bool = true
    ) async throws -> String {
        var request = URLRequest(url: buildURL(baseURL: baseURL ?? activeSchoolBaseURL, path: path))
        request.httpMethod = method

        if method == "POST" {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(body)
        }

        let (data, response) = try await sendRequest(request)
        if requiresTeachingCenterSession,
           isTeachingCenterAuthenticationFailure(data: data, response: response)
        {
            throw ScheduleServiceError.teachingCenterSessionExpired
        }
        guard (200 ..< 400).contains(response.statusCode) else {
            throw httpError(response.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func sendStringRequest(_ request: URLRequest) async throws -> String {
        let (data, response) = try await sendRequest(request)
        guard (200 ..< 400).contains(response.statusCode) else {
            throw httpError(response.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 统一底层请求入口，并在发起前做 HTTPS 升级。
    private func sendRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let secureRequest: URLRequest
        if let url = request.url, let upgradedURL = ScheduleURLUpgrade.upgradedURL(from: url), upgradedURL != url {
            var upgradedRequest = request
            upgradedRequest.url = upgradedURL
            secureRequest = upgradedRequest
        } else {
            secureRequest = request
        }
        do {
            let result = try await HTTPClient(transport: session).send(
                secureRequest,
                accepting: 100 ..< 600
            )
            return (result.data, result.response)
        } catch is HTTPClientError {
            throw ScheduleServiceError.invalidResponse
        }
    }

    /// 组装最终请求 URL，兼容绝对路径与相对路径。
    private func buildURL(baseURL: URL, path: String) -> URL {
        if baseURL.host == "webvpn.bit.edu.cn", path.hasPrefix("/") {
            return URL(string: baseURL.absoluteString + path) ?? baseURL
        }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL.appending(path: path)
    }

    private var activeSchoolBaseURL: URL {
        let studentID = storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return teachingCenterState.hasUsableSession(for: studentID) ? webVPNSchoolBaseURL : schoolBaseURL
    }

    private func isTeachingCenterAuthenticationFailure(
        data: Data,
        response: HTTPURLResponse
    ) -> Bool {
        if response.statusCode == 401 || response.statusCode == 403 {
            return true
        }

        if let url = response.url {
            let host = url.host?.lowercased() ?? ""
            let path = url.path.lowercased()
            if host == "sso.bit.edu.cn"
                || path.contains("/cas/login")
                || path.contains("/auth-protocol-core/login")
            {
                return true
            }
        }
        if let location = response.value(forHTTPHeaderField: "Location")?.lowercased(),
           location.contains("login") || location.contains("/cas/")
        {
            return true
        }
        return looksLikeLoginHTML(data)
    }

    private func looksLikeLoginHTML(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let prefix = String(decoding: data.prefix(16_384), as: UTF8.self).lowercased()
        guard prefix.contains("<html") || prefix.contains("<!doctype html") else { return false }
        return prefix.contains("统一身份认证")
            || prefix.contains("用户名密码")
            || prefix.contains("cas/login")
            || prefix.contains("login-page-flowkey")
    }

    /// 用正则从乐学页面里尝试提取订阅链接。
    private func extractCalendarURL(from html: String, pattern: String) -> String? {
        html.captureGroups(pattern: pattern, options: [.dotMatchesLineSeparators]).first
            .map { rawURLString in
                // 乐学页面可能把参数里的 & 转义成 &amp;，不先还原就会打成 404。
                let urlString = decodeHTML(urlString: rawURLString)

                if urlString.lowercased().hasPrefix("webcal://") {
                    return "https://" + urlString.dropFirst("webcal://".count)
                }
                return ScheduleURLUpgrade.upgradedURLString(from: urlString)
            }
    }

    /// 还原 HTML 属性里的常见实体转义。
    private func decodeHTML(urlString: String) -> String {
        urlString
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    /// 把字段组装成 `application/x-www-form-urlencoded` 表单体。
    private func formBody(_ fields: [(String, String)]) -> Data {
        let encoded = fields.map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }
        .joined(separator: "&")

        return Data(encoded.utf8)
    }

    /// 表单值专用 URL 编码。
    private func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 把 HTTP 状态码包装成统一错误。
    private func httpError(_ statusCode: Int) -> NSError {
        NSError(
            domain: "BIT101.Schedule",
            code: statusCode,
            userInfo: [NSLocalizedDescriptionKey: "请求失败，HTTP 状态码 \(statusCode)。"]
        )
    }
}
