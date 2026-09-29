import CommunityCore
protocol CourseListServicing {
    func fetchCourses(search: String, page: Int) async throws -> [CourseSummary]
}

protocol CourseDetailServicing {
    func fetchCourse(id: Int) async throws -> CourseDetail
    func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade]
    func fetchComments(courseID: Int, page: Int?) async throws -> [CommunityComment]
    func like(objectID: String) async throws -> CommunityLikeResult
    func createComment(
        objectID: String,
        text: String,
        replyObjectID: String?,
        replyUID: Int?,
        anonymous: Bool,
        rate: Int?
    ) async throws -> CommunityComment
}

extension CourseService: CourseListServicing, CourseDetailServicing {}
