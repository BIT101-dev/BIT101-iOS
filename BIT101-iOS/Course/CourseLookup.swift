import Foundation

/// 课程评价入口共用的课程匹配规则。
///
/// 日程课程和成绩记录都只有课程号/课程名等外部标识，最终必须通过同一套
/// 去格式化、教师消歧和唯一性判断，才能进入同一个课程详情与评价页面。
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

        if !normalizedTeacher(expectedTeacher).isEmpty {
            if let match = sameNumber.first(where: {
                teacherMatches(expectedTeacher, candidate: $0.teachersName)
            }) {
                return match
            }
            if let match = sameName.first(where: {
                teacherMatches(expectedTeacher, candidate: $0.teachersName)
            }) {
                return match
            }

            // 后端个别旧课程没有教师字段；只在课程号唯一且候选教师也为空时安全回退。
            if sameNumber.count == 1,
               normalizedTeacher(sameNumber[0].teachersName).isEmpty
            {
                return sameNumber[0]
            }
            return nil
        }

        if sameNumber.count == 1 { return sameNumber[0] }
        if sameName.count == 1 { return sameName[0] }

        // 成绩接口通常没有教师字段：当同一课程号和课程名只是因教师记录被拆成多行时，
        // 它们仍然代表同一门可评价课程，可以稳定取第一条；不同课程号的同名课仍保持歧义失败。
        let sameIdentity = sameNumber.filter { numberCourse in
            sameName.contains(where: { $0.id == numberCourse.id })
        }
        if sameIdentity.count > 1,
           Set(sameIdentity.map { normalizedIdentifier($0.number) }).count == 1,
           Set(sameIdentity.map { normalizedText($0.name) }).count == 1
        {
            return sameIdentity[0]
        }
        return nil
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

    private static func teacherMatches(_ expected: String, candidate: String) -> Bool {
        let expectedNames = teacherNames(expected)
        let candidateNames = teacherNames(candidate)
        guard !expectedNames.isEmpty, !candidateNames.isEmpty else { return false }
        return !expectedNames.isDisjoint(with: candidateNames)
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
/// 日程与成绩详情各自只搜一个字段而把同一门课程误判为“找不到”。
struct CourseEvaluationLookupResult {
    let selectedCourse: CourseSummary
    let searchQuery: String
    let searchResults: [CourseSummary]
}

struct CourseEvaluationResolver {
    private let service: any CourseListServicing

    init(service: any CourseListServicing = CourseService()) {
        self.service = service
    }

    func resolve(
        courseName: String,
        courseNumber: String,
        teacher: String = ""
    ) async throws -> CourseEvaluationLookupResult? {
        let name = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = courseNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !number.isEmpty else { return nil }

        async let numberCandidates = fetchCandidates(for: number)
        async let nameCandidates = fetchCandidates(for: name)
        let (numberResults, nameResults) = try await (numberCandidates, nameCandidates)
        let candidates = deduplicating(numberResults + nameResults)
        guard let selectedCourse = CourseLookupMatcher.bestMatch(
            courseNumber: number,
            courseName: name,
            teacher: teacher,
            candidates: candidates
        ) else {
            return nil
        }

        var searchResults = deduplicating(nameResults)
        if !searchResults.contains(where: { $0.id == selectedCourse.id }) {
            searchResults.insert(selectedCourse, at: 0)
        }
        return CourseEvaluationLookupResult(
            selectedCourse: selectedCourse,
            searchQuery: name.isEmpty ? number : name,
            searchResults: searchResults
        )
    }

    private func fetchCandidates(for search: String) async throws -> [CourseSummary] {
        guard !search.isEmpty else { return [] }
        return try await service.fetchCourses(search: search, page: 0)
    }

    private func deduplicating(_ courses: [CourseSummary]) -> [CourseSummary] {
        var seen = Set<Int>()
        return courses.filter { seen.insert($0.id).inserted }
    }
}
