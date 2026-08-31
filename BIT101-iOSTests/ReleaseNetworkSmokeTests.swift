#if RELEASE_NETWORK_SMOKE
import Foundation
import XCTest
@testable import BIT101_iOS

/// 发布前真机网络冒烟测试。
///
/// 测试不识别 Wi-Fi、蜂窝网络或校园网，也不根据网络环境改变流程；在任何网络下都
/// 顺序执行同一组真实用户只读操作，让 App 自己选择 WebVPN 或校园网直连链路。
@MainActor
final class ReleaseNetworkSmokeTests: XCTestCase {
    private var failures: [String] = []
    private var authenticationBlockers: [String] = []

    func testReadOnlyUserNetworkFlows() async throws {
        failures = []
        authenticationBlockers = []
        let startedAt = Date()

        let studentID = await probe("BIT101 登录状态") {
            try await LoginService().checkLogin()
        }
        guard let loginResult = studentID,
              let signedInStudentID = loginResult,
              !signedInStudentID.isEmpty
        else {
            XCTFail("真机没有有效登录状态，无法执行发布前网络冒烟测试")
            return
        }

        let gallery = GalleryService()
        let posters = await probe("话廊最新列表") {
            try await gallery.fetchFeed(kind: .newest, page: nil)
        } ?? []
        if let poster = posters.first {
            _ = await probe("话廊帖子详情") {
                try await gallery.fetchPoster(id: poster.id)
            }
            _ = await probe("话廊帖子评论") {
                try await gallery.fetchComments(
                    objectID: "poster\(poster.id)",
                    order: .newest,
                    page: nil
                )
            }
            if let image = poster.images.first ?? Optional(poster.user.avatar) {
                _ = await probe("话廊图片下载") {
                    try await Self.download(urlString: image.lowUrl.isEmpty ? image.url : image.lowUrl)
                }
            }
            _ = await probe("话廊网页详情") {
                try await Self.fetchWebPage("https://open.aihelpme.dev/gallery/\(poster.id)")
            }
        } else {
            recordFailure("话廊最新列表", "服务器返回空列表，无法继续验证详情与图片")
        }
        _ = await probe("消息未读数") {
            try await gallery.fetchMessageUnreadCounts()
        }

        let courses = CourseService()
        let courseRows = await probe("学业课程列表") {
            try await courses.fetchCourses(search: "", page: 0)
        } ?? []
        if let course = courseRows.first {
            _ = await probe("学业课程详情") {
                try await courses.fetchCourse(id: course.id)
            }
            _ = await probe("学业课程评论") {
                try await courses.fetchComments(courseID: course.id, page: nil)
            }
            _ = await probe("学业课程历史成绩") {
                try await courses.fetchCourseHistories(number: course.number)
            }
            _ = await probe("学业课程网页详情") {
                try await Self.fetchWebPage("https://open.aihelpme.dev/course/\(course.id)")
            }
        } else {
            recordFailure("学业课程列表", "服务器返回空列表，无法继续验证课程详情")
        }

        let papers = PaperService()
        let paperRows = await probe("文章列表") {
            try await papers.fetchPapers(search: nil, order: .newest, page: 0)
        } ?? []
        if let paper = paperRows.first {
            _ = await probe("文章详情") {
                try await papers.fetchPaper(id: paper.id)
            }
            _ = await probe("文章评论") {
                try await papers.fetchComments(paperID: paper.id, order: .newest, page: nil)
            }
        } else {
            recordFailure("文章列表", "服务器返回空列表，无法继续验证文章详情")
        }

        let mine = MineService()
        _ = await probe("我的资料") { try await mine.fetchMyInfo() }
        _ = await probe("我的关注") { try await mine.fetchFollowings(page: 0) }
        _ = await probe("我的粉丝") { try await mine.fetchFollowers(page: 0) }
        _ = await probe("我的帖子") { try await mine.fetchMyPosters(page: 0) }

        let schedule = ScheduleService()
        let terms = await probe("切换学期列表") {
            try await schedule.fetchAvailableTerms()
        } ?? []
        if let term = terms.first {
            _ = await probe("课表、考试与首周同步") {
                try await schedule.syncCourses(term: term)
            }

            let campuses = await probe("空教室校区列表") {
                try await schedule.fetchCampuses()
            } ?? []
            if let campus = campuses.first {
                let buildings = await probe("空教室教学楼列表") {
                    try await schedule.fetchBuildings(campusCode: campus.code)
                } ?? []
                if let building = buildings.first {
                    _ = await probe("空教室占用数据") {
                        try await schedule.fetchClassrooms(buildingID: building.id, term: term)
                    }
                } else {
                    recordFailure("空教室教学楼列表", "服务器返回空列表")
                }
            } else {
                recordFailure("空教室校区列表", "服务器返回空列表")
            }
        } else {
            recordFailure("切换学期列表", "服务器返回空列表，无法继续验证课表与空教室")
        }

        let calendarURL = await probe("乐学日历订阅地址") {
            try await schedule.refreshLexueCalendarURL()
        }
        if let calendarURL {
            _ = await probe("乐学 DDL 下载") {
                try await schedule.syncDDLEvents(existingEvents: [], storedURL: calendarURL)
            }
        }

        _ = await probe("App Store 更新接口") {
            try await Self.fetchWebPage("https://itunes.apple.com/lookup?id=6761147125&country=cn")
        }
        _ = await probe("紧急更新配置接口") {
            try await Self.fetchWebPage(
                "https://update.aihelpme.dev/emergency-update.json"
            )
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        let passed = failures.isEmpty && authenticationBlockers.isEmpty
        print(
            "NETWORK_SMOKE_SUMMARY passed=\(passed) failures=\(failures.count) "
                + "auth_blocked=\(authenticationBlockers.count) elapsed=\(Self.duration(elapsed))"
        )
        let failureSection = failures.isEmpty
            ? ""
            : "\n网络或业务失败：\n" + failures.joined(separator: "\n")
        let authenticationSection = authenticationBlockers.isEmpty
            ? ""
            : "\n需要人工认证，相关路径尚未完成验证：\n" + authenticationBlockers.joined(separator: "\n")
        XCTAssertTrue(
            passed,
            "发布前网络冒烟测试未完全通过：" + failureSection + authenticationSection
        )
    }

    private func probe<Value>(
        _ name: String,
        operation: () async throws -> Value
    ) async -> Value? {
        let startedAt = Date()
        do {
            let value = try await operation()
            print("NETWORK_SMOKE_PASS name=\(name) elapsed=\(Self.duration(Date().timeIntervalSince(startedAt)))")
            return value
        } catch {
            let elapsed = Date().timeIntervalSince(startedAt)
            if Self.isAuthenticationBlocked(error) {
                recordAuthenticationBlocker(name, error.localizedDescription, elapsed: elapsed)
            } else {
                recordFailure(name, error.localizedDescription, elapsed: elapsed)
            }
            return nil
        }
    }

    private func recordFailure(_ name: String, _ message: String, elapsed: TimeInterval? = nil) {
        let timing = elapsed.map { " elapsed=\(Self.duration($0))" } ?? ""
        let line = "[\(name)] \(message)\(timing)"
        failures.append(line)
        print("NETWORK_SMOKE_FAIL \(line)")
    }

    private func recordAuthenticationBlocker(
        _ name: String,
        _ message: String,
        elapsed: TimeInterval
    ) {
        let line = "[\(name)] \(message) elapsed=\(Self.duration(elapsed))"
        authenticationBlockers.append(line)
        print("NETWORK_SMOKE_AUTH_BLOCKED \(line)")
    }

    private nonisolated static func isAuthenticationBlocked(_ error: Error) -> Bool {
        switch error {
        case ScheduleServiceError.secondFactorRequired,
             ScheduleServiceError.schoolSecondFactorRequired,
             ScoreServiceError.secondFactorRequired:
            return true
        default:
            return false
        }
    }

    private nonisolated static func download(urlString: String) async throws -> Int {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        return try await fetch(url).count
    }

    private nonisolated static func fetchWebPage(_ urlString: String) async throws -> Int {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        return try await fetch(url).count
    }

    private nonisolated static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("BIT101-iOS release network smoke", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 400).contains(httpResponse.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }
        return data
    }

    private nonisolated static func duration(_ interval: TimeInterval) -> String {
        String(format: "%.2fs", interval)
    }
}
#endif
