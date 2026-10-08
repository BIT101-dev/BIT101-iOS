import ClientCore
import Foundation
import ScheduleDomain
import SchedulePorts
import TransportCore

nonisolated struct EclassCoursePage: Decodable, Sendable {
    struct Course: Decodable, Sendable {
        let id: Int
        let name: String
    }
    let courses: [Course]
    let page: Int?
    let pages: Int?
}

nonisolated struct EclassActivityPage: Decodable, Sendable {
    let activities: [EclassActivity]
}

nonisolated struct EclassActivity: Decodable, Sendable {
    let id: Int
    let title: String?
    let type: String?
    let endTime: String?
    let visibleEndAt: String?
    let submitTimes: Int?
    let lateSubmissionCount: Int?
    let isReviewHomework: Bool?

    var hasHomeworkFields: Bool { submitTimes != nil || lateSubmissionCount != nil || isReviewHomework != nil }

    func event(courseName: String) throws -> DDLEventRecord? {
        guard type?.lowercased() != "material", hasHomeworkFields else { return nil }
        guard id > 0 else { throw ScheduleServiceError.invalidResponse }
        let end = try Self.deadlineDate(endTime)
        let visibleEnd = try Self.deadlineDate(visibleEndAt)
        guard let dueAt = end ?? visibleEnd else { return nil }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DDLEventRecord(id: "eclass:\(id)", group: "eclass", title: name.isEmpty ? "未命名作业" : name,
                              text: courseName, dueAt: dueAt, done: false)
    }

    private static func deadlineDate(_ raw: String?) throws -> Date? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.lowercased() != "null" else { return nil }
        guard let date = parseTime(text) else { throw ScheduleServiceError.invalidResponse }
        return date
    }

    static func parseTime(_ raw: String?) -> Date? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.lowercased() != "null" else { return nil }
        for fractional in [true, false] {
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: fractional).parse(text) {
                return date
            }
        }
        for formatter in localTimeFormatters {
            if let date = formatter.date(from: text), formatter.string(from: date) == text { return date }
        }
        return nil
    }

    private static let localTimeFormatters: [DateFormatter] = {
        ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm",
         "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"].map { format in
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = format
            formatter.isLenient = false
            return formatter
        }
    }()
}

public nonisolated struct EclassDDLResult: Sendable {
    public let events: [DDLEventRecord]
    public let courseCount: Int
    public let activityCount: Int
    public let activityTypes: [String: Int]
    public let homeworkWithoutDeadlineCount: Int
}

extension ScheduleService {
    /// 获取全部课程并验证每门课的活动，完整成功后交给仓库更新。
    public func fetchEclassDDLEvents(schoolSMSCodeHandler: SchoolSMSCodeHandler? = nil) async throws -> EclassDDLResult {
        try await fetchEclassDDLEvents(schoolSMSCodeHandler: schoolSMSCodeHandler, smsDeliveryMode: .send)
    }

    public func fetchEclassDDLEventsForPreflight() async throws -> EclassDDLResult {
        try await fetchEclassDDLEvents(schoolSMSCodeHandler: nil, smsDeliveryMode: .preflight)
    }

    private func fetchEclassDDLEvents(schoolSMSCodeHandler: SchoolSMSCodeHandler?, smsDeliveryMode: SchoolSMSDeliveryMode) async throws -> EclassDDLResult {
        let owner = credentials.schoolSessionIdentity
        try validateAuthenticationOwner(owner)
        do {
            return try await fetchEclassSnapshot(owner: owner)
        } catch ScheduleServiceError.eclassAuthenticationFailed {
            try await ensureSchoolSession(schoolSMSCodeHandler: schoolSMSCodeHandler, smsDeliveryMode: smsDeliveryMode, owner: owner)
            try await prepareEclassAccess(schoolSMSCodeHandler: schoolSMSCodeHandler, smsDeliveryMode: smsDeliveryMode, owner: owner)
            return try await fetchEclassSnapshot(owner: owner)
        }
    }

