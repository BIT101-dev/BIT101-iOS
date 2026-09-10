//
//  ScheduleService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// 日程同步过程中的统一错误。
///
/// 该枚举承接 UI 展示所需的错误；接口差异和字段缺失在此归并为少量用户可理解的文案。
enum ScheduleServiceError: LocalizedError {
    case notLoggedIn
    case secondFactorRequired(BITLoginAuthenticationChallenge)
    case challengeInvalid(String)
    case teachingCenterSessionExpired
    case authenticationFailed(String)
    case schoolTransportFailure
    case schoolSecondFactorRequired
    case invalidResponse
    case invalidLexuePage
    case invalidCalendarURL
    case invalidCalendarData
    case schoolResponse(String)

    var isUnpublishedCourseSchedule: Bool {
        guard case let .schoolResponse(message) = self else { return false }
        return message.contains("课表未发布") || message.contains("课表尚未发布")
    }

    /// 学校统一认证后端可能把 WebVPN/TLS 故障作为 challenge 的失败消息返回。
    /// 此类消息归入学校传输失败，验证码失效分支保留给 challenge 无效响应。
    var isSchoolTransportFailure: Bool {
        switch self {
        case .schoolTransportFailure:
            return true
        case let .challengeInvalid(message), let .authenticationFailed(message):
            return Self.looksLikeTransportFailure(message)
        default:
            return false
        }
    }

    var schoolTransportFailureMessage: String {
        "学校统一认证服务暂时无法建立安全连接，请稍后重试。"
    }

    private static func looksLikeTransportFailure(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("ssl")
            || value.contains("certificate")
            || value.contains("证书")
            || value.contains("httpsconnectionpool")
            || value.contains("tls")
    }

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
        case .schoolTransportFailure:
            return schoolTransportFailureMessage
        case .schoolSecondFactorRequired:
            return "学校统一身份认证要求短信二次验证。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .invalidLexuePage:
            return "无法从乐学页面提取日历订阅信息。"
        case .invalidCalendarURL:
            return "乐学日历订阅链接无效。"
        case .invalidCalendarData:
            return "乐学日历数据解析失败。"
        case let .schoolResponse(message):
            return message
        }
    }
}

/// 同步课程表和考试后的组合结果。
///
/// 课程、考试和首周日期来自不同接口；“同步课表”按一个业务动作一起更新，返回体集中承载三类数据。
struct CourseSyncPayload {
    let term: String
    let firstDayString: String
    let courses: [CourseRecord]
    let exams: [ExamRecord]
}

