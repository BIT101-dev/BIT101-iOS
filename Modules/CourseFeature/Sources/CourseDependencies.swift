import CommunityCore
import CommunityTransport
import Observation

/// 课程页面消费列表、详情、课程偏好与学分查询。
@MainActor
@Observable
public final class CourseDependencies {
    let list: any CourseListServicing
    let detail: any CourseDetailServicing
    let preferences: CommunityPreferences
    let loadCourseCredits: @MainActor () async -> [CommunityCourseCredit]

    public func makeListViewModel() -> CourseListViewModel {
        CourseListViewModel(service: list)
    }

    public func makeEvaluationResolver() -> CourseEvaluationResolver {
        CourseEvaluationResolver(service: list)
    }

    public init(
        list: any CourseListServicing,
        detail: any CourseDetailServicing,
        preferences: CommunityPreferences,
        loadCourseCredits: @escaping @MainActor () async -> [CommunityCourseCredit]
    ) {
        self.list = list
        self.detail = detail
        self.preferences = preferences
        self.loadCourseCredits = loadCourseCredits
    }
}

