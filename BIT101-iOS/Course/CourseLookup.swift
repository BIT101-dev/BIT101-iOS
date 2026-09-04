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