    private func prepareEclassAccess(schoolSMSCodeHandler: SchoolSMSCodeHandler?, smsDeliveryMode: SchoolSMSDeliveryMode, owner: SchoolSessionIdentity) async throws {
        let request = URLRequest(url: AppURL.required("https://zy-eclass.bit.edu.cn/user/index"))
        let (data, response) = try await sendRequest(request, owner: owner)
        try Task.checkCancellation()
        if let context = SchoolLoginHTMLParser.parseSecondFactorPage(html: String(decoding: data, as: UTF8.self), baseURL: schoolSSOBaseURL) {
            try await completeSchoolSecondFactor(context, handler: schoolSMSCodeHandler, smsDeliveryMode: smsDeliveryMode, owner: owner)
            _ = try await sendRequest(request, owner: owner)
        } else if !(200 ..< 300).contains(response.statusCode) || response.url?.host?.lowercased() != "zy-eclass.bit.edu.cn" {
            throw ScheduleServiceError.eclassAuthenticationFailed
        }
    }

    private func fetchEclassSnapshot(owner: SchoolSessionIdentity) async throws -> EclassDDLResult {
        guard !credentials.currentStudentID.isEmpty else { throw ScheduleServiceError.notLoggedIn }
        var courses: [EclassCoursePage.Course] = []
        var seenIDs: Set<Int> = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let response: EclassCoursePage = try await eclassRequest(path: "/api/my-courses", page: page, owner: owner)
            guard response.page == nil || response.page == page else { throw ScheduleServiceError.invalidResponse }
            guard response.courses.allSatisfy({ $0.id > 0 && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { throw ScheduleServiceError.invalidResponse }
            let newCourses = response.courses.filter { seenIDs.insert($0.id).inserted }
            guard response.courses.isEmpty || !newCourses.isEmpty else { throw ScheduleServiceError.invalidResponse }
            courses.append(contentsOf: newCourses)
            if let pages = response.pages {
                guard pages >= 0, pages == 0 || page <= pages,
                      !response.courses.isEmpty || page >= pages else { throw ScheduleServiceError.invalidResponse }
                if page >= pages { break }
            } else if response.courses.count < 100 { break }
            page += 1
        }

        var events: [DDLEventRecord] = []
        var activityCount = 0
        var activityTypes: [String: Int] = [:]
        var homeworkWithoutDeadlineCount = 0
        let fetchActivities: @MainActor @Sendable (EclassCoursePage.Course) async throws -> (EclassCoursePage.Course, EclassActivityPage) = { course in
            let response: EclassActivityPage = try await self.eclassRequest(path: "/api/courses/\(course.id)/activities", owner: owner)
            return (course, response)
        }
        try await withThrowingTaskGroup(of: (EclassCoursePage.Course, EclassActivityPage).self) { group in
            var remaining = courses.makeIterator()
            for _ in 0 ..< min(4, courses.count) {
                if let course = remaining.next() {
                    group.addTask { try await fetchActivities(course) }
                }
            }
            while let result = try await group.next() {
                activityCount += result.1.activities.count
                for activity in result.1.activities {
                    activityTypes[activity.type ?? "unknown", default: 0] += 1
                    if let event = try activity.event(courseName: result.0.name) {
                        events.append(event)
                    } else if activity.hasHomeworkFields, activity.type?.lowercased() != "material" {
                        homeworkWithoutDeadlineCount += 1
                    }
                }
                if let course = remaining.next() {
                    group.addTask { try await fetchActivities(course) }
                }
            }
        }
        try Task.checkCancellation()
        let uniqueEvents = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return EclassDDLResult(events: uniqueEvents.values.sorted {
            $0.dueAt == $1.dueAt ? $0.id < $1.id : $0.dueAt < $1.dueAt
        }, courseCount: courses.count, activityCount: activityCount, activityTypes: activityTypes,
            homeworkWithoutDeadlineCount: homeworkWithoutDeadlineCount)
    }

    private func eclassRequest<Response: Decodable>(path: String, page: Int? = nil, owner: SchoolSessionIdentity) async throws -> Response {
        var request = URLRequest(url: AppURL.required("https://zy-eclass.bit.edu.cn").appending(path: path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let page {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "page": page, "page_size": 100, "fields": "id,name", "conditions": [String: String](),
            ])
        }
        let (data, response) = try await sendRequest(request, owner: owner)
        try Task.checkCancellation()
        let host = response.url?.host?.lowercased()
        if response.statusCode == 401 || response.statusCode == 403 || (300 ..< 400).contains(response.statusCode)
            || host != "zy-eclass.bit.edu.cn" {
            throw ScheduleServiceError.eclassAuthenticationFailed
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ScheduleServiceError.schoolResponse("课程中心请求失败，HTTP \(response.statusCode)。")
        }
        if response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true {
            throw ScheduleServiceError.eclassAuthenticationFailed
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw ScheduleServiceError.invalidResponse }
    }
}
