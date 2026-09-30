import CourseFeature
import MapFeature
import ScheduleFeature
import ScheduleDomain
import ScheduleContracts
import Foundation
import TransportCore
import SwiftUI

/// 日程课程操作所需的结果：当前教师对应的社区课程。
struct ScheduleAcademicCourseResolution {
    let selectedCourse: CourseSummary
    let searchQuery: String
    let searchResults: [CourseSummary]
}

extension ScheduleDestinations {
    static func appDestinations(
        courses: CourseDependencies,
        onOpenAcademicCourse: @escaping (CourseNavigationRequest) -> Void,
        onOpenCourseLocation: @escaping (CampusMapLocationRequest) -> Void
    ) -> ScheduleDestinations {
        let resolver = ScheduleAcademicCourseResolver(resolver: courses.makeEvaluationResolver())
        return ScheduleDestinations(
            appStoreURL: BIT101AppStore.url,
            academicCourse: { course, onDismiss in
                AnyView(CourseEvaluationLink(dependencies: courses, request: .lookup(
                    courseName: course.name, courseNumber: course.number, teacher: course.teacher
                )) { request in
                    onDismiss()
                    onOpenAcademicCourse(request)
                })
            },
            openCourseLocation: { courses in
                var seen = Set<String>()
                let places = courses.compactMap { course -> CampusMapPlace? in
                    guard let place = CampusMapPlaceCatalog.place(campusName: course.campus, classroom: course.classroom),
                          seen.insert(place.id).inserted else { return nil }
                    return place
                }
                guard let first = courses.first, !places.isEmpty else { return false }
                onOpenCourseLocation(CampusMapLocationRequest(
                    courseName: ScheduleDisplayNormalizer.normalizeCourseTitle(first.name), places: places
                ))
                return true
            },
            resolveCourseShare: { course in
                guard let resolution = try await resolver.resolve(course) else { return nil }
                return ScheduleCourseShare(
                    url: AppURL.required("https://open.aihelpme.dev/course/\(resolution.selectedCourse.id)"),
                    subject: resolution.selectedCourse.name
                )
            }
        )
    }
}

/// 把教务课表课程匹配到 BIT101“学业－课程”中的社区课程。
///
/// 课程号搜索和课程名搜索并行执行，匹配规则集中在 `CourseEvaluationResolver`，
/// 课程分享和课程评价入口都复用同一规则。
@MainActor
struct ScheduleAcademicCourseResolver {
    private let resolver: CourseEvaluationResolver

    init(service: any CourseListServicing) {
        self.resolver = CourseEvaluationResolver(service: service)
    }

    init(resolver: CourseEvaluationResolver) {
        self.resolver = resolver
    }

    func resolve(_ course: CourseRecord) async throws -> ScheduleAcademicCourseResolution? {
        let number = course.number.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = course.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        guard let lookup = try await resolver.resolve(
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
