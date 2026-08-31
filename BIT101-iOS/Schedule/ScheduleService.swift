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
    let schoolBaseURL = URL(string: "https://jxzxehallapp.bit.edu.cn")!
    let webVPNSchoolBaseURL = URL(
        string: "https://webvpn.bit.edu.cn/https/77726476706e69737468656265737421faef5b842238695c720999bcd6572a216b231105adc27d"
    )!
    let bitLoginBaseURL = URL(string: "https://login.bit101.flwfdd.xyz")!
    let lexueBaseURL = URL(string: "https://lexue.bit.edu.cn")!
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

    struct SMSCodeRequest: Encodable {
        let code: String
    }

    struct ChallengeEnvelope: Decodable {
        let detail: ChallengePayload
    }

    struct ChallengePayload: Decodable {
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

    struct CookieResponse: Decodable {
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

}
