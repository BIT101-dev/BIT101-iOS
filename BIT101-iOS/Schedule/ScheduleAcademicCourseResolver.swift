import Foundation

/// 日程课程操作所需的结果：当前教师对应的社区课程。
struct ScheduleAcademicCourseResolution {
    let selectedCourse: CourseSummary
    let searchQuery: String
    let searchResults: [CourseSummary]
}

/// 把教务课表课程匹配到 BIT101“学业－课程”中的社区课程。
///
/// 课程号搜索和课程名搜索并行执行，匹配规则集中在 `CourseEvaluationResolver`，
/// 课程分享和课程评价入口都复用同一规则。
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

        guard let lookup = try await CourseEvaluationResolver(service: service).resolve(
            courseName: name,
            courseNumber: number,
            teacher: course.teacher
        ) else { return nil }

        return ScheduleAcademicCourseResolution(
            selectedCourse: lookup.selectedCourse,
            searchQuery: lookup.searchQuery,
            searchResults: lookup.searchResults
        )
    }
}
