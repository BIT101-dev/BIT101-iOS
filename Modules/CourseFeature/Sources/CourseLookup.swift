import TransportCore
import CommunityCore
import Foundation

/// 课程评价入口共用的课程匹配规则。
///
/// 日程课程和成绩记录使用课程号、课程名等外部标识匹配候选课程；匹配过程统一清理
/// 格式、消除教师歧义并判断唯一性，结果进入同一个课程详情与评价页面。
nonisolated enum CourseLookupMatcher {
    static func bestMatch(
        courseNumber: String,
        courseName: String,
        teacher: String,
        candidates: [CourseSummary]
    ) -> CourseSummary? {
        let expectedNumber = normalizedIdentifier(courseNumber)
        let expectedName = normalizedText(courseName)
        let expectedTeacher = teacher.trimmingCharacters(in: .whitespacesAndNewlines)

        let sameNumber = expectedNumber.isEmpty ? [] : candidates.filter {
            normalizedIdentifier($0.number) == expectedNumber
        }
        let sameName = expectedName.isEmpty ? [] : candidates.filter {
            normalizedText($0.name) == expectedName
        }
        let hasConflictingUniqueIdentity = sameNumber.count == 1
            && sameName.count == 1
            && sameNumber[0].id != sameName[0].id

        if !normalizedTeacher(expectedTeacher).isEmpty {
            if let match = matchingTeacher(expectedTeacher, candidates: sameNumber) {
                return match
            }
            if let match = matchingTeacher(expectedTeacher, candidates: sameName) {
                return match
            }

            if hasConflictingUniqueIdentity {
                return nil
            }

            // 课程缺少教师字段时，课程号唯一且教师候选为空可直接确定匹配结果。
            if sameNumber.count == 1,
               normalizedTeacher(sameNumber[0].teachersName).isEmpty
            {
                return sameNumber[0]
            }
            return nil
        }

        if hasConflictingUniqueIdentity {
            return nil
        }

        if sameNumber.count == 1 { return sameNumber[0] }
        if sameName.count == 1 { return sameName[0] }

        // 成绩接口通常没有教师字段；课程号和课程名交集中的记录按候选顺序进入详情。
        let sameIdentity = sameNumber.filter { numberCourse in
            sameName.contains(where: { $0.id == numberCourse.id })
        }
        return sameIdentity.first
    }

    static func exactMatch(courseNumber: String, courseName: String, teacher: String,
        candidates: [CourseSummary]) -> CourseSummary? {
        let number = normalizedIdentifier(courseNumber), name = normalizedText(courseName)
        guard !number.isEmpty, !name.isEmpty else { return nil }
        let teachers = teacherNames(teacher)
        return bestMatch(courseNumber: courseNumber, courseName: courseName, teacher: teacher,
            candidates: candidates.filter {
                normalizedIdentifier($0.number) == number && normalizedText($0.name) == name
                    && (teachers.isEmpty || teacherNames($0.teachersName) == teachers)
            })
    }

    private static func matchingTeacher(_ expected: String, candidates: [CourseSummary]) -> CourseSummary? {
        let expectedNames = teacherNames(expected)
        let exact = candidates.filter { teacherNames($0.teachersName) == expectedNames }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        let partial = candidates.filter { !expectedNames.isDisjoint(with: teacherNames($0.teachersName)) }
        return partial.count == 1 ? partial[0] : nil
    }

    private static func teacherNames(_ value: String) -> Set<String> {
        let separators = CharacterSet(charactersIn: ",，、/&;；")
            .union(.whitespacesAndNewlines)
        return Set(value
            .replacingOccurrences(of: "老师", with: "")
            .components(separatedBy: separators)
            .map(normalizedText)
            .filter { !$0.isEmpty })
    }

    private static func normalizedTeacher(_ value: String) -> String {
        normalizedText(value).replacingOccurrences(of: "老师", with: "")
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            .lowercased()
    }

    private static func normalizedText(_ value: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters
        let whitespace = CharacterSet.whitespacesAndNewlines
        return String(value.unicodeScalars.filter { !punctuation.contains($0) && !whitespace.contains($0) })
            .lowercased()
    }
}

/// 课程评价入口共用的远程检索与消歧流程。
///
/// 课程号和课程名并行检索，完整标识匹配后立即进入详情；单路故障时保留成功候选。
/// 候选按统一规则消歧，并沿课程搜索首屏继续浏览。
public struct CourseEvaluationLookupResult: Sendable {
    public let selectedCourse: CourseSummary
    public let searchQuery: String
    public let searchResults: [CourseSummary]
}

public struct CourseEvaluationResolver {
    private struct Candidates: Sendable {
        let firstPage: [CourseSummary]
        let all: [CourseSummary]
    }
    private struct SearchResult: Sendable {
        let query: String
        let result: Result<Candidates, any Error>
    }
    private let service: any CourseListServicing
    private let waitForDeadline: @Sendable (ContinuousClock.Instant) async throws -> Void

    public init(service: any CourseListServicing) {
        self.service = service
        waitForDeadline = { try await ContinuousClock().sleep(until: $0) }
    }

