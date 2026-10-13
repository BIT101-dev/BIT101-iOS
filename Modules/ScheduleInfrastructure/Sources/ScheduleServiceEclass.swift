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

@MainActor
final class EclassSnapshotBudget {
    static let parallelRequests = 4
    private let deadline: ContinuousClock.Instant
    private var remainingBytes: Int

    init(timeout: TimeInterval = URLRequest(url: AppURL.required("https://zy-eclass.bit.edu.cn")).timeoutInterval,
         maximumBytes: Int = HTTPResponseResourceLimits.maximumStructuredBytes * parallelRequests) {
        deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        remainingBytes = maximumBytes
    }

    func remainingTimeout() throws -> TimeInterval {
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw URLError(.timedOut) }
        let components = remaining.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    func consume(_ bytes: Int) throws {
        _ = try remainingTimeout()
        guard bytes <= remainingBytes else { throw HTTPClientError.responseTooLarge }
        remainingBytes -= bytes
    }
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
        if let context = SchoolLoginHTMLParser.parseSecondFactorPage(html: String(decoding: data, as: UTF8.self), baseURL: schoolSSOBaseURL, documentURL: response.url ?? request.url) {
            try await completeSchoolSecondFactor(context, handler: schoolSMSCodeHandler, smsDeliveryMode: smsDeliveryMode, owner: owner)
            _ = try await sendRequest(request, owner: owner)
        } else if !(200 ..< 300).contains(response.statusCode) || response.url?.host?.lowercased() != "zy-eclass.bit.edu.cn" {
            throw ScheduleServiceError.eclassAuthenticationFailed
        }
    }

    func fetchEclassSnapshot(owner: SchoolSessionIdentity, budget: EclassSnapshotBudget = .init()) async throws -> EclassDDLResult {
        let remaining = try budget.remainingTimeout()
        return try await withThrowingTaskGroup(of: EclassDDLResult.self) { group in
            group.addTask { try await self.fetchEclassSnapshotBody(owner: owner, budget: budget) }
            group.addTask {
                try await Task.sleep(for: .seconds(remaining))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func fetchEclassSnapshotBody(owner: SchoolSessionIdentity, budget: EclassSnapshotBudget) async throws -> EclassDDLResult {
        guard !credentials.currentStudentID.isEmpty else { throw ScheduleServiceError.notLoggedIn }
        var courses: [EclassCoursePage.Course] = []
        var seenNames: [Int: String] = [:]
        var page = 1
        var totalPages: Int?
        while true {
            try Task.checkCancellation()
            let response: EclassCoursePage = try await eclassRequest(path: "/api/my-courses", page: page, owner: owner, budget: budget)
            if page == 1 { totalPages = response.pages }
            guard response.pages == totalPages, response.courses.count <= 100 else { throw ScheduleServiceError.invalidResponse }
            guard response.page == nil || response.page == page else { throw ScheduleServiceError.invalidResponse }
            guard response.courses.allSatisfy({ $0.id > 0 && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { throw ScheduleServiceError.invalidResponse }
            let newCourses = try response.courses.filter { course in
                let name = course.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let previous = seenNames[course.id] {
                    guard previous == name else { throw ScheduleServiceError.invalidResponse }
                    return false
                }
                seenNames[course.id] = name
                return true
            }
            guard response.courses.isEmpty || !newCourses.isEmpty else { throw ScheduleServiceError.invalidResponse }
            courses.append(contentsOf: newCourses)
            if let pages = totalPages {
                guard pages >= 0, pages == 0 || page <= pages,
                      pages > 0 || response.courses.isEmpty,
                      !response.courses.isEmpty || page >= pages else { throw ScheduleServiceError.invalidResponse }
                if page >= pages { break }
            } else if response.courses.count < 100 { break }
            page += 1
        }

        var results: [Int: EclassDDLResult] = [:]
        let fetchActivities: @MainActor @Sendable (EclassCoursePage.Course) async throws -> (Int, EclassDDLResult) = { course in
            let response: EclassActivityPage = try await self.eclassRequest(path: "/api/courses/\(course.id)/activities", owner: owner, budget: budget)
            return (course.id, try await Self.mapEclassActivities(response, courseName: course.name))
        }
        try await withThrowingTaskGroup(of: (Int, EclassDDLResult).self) { group in
            var remaining = courses.makeIterator()
            for _ in 0 ..< min(EclassSnapshotBudget.parallelRequests, courses.count) {
                if let course = remaining.next() {
                    group.addTask { try await fetchActivities(course) }
                }
            }
            while let result = try await group.next() {
                results[result.0] = result.1
                _ = try budget.remainingTimeout()
                if let course = remaining.next() {
                    group.addTask { try await fetchActivities(course) }
                }
            }
        }
        let result = try await Self.combineEclassResults(courses.compactMap { results[$0.id] })
        try validateAuthenticationOwner(owner)
        _ = try budget.remainingTimeout()
        return result
    }

    @concurrent
    static func decodeEclassResponse<Response: Decodable & Sendable>(_ data: Data) async throws -> Response {
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result: Response
        do { result = try decoder.decode(Response.self, from: data) }
        catch {
            let failure = ScheduleServiceError.invalidResponse as NSError
            throw NSError(domain: failure.domain, code: failure.code,
                userInfo: failure.userInfo.merging([NSUnderlyingErrorKey: error,
                    NSLocalizedDescriptionKey: failure.localizedDescription]) { _, value in value })
        }
        try Task.checkCancellation()
        return result
    }

    @concurrent
    static func mapEclassActivities(_ response: EclassActivityPage, courseName: String) async throws -> EclassDDLResult {
        var events: [DDLEventRecord] = []
        var types: [String: Int] = [:]
        var withoutDeadline = 0
        for activity in response.activities {
            try Task.checkCancellation()
            types[activity.type ?? "unknown", default: 0] += 1
            if let event = try activity.event(courseName: courseName) { events.append(event) }
            else if activity.hasHomeworkFields, activity.type?.lowercased() != "material" { withoutDeadline += 1 }
        }
        return EclassDDLResult(events: events, courseCount: 1, activityCount: response.activities.count,
                              activityTypes: types, homeworkWithoutDeadlineCount: withoutDeadline)
    }

    @concurrent
    private static func combineEclassResults(_ results: [EclassDDLResult]) async throws -> EclassDDLResult {
        try Task.checkCancellation()
        var uniqueEvents: [String: DDLEventRecord] = [:]
        var activityCount = 0
        var types: [String: Int] = [:]
        var withoutDeadline = 0
        for result in results {
            try Task.checkCancellation()
            activityCount += result.activityCount
            withoutDeadline += result.homeworkWithoutDeadlineCount
            for (type, count) in result.activityTypes { types[type, default: 0] += count }
            for event in result.events {
                if let previous = uniqueEvents[event.id] {
                    guard previous.title == event.title, previous.dueAt == event.dueAt, previous.done == event.done
                    else { throw ScheduleServiceError.invalidResponse }
                } else { uniqueEvents[event.id] = event }
            }
        }
        let events = uniqueEvents.values.sorted {
            $0.dueAt == $1.dueAt ? $0.id < $1.id : $0.dueAt < $1.dueAt
        }
        try Task.checkCancellation()
        return EclassDDLResult(events: events, courseCount: results.count, activityCount: activityCount,
                              activityTypes: types, homeworkWithoutDeadlineCount: withoutDeadline)
    }

    private func eclassRequest<Response: Decodable & Sendable>(path: String, page: Int? = nil, owner: SchoolSessionIdentity, budget: EclassSnapshotBudget) async throws -> Response {
        var request = URLRequest(url: AppURL.required("https://zy-eclass.bit.edu.cn").appending(path: path))
        request.timeoutInterval = try budget.remainingTimeout()
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let page {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "page": page, "page_size": 100, "fields": "id,name", "conditions": [String: String](),
            ])
        }
        let (data, response) = try await sendRequest(request, owner: owner)
        try budget.consume(data.count)
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
        let result: Response = try await Self.decodeEclassResponse(data)
        try validateAuthenticationOwner(owner)
        _ = try budget.remainingTimeout()
        return result
    }
}
