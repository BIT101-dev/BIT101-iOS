//
//  ScheduleAcademicCourseResolver.swift
//  BIT101-iOS
//

import Foundation

/// 日程课程跳转所需的完整结果：当前教师对应的课程，以及已预取的同名课程列表。
struct ScheduleAcademicCourseResolution {
    let selectedCourse: CourseSummary
    let searchQuery: String
    let searchResults: [CourseSummary]

    var navigationRequest: CourseNavigationRequest {
        CourseNavigationRequest(
            courseID: selectedCourse.id,
            preparedCourse: selectedCourse,
            searchQuery: searchQuery,
            searchResults: searchResults
        )
    }
}

/// 把教务课表课程匹配到 BIT101“学业－课程”中的社区课程。
///
/// 课程号搜索和课程名搜索并行执行：前者用于精确确认课程，后者作为返回详情后的
/// 普通列表首屏。两组候选都结合任课教师匹配，无法确认教师时宁可返回 nil。
@MainActor
struct ScheduleAcademicCourseResolver {
    private let service: any CourseListServicing

    init(service: any CourseListServicing) {
        self.service = service
    }

    init() {
        service = CourseService()
    }

    func resolve(_ course: CourseRecord) async throws -> ScheduleAcademicCourseResolution? {
        let number = course.number.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = course.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        async let numberCandidatesTask = fetchNumberCandidates(number)
        async let nameCandidatesTask = service.fetchCourses(search: name, page: 0)
        let (numberCandidates, nameCandidates) = try await (
            numberCandidatesTask,
            nameCandidatesTask
        )

        let allCandidates = deduplicating(numberCandidates + nameCandidates)
        guard let selected = ScheduleAcademicCourseMatcher.bestMatch(
            courseNumber: number,
            courseName: name,
            teacher: course.teacher,
            candidates: allCandidates
        ) else { return nil }

        var preparedResults = deduplicating(nameCandidates)
        if !preparedResults.contains(where: { $0.id == selected.id }) {
            preparedResults.insert(selected, at: 0)
        }
        return ScheduleAcademicCourseResolution(
            selectedCourse: selected,
            searchQuery: name,
            searchResults: preparedResults
        )
    }

    private func fetchNumberCandidates(_ number: String) async throws -> [CourseSummary] {
        guard !number.isEmpty else { return [] }
        return try await service.fetchCourses(search: number, page: 0)
    }

    private func deduplicating(_ courses: [CourseSummary]) -> [CourseSummary] {
        var seen = Set<Int>()
        return courses.filter { seen.insert($0.id).inserted }
    }
}

nonisolated enum ScheduleAcademicCourseMatcher {
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
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .lowercased()
    }
}
