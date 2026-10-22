import CommunityCore
import Foundation

/// 日程、成绩和外部深链统一使用的课程解析流程。
///
/// 所有入口先通过同一个解析器确认课程，再进入同一个 `CourseDetailView`。
struct CourseEvaluationRouteResolver {
    private let listService: any CourseListServicing
    private let detailService: any CourseDetailServicing

    init(
        listService: any CourseListServicing,
        detailService: any CourseDetailServicing
    ) {
        self.listService = listService
        self.detailService = detailService
    }

    func resolve(_ request: CourseNavigationRequest) async throws -> CourseNavigationRequest {
        if request.preparedCourse != nil {
            return request
        }

        if request.hasLookupIdentity {
            let name = request.lookupCourseName ?? ""
            let number = request.lookupCourseNumber ?? ""
            let teacher = request.lookupTeacher ?? ""
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw CourseEvaluationError.missingIdentity
            }
            guard let lookup = try await CourseEvaluationResolver(service: listService).resolve(
                courseName: name,
                courseNumber: number,
                teacher: teacher
            ) else {
                throw CourseEvaluationError.notFound
            }
            return CourseNavigationRequest(
                courseID: lookup.selectedCourse.id,
                lookupCourseName: name,
                lookupCourseNumber: number,
                lookupTeacher: teacher,
                preparedCourse: lookup.selectedCourse,
                searchQuery: lookup.searchQuery,
                searchResults: lookup.searchResults
            )
        }

        guard request.courseID > 0 else {
            throw CourseEvaluationError.missingIdentity
        }
        let detail = try await detailService.fetchCourse(id: request.courseID)
        return CourseNavigationRequest(
            courseID: request.courseID,
            preparedCourse: CourseSummary(detail: detail),
            preparedDetail: detail
        )
    }
}

nonisolated enum CourseEvaluationError: LocalizedError {
    case missingIdentity
    case notFound

    var errorDescription: String? {
        switch self {
        case .missingIdentity:
            return "课程记录需要课程号或课程名。"
        case .notFound:
            return "课程检索结果为空，请调整课程信息后重试。"
        }
    }
}
