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
/// 普通列表首屏。匹配规则集中在 `CourseLookupMatcher`，成绩详情也复用同一规则。
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
        guard let selected = CourseLookupMatcher.bestMatch(
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
