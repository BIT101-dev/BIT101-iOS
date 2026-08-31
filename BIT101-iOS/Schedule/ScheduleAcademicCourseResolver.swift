//
//  ScheduleAcademicCourseResolver.swift
//  BIT101-iOS
//

import Foundation

/// 把教务课表课程匹配到 BIT101“学业－课程”中的社区课程。
///
/// 优先使用课程号做确定性匹配；课程号缺失或后端没有对应记录时，再按课程名查找，
/// 并用教师信息消除同名课程歧义。无法得到唯一结果时宁可返回 nil，也不跳错课程。
@MainActor
struct ScheduleAcademicCourseResolver {
    private let service: any CourseListServicing

    init(service: any CourseListServicing) {
        self.service = service
    }

    init() {
        service = CourseService()
    }

    func resolve(_ course: CourseRecord) async throws -> CourseSummary? {
        let number = course.number.trimmingCharacters(in: .whitespacesAndNewlines)
        if !number.isEmpty {
            let candidates = try await service.fetchCourses(search: number, page: 0)
            if let match = ScheduleAcademicCourseMatcher.numberMatch(
                courseNumber: number,
                candidates: candidates
            ) {
                return match
            }
        }

        let name = course.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let candidates = try await service.fetchCourses(search: name, page: 0)
        return ScheduleAcademicCourseMatcher.nameMatch(
            courseName: name,
            teacher: course.teacher,
            candidates: candidates
        )
    }
}

nonisolated enum ScheduleAcademicCourseMatcher {
    static func numberMatch(
        courseNumber: String,
        candidates: [CourseSummary]
    ) -> CourseSummary? {
        let expected = normalizedIdentifier(courseNumber)
        guard !expected.isEmpty else { return nil }
        return candidates.first { normalizedIdentifier($0.number) == expected }
    }

    static func nameMatch(
        courseName: String,
        teacher: String,
        candidates: [CourseSummary]
    ) -> CourseSummary? {
        let expectedName = normalizedText(courseName)
        guard !expectedName.isEmpty else { return nil }
        let sameName = candidates.filter { normalizedText($0.name) == expectedName }
        guard sameName.count > 1 else { return sameName.first }

        let expectedTeacher = normalizedText(teacher)
        guard !expectedTeacher.isEmpty else { return nil }
        let sameTeacher = sameName.filter {
            let candidateTeacher = normalizedText($0.teachersName)
            guard !candidateTeacher.isEmpty else { return false }
            return candidateTeacher.contains(expectedTeacher)
                || expectedTeacher.contains(candidateTeacher)
        }
        return sameTeacher.count == 1 ? sameTeacher[0] : nil
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
