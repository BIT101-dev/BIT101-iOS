#if os(iOS)
import Foundation
import ScheduleDomain
import SwiftUI

/// 日程所需的课程分享值，由应用适配器解析。
public struct ScheduleCourseShare: Equatable {
    public let url: URL
    public let subject: String

    public init(url: URL, subject: String) {
        self.url = url
        self.subject = subject
    }
}

/// 应用壳层注入跨业务页面、地图路由和课程分享。
@MainActor
public struct ScheduleDestinations {
    let appStoreURL: URL
    let academicCourse: (CourseRecord, @escaping () -> Void) -> AnyView
    let openCourseLocation: ([CourseRecord]) -> Bool
    let resolveCourseShare: (CourseRecord) async throws -> ScheduleCourseShare?

    public init(
        appStoreURL: URL,
        academicCourse: @escaping (CourseRecord, @escaping () -> Void) -> AnyView,
        openCourseLocation: @escaping ([CourseRecord]) -> Bool,
        resolveCourseShare: @escaping (CourseRecord) async throws -> ScheduleCourseShare?
    ) {
        self.appStoreURL = appStoreURL
        self.academicCourse = academicCourse
        self.openCourseLocation = openCourseLocation
        self.resolveCourseShare = resolveCourseShare
    }
}
#endif