/// 校正上半学期中由小学期产生的周次整体偏移。
///
/// 教务接口的 `SKZC` 有时沿用完整校历计数，`YPSJDD` 按小学期重新从第 1 周标注。
/// 代码仅在证据确认偏移为 3 周时全局减 3 周，其他情况保留原数据。
nonisolated enum SmallTermWeekNormalizer {
    /// 结果包含两种状态：`0` 表示不变，`3` 表示全局减 3 周。
    static let correctionOffset = 3

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
        var evidenceCount = 0
        for group in groups.values {
            let raw = group.rawWeeks.sorted()
            let described = group.describedWeeks.sorted()
            // 个别短课返回一周，或使用 -2/-1 这类开学前周次；这类组从全学期叠加候选中排除
            // 偏移判定，其他证据组继续参与校正。
            guard raw.count == described.count, raw.count >= 2,
                  described.allSatisfy({ $0 > 0 })
            else { continue }
            let differences = Set(zip(raw, described).map(-))
            guard differences.count == 1, let difference = differences.first else { continue }
            offsets.insert(difference)
            evidenceCount += 1
        }

        guard offsets == Set([correctionOffset]), evidenceCount >= 2 else { return unchanged }

        let shiftedFirstDay = parseDate(firstDayString)
            .flatMap { calendar.date(byAdding: .day, value: correctionOffset * 7, to: $0) }

        return Result(
            firstDayString: shiftedFirstDay.map(formatDate) ?? firstDayString,
            courses: courses.map { shiftingWeeks(of: $0, by: -correctionOffset) },
            offset: correctionOffset
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

    static func weeksDescribed(in text: String) -> Set<Int> {
        let pattern = #"(-?\d{1,2})\s*(?:[-－—~～至]\s*(-?\d{1,2}))?\s*周"#
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
        course.replacingWeeks(course.weeks.map { $0 < 1 ? $0 : $0 + delta })
    }
}

/// 教务接口把同一门课的多个上课安排合并到 `YPSJDD`，每行的 `SKXQ`、节次和教室对应一项安排。
/// 解析器按行恢复周次，各星期使用对应行的周次。
nonisolated enum CourseScheduleRowParser {
    private struct Occurrence {
        let weeks: Set<Int>
        let weekday: Int
        let startSection: Int
        let endSection: Int
        let classroom: String
    }

    static func narrowedCourses(_ courses: [CourseRecord]) -> [CourseRecord] {
        courses.map { course in
            let weeks = narrowedWeeks(for: course)
            return weeks == course.weeks ? course : course.replacingWeeks(weeks)
        }
    }

    private static func narrowedWeeks(for course: CourseRecord) -> [Int] {
        let occurrences = occurrences(in: course.description)
        guard !occurrences.isEmpty else { return course.weeks }

        let sameTime = occurrences.filter {
            $0.weekday == course.weekday
                && $0.startSection == course.startSection
                && $0.endSection == course.endSection
        }
        guard !sameTime.isEmpty else { return course.weeks }

        let exact = sameTime.filter {
            normalizedClassroom($0.classroom) == normalizedClassroom(course.classroom)
        }
        let matched = exact.isEmpty && sameTime.count == 1 ? sameTime : exact
        guard !matched.isEmpty else { return course.weeks }

        let describedWeeks = matched.reduce(into: Set<Int>()) { result, occurrence in
            result.formUnion(occurrence.weeks)
        }
        let currentWeeks = Set(course.weeks)
        guard !describedWeeks.isEmpty else { return course.weeks }
        if describedWeeks.allSatisfy({ $0 < 0 }) {
            return describedWeeks.sorted()
        }
        // 解析器在描述周次属于当前课程周次集合时收窄，坐标系证据不足时保留原值。
        // 小学期整体 -3 由 SmallTermWeekNormalizer 统一处理。
        guard describedWeeks.isSubset(of: currentWeeks) else { return course.weeks }
        return course.weeks.filter { describedWeeks.contains($0) }
    }

    private static func occurrences(in text: String) -> [Occurrence] {
        let pattern = #"((?:-?\d{1,2}\s*(?:[-－—~～至]\s*-?\d{1,2})?\s*周)(?:\s*,\s*(?:-?\d{1,2}\s*(?:[-－—~～至]\s*-?\d{1,2})?\s*周))*)\s*星期([一二三四五六日天])\s*第?(\d{1,2})\s*节?\s*[-－—~～至]\s*第?(\d{1,2})\s*节\s*(.*?)(?=,\s*-?\d{1,2}\s*(?:[-－—~～至]\s*-?\d{1,2})?\s*周|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard
                let weeksRange = Range(match.range(at: 1), in: text),
                let weekdayRange = Range(match.range(at: 2), in: text),
                let startRange = Range(match.range(at: 3), in: text),
                let endRange = Range(match.range(at: 4), in: text),
                let classroomRange = Range(match.range(at: 5), in: text),
                let startSection = Int(text[startRange]),
                let endSection = Int(text[endRange]),
                let weekday = weekday(from: String(text[weekdayRange]))
            else { return nil }

            return Occurrence(
                weeks: SmallTermWeekNormalizer.weeksDescribed(in: String(text[weeksRange])),
                weekday: weekday,
                startSection: startSection,
                endSection: endSection,
                classroom: String(text[classroomRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func weekday(from value: String) -> Int? {
        switch value {
        case "一": return 1
        case "二": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "日", "天": return 7
        default: return nil
        }
    }

    private static func normalizedClassroom(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isWhitespace }
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
    let schoolBaseURL = AppURL.required("https://jxzxehallapp.bit.edu.cn")
    let webVPNSchoolBaseURL = AppURL.required("https://webvpn.bit.edu.cn/https/77726476706e69737468656265737421faef5b842238695c720999bcd6572a216b231105adc27d")
    let bitLoginBaseURL = AppURL.required("https://login.bit101.flwfdd.xyz")
    let schoolSSOBaseURL = AppURL.required("https://sso.bit.edu.cn")
    let lexueBaseURL = AppURL.required("https://lexue.bit.edu.cn")
    let storage = LoginStorage.shared
    let teachingCenterState = TeachingCenterSessionState.shared
    let session: URLSession
    private let redirectDelegate = HTTPSUpgradingRedirectDelegate()
    static let authenticationWaitSeconds: TimeInterval = 90
    static let decoder = JSONDecoder()

    struct AuthenticationCredentials: Encodable {
        let username: String?
        let password: String?
        let challengeID: String?

        enum CodingKeys: String, CodingKey {
            case username, password
            case challengeID = "challenge_id"
        }
    }

    struct CookieResponse: Decodable {
        let data: [String: String]
    }

    /// 构造带共享 cookie 与 HTTPS 升级能力的会话。
    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        // 教学中心提供校外 WebVPN 与校园网直连两条链路。配置关闭连接等待，让当前网络
        // 未解析主机及时返回 DNS 错误，直连回退继续执行。
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

}