    init(service: any CourseListServicing, waitForDeadline: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void) {
        self.service = service
        self.waitForDeadline = waitForDeadline
    }

    public func resolve(
        courseName: String,
        courseNumber: String,
        teacher: String = ""
    ) async throws -> CourseEvaluationLookupResult? {
        let name = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = courseNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !number.isEmpty else { return nil }

        let deadline = ContinuousClock.now.advanced(by: .seconds(URLSessionConfiguration.default.timeoutIntervalForRequest))
        let operation: @MainActor @Sendable () async throws -> CourseEvaluationLookupResult? = {
            try await lookup(name: name, number: number, teacher: teacher, deadline: deadline)
        }
        return try await withThrowingTaskGroup(of: CourseEvaluationLookupResult?.self) { group in
            group.addTask { try await operation() }
            group.addTask { [waitForDeadline] in
                try await waitForDeadline(deadline)
                throw CourseEvaluationLookupLimit.reached
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        }
    }

    private func lookup(name: String, number: String, teacher: String, deadline: ContinuousClock.Instant) async throws -> CourseEvaluationLookupResult? {
        var queries: [String] = []
        for query in [number, name] where !query.isEmpty && !queries.contains(query) { queries.append(query) }
        let load: @MainActor @Sendable (String) async throws -> Candidates = { query in
            try await fetchCandidates(for: query, name: name, number: number, teacher: teacher, deadline: deadline)
        }
        return try await withThrowingTaskGroup(of: SearchResult.self) { group in
            for query in queries {
                group.addTask {
                    do { return SearchResult(query: query, result: .success(try await load(query))) }
                    catch { return SearchResult(query: query, result: .failure(error)) }
                }
            }
            defer { group.cancelAll() }
            var candidates: [CourseSummary] = [], firstPages: [String: [CourseSummary]] = [:]
            var failures: [any Error] = []
            for try await search in group {
                try Task.checkCancellation()
                switch search.result {
                case let .success(result):
                    firstPages[search.query] = result.firstPage
                    candidates = deduplicating(candidates + result.all)
                    if let selected = CourseLookupMatcher.exactMatch(courseNumber: number, courseName: name,
                        teacher: teacher, candidates: candidates) {
                        return lookupResult(selected, name: name, number: number, firstPages: firstPages)
                    }
                case let .failure(error):
                    if TaskCancellation.matches(error) { throw error }
                    failures.append(error)
                }
            }
            if let selected = CourseLookupMatcher.bestMatch(courseNumber: number, courseName: name,
                teacher: teacher, candidates: candidates) {
                return lookupResult(selected, name: name, number: number, firstPages: firstPages)
            }
            if let failure = failures.first { throw failure }
            return nil
        }
    }

    private func lookupResult(_ selected: CourseSummary, name: String, number: String,
        firstPages: [String: [CourseSummary]]) -> CourseEvaluationLookupResult {
        let query = firstPages[name] == nil ? number : name
        var results = firstPages[query] ?? []
        if !results.contains(where: { $0.id == selected.id }) { results.insert(selected, at: 0) }
        return CourseEvaluationLookupResult(selectedCourse: selected,
            searchQuery: query, searchResults: results)
    }

    private func fetchCandidates(for search: String, name: String, number: String, teacher: String,
        deadline: ContinuousClock.Instant) async throws -> Candidates {
        var results: [CourseSummary] = [], firstPage: [CourseSummary] = []
        var candidateBytes = 0
        var known = Set<Int>(), progress = CommunityPageProgress<Int>(), page = 0
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw CourseEvaluationLookupLimit.reached }
            let incoming = try await service.fetchCourses(search: search, page: page)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw CourseEvaluationLookupLimit.reached }
            try progress.record(incoming.map(\.id), knownIDs: known)
            if page == 0 { firstPage = deduplicating(incoming) }
            if incoming.isEmpty { return Candidates(firstPage: firstPage, all: results) }
            for course in incoming where known.insert(course.id).inserted {
                let bytes = MemoryLayout<CourseSummary>.stride + course.name.utf8.count + course.number.utf8.count
                    + course.teachersName.utf8.count + course.teachersNumber.utf8.count
                guard bytes <= HTTPResponseResourceLimits.maximumStructuredBytes - candidateBytes else { throw CourseEvaluationLookupLimit.reached }
                candidateBytes += bytes
                results.append(course)
            }
            if CourseLookupMatcher.exactMatch(courseNumber: number, courseName: name,
                teacher: teacher, candidates: results) != nil {
                return Candidates(firstPage: firstPage, all: results)
            }
            page += 1
        }
    }

    private func deduplicating(_ courses: [CourseSummary]) -> [CourseSummary] {
        var seen = Set<Int>()
        return courses.filter { seen.insert($0.id).inserted }
    }
}


private enum CourseEvaluationLookupLimit: LocalizedError {
    case reached
    var errorDescription: String? { "课程候选范围较大，请在课程搜索中输入完整课程号或课程名后选择。" }
}
