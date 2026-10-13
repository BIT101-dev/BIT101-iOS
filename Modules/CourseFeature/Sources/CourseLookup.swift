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

    static func numberMatch(
        courseNumber: String,
        teacher: String = "",
        candidates: [CourseSummary]
    ) -> CourseSummary? {
        bestMatch(
            courseNumber: courseNumber,
            courseName: "",
            teacher: teacher,
            candidates: candidates
        )
    }

    static func nameMatch(
        courseName: String,
        teacher: String,
        candidates: [CourseSummary]
    ) -> CourseSummary? {
        bestMatch(
            courseNumber: "",
            courseName: courseName,
            teacher: teacher,
            candidates: candidates
        )
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
/// 课程号和课程名都要检索：教务成绩里的课程号可能是学校侧别名，课程名也可能存在
/// 全角标点、空格或括号差异。两路结果统一去重后再交给 `CourseLookupMatcher`，避免
/// 日程与成绩详情分别依赖各自字段；两路结果统一检索与消歧，避免同一课程被判定为“找不到”。
public struct CourseEvaluationLookupResult: Sendable {
    public let selectedCourse: CourseSummary
    public let searchQuery: String
    public let searchResults: [CourseSummary]
}

public struct CourseEvaluationResolver {
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
        async let numberCandidates = fetchCandidates(for: number, deadline: deadline)
        async let nameCandidates = fetchCandidates(for: name, deadline: deadline)
        let (numberResults, nameResults) = try await (numberCandidates, nameCandidates)
        let candidates = deduplicating(numberResults.all + nameResults.all)
        guard let selectedCourse = CourseLookupMatcher.bestMatch(
            courseNumber: number,
            courseName: name,
            teacher: teacher,
            candidates: candidates
        ) else {
            return nil
        }

        var searchResults = name.isEmpty ? numberResults.firstPage : nameResults.firstPage
        if !searchResults.contains(where: { $0.id == selectedCourse.id }) {
            searchResults.insert(selectedCourse, at: 0)
        }
        return CourseEvaluationLookupResult(
            selectedCourse: selectedCourse,
            searchQuery: name.isEmpty ? number : name,
            searchResults: searchResults
        )
    }

    private func fetchCandidates(for search: String, deadline: ContinuousClock.Instant) async throws -> (firstPage: [CourseSummary], all: [CourseSummary]) {
        guard !search.isEmpty else { return ([], []) }
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
            if incoming.isEmpty { return (firstPage, results) }
            for course in incoming where known.insert(course.id).inserted {
                let bytes = MemoryLayout<CourseSummary>.stride + course.name.utf8.count + course.number.utf8.count
                    + course.teachersName.utf8.count + course.teachersNumber.utf8.count
                guard bytes <= HTTPResponseResourceLimits.maximumStructuredBytes - candidateBytes else { throw CourseEvaluationLookupLimit.reached }
                candidateBytes += bytes
                results.append(course)
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
