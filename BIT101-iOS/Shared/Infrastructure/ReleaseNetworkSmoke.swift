import Foundation

// MARK: - Release network smoke

#if DEBUG || RELEASE_NETWORK_SMOKE

/// 发布前网络冒烟的范围。
///
/// 这里与脚本入口保持同名同义，方便正式 App、测试宿主和命令行脚本复用同一套探针。
enum NetworkSmokeScope: String, Codable {
    case all
    case bit101
    case school
    case transcript
    case schedule

    func includes(_ name: String) -> Bool {
        switch self {
        case .all:
            return true
        case .bit101:
            return name == "BIT101 登录状态"
                || name.hasPrefix("话廊")
                || name.hasPrefix("社区")
                || name.hasPrefix("消息")
                || name.hasPrefix("用户")
                || name.hasPrefix("学业")
                || name.hasPrefix("文章")
                || name.hasPrefix("我的")
                || name.hasPrefix("App Store")
                || name.hasPrefix("紧急更新")
                || name.hasPrefix("open.aihelpme.dev")
                || name.hasPrefix("feedback.aihelpme.dev")
        case .school:
            return name == "BIT101 登录状态"
                || name.hasPrefix("切换学期")
                || name.hasPrefix("课表")
                || name.hasPrefix("空教室")
                || name.hasPrefix("乐学")
                || name.hasPrefix("成绩")
                || name.hasPrefix("可信成绩单")
        case .transcript:
            return name == "可信成绩单接口"
        case .schedule:
            return name == "BIT101 登录状态"
                || name == "当前学期"
                || name == "切换学期列表"
                || name == "课表、考试与首周同步"
        }
    }
}

/// 冒烟结果的持久化报告。
struct ReleaseNetworkSmokeReport: Codable {
    let runID: String
    let scope: NetworkSmokeScope
    let startedAt: Date
    let finishedAt: Date
    let passed: Bool
    let failures: [String]
    let authenticationBlockers: [String]

    var elapsed: TimeInterval {
        finishedAt.timeIntervalSince(startedAt)
    }

    var summaryLine: String {
        "NETWORK_SMOKE_SUMMARY run_id=\(runID) scope=\(scope.rawValue) passed=\(passed) failures=\(failures.count) auth_blocked=\(authenticationBlockers.count) elapsed=\(Self.duration(elapsed))"
    }

    var failureMessage: String {
        let failureSection = failures.isEmpty ? "" : "\n网络或业务失败：\n" + failures.joined(separator: "\n")
        let authenticationSection = authenticationBlockers.isEmpty ? "" : "\n需要人工认证，相关路径尚未完成验证：\n" + authenticationBlockers.joined(separator: "\n")
        return "发布前网络冒烟测试未完全通过：" + failureSection + authenticationSection
    }

    private static func duration(_ interval: TimeInterval) -> String {
        String(format: "%.2fs", interval)
    }
}

/// 冒烟报告的本地落盘位置。
enum ReleaseNetworkSmokeReportStore {
    private static let directoryName = "NetworkSmoke"
    private static let filePrefix = "release-network-smoke"

    static func fileURL(runID _: String) -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ScheduleSharedContainer.identifier
        ) else {
            return nil
        }

        return containerURL
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: "\(filePrefix).json")
    }

    static func write(_ report: ReleaseNetworkSmokeReport) throws {
        guard let fileURL = fileURL(runID: report.runID) else {
            throw ScheduleExternalSnapshotStoreError.sharedContainerUnavailable
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let directory = fileURL.deletingLastPathComponent()
        let oldReports = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for oldReport in oldReports
            where oldReport.lastPathComponent.hasPrefix("\(filePrefix)-")
        {
            try? FileManager.default.removeItem(at: oldReport)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// `bit101://network-smoke/...` 触发参数。
struct ReleaseNetworkSmokeLaunchRequest {
    let scope: NetworkSmokeScope
    let runID: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == "bit101",
              url.host?.lowercased() == "network-smoke"
        else { return nil }

        let pathScope = url.pathComponents
            .filter { $0 != "/" }
            .first
            .flatMap(NetworkSmokeScope.init(rawValue:))
            ?? .all

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let runID = components?.queryItems?.first(where: { $0.name == "run" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        self.scope = pathScope
        if let runID, !runID.isEmpty {
            self.runID = runID
        } else {
            self.runID = UUID().uuidString
        }
    }
}

/// 发布前网络冒烟执行器。
///
/// 这份实现同时服务于：
/// - 真机上的正式 App：通过 `bit101://network-smoke/...` 在当前进程内复用会话执行；
/// - XCTest：保留一个直接调用入口，方便回归和未来 CI 复用同一组探针。
@MainActor
final class ReleaseNetworkSmokeRunner {
    private var failures: [String] = []
    private var authenticationBlockers: [String] = []

    func run(scope: NetworkSmokeScope, runID: String = UUID().uuidString) async -> ReleaseNetworkSmokeReport {
        failures = []
        authenticationBlockers = []
        let startedAt = Date()

        let loginStartedAt = Date()
        do {
            let loginResult = try await LoginService().checkLogin()
            guard let signedInStudentID = loginResult, !signedInStudentID.isEmpty else {
                recordFailure("BIT101 登录状态", "真机没有有效登录状态，无法执行发布前网络冒烟测试", scope: scope)
                return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
            }
            print("NETWORK_SMOKE_PASS name=BIT101 登录状态 elapsed=\(Self.duration(Date().timeIntervalSince(loginStartedAt)))")
            _ = signedInStudentID
        } catch {
            recordFailure("BIT101 登录状态", error.localizedDescription, scope: scope, elapsed: Date().timeIntervalSince(loginStartedAt))
            return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
        }

        let gallery = GalleryService()
        _ = await probe("open.aihelpme.dev 首页", scope: scope) {
            try await Self.fetchWebPage("https://open.aihelpme.dev")
        }
        let posters = await probe("话廊最新列表", scope: scope) {
            try await gallery.fetchFeed(kind: .newest, page: nil)
        } ?? []
        if let poster = posters.first {
            _ = await probe("话廊帖子详情", scope: scope) {
                try await gallery.fetchPoster(id: poster.id)
            }
            _ = await probe("话廊帖子评论", scope: scope) {
                try await gallery.fetchComments(
                    objectID: "poster\(poster.id)",
                    order: .newest,
                    page: nil
                )
            }
            if let image = poster.images.first ?? Optional(poster.user.avatar) {
                _ = await probe("话廊图片下载", scope: scope) {
                    try await Self.download(urlString: image.lowUrl.isEmpty ? image.url : image.lowUrl)
                }
            }
            _ = await probe("话廊网页详情", scope: scope) {
                try await Self.fetchWebPage("https://open.aihelpme.dev/gallery/\(poster.id)")
            }
        } else {
            recordFailure("话廊最新列表", "服务器返回空列表，无法继续验证详情与图片", scope: scope)
        }
        _ = await probe("话廊推荐流", scope: scope) { try await gallery.fetchRecommendPage(sourcePage: 0) }
        _ = await probe("话廊机器人流", scope: scope) { try await gallery.fetchBotFeed(startPage: 0) }
        _ = await probe("帖子声明列表", scope: scope) { try await gallery.fetchClaims() }
        _ = await probe("话廊搜索", scope: scope) {
            try await gallery.searchPosters(query: GallerySearchQuery(text: "BIT101"), page: 0)
        }
        _ = await probe("消息未读数", scope: scope) {
            try await gallery.fetchMessageUnreadCounts()
        }
        for messageType in GalleryMessageType.allCases {
            _ = await probe("消息列表-\(messageType.rawValue)", scope: scope) {
                try await gallery.fetchMessages(type: messageType, lastID: nil)
            }
        }

        let courses = CourseService()
        let courseRows = await probe("学业课程列表", scope: scope) {
            try await courses.fetchCourses(search: "", page: 0)
        } ?? []
        if let course = courseRows.first {
            _ = await probe("学业课程详情", scope: scope) {
                try await courses.fetchCourse(id: course.id)
            }
            _ = await probe("学业课程评论", scope: scope) {
                try await courses.fetchComments(courseID: course.id, page: nil)
            }
            _ = await probe("学业课程历史成绩", scope: scope) {
                try await courses.fetchCourseHistories(number: course.number)
            }
            _ = await probe("学业课程网页详情", scope: scope) {
                try await Self.fetchWebPage("https://open.aihelpme.dev/course/\(course.id)")
            }
        } else {
            recordFailure("学业课程列表", "服务器返回空列表，无法继续验证课程详情", scope: scope)
        }

        let papers = PaperService()
        let paperRows = await probe("文章列表", scope: scope) {
            try await papers.fetchPapers(search: nil, order: .newest, page: 0)
        } ?? []
        if let paper = paperRows.first {
            _ = await probe("文章详情", scope: scope) {
                try await papers.fetchPaper(id: paper.id)
            }
            _ = await probe("文章评论", scope: scope) {
                try await papers.fetchComments(paperID: paper.id, order: .newest, page: nil)
            }
        } else {
            recordFailure("文章列表", "服务器返回空列表，无法继续验证文章详情", scope: scope)
        }
        for order in PaperSortOrder.allCases {
            _ = await probe("文章列表-\(order.title)", scope: scope) {
                try await papers.fetchPapers(search: "BIT101", order: order, page: 0)
            }
        }

        let mine = MineService()
        let myInfo = await probe("我的资料", scope: scope) { try await mine.fetchMyInfo() }
        _ = await probe("我的关注", scope: scope) { try await mine.fetchFollowings(page: 0) }
        _ = await probe("我的粉丝", scope: scope) { try await mine.fetchFollowers(page: 0) }
        _ = await probe("我的帖子", scope: scope) { try await mine.fetchMyPosters(page: 0) }
        if let myInfo {
            _ = await probe("用户资料详情", scope: scope) { try await mine.fetchUserInfo(id: myInfo.user.id) }
            _ = await probe("用户帖子", scope: scope) { try await mine.fetchUserPosters(userID: myInfo.user.id, page: 0) }
        }

        // 可信成绩单最容易受当前会话状态影响，因此放在学校链路最前面，尽量贴近
        // 用户手动点“申请可信成绩单”时的行为。
        let scoreService = ScoreService()
        _ = await probe("可信成绩单接口", scope: scope) {
            try await scoreService.fetchTrustedTranscriptPages()
        }

        let schedule = ScheduleService()
        _ = await probe("当前学期", scope: scope) { try await schedule.fetchCurrentTermOnly() }
        let terms = await probe("切换学期列表", scope: scope) {
            try await schedule.fetchAvailableTerms()
        } ?? []
        if let term = terms.first {
            _ = await probe("课表、考试与首周同步", scope: scope) {
                try await schedule.syncCourses(term: term)
            }

            let campuses = await probe("空教室校区列表", scope: scope) {
                try await schedule.fetchCampuses()
            } ?? []
            if let campus = campuses.first {
                let buildings = await probe("空教室教学楼列表", scope: scope) {
                    try await schedule.fetchBuildings(campusCode: campus.code)
                } ?? []
                if let building = buildings.first {
                    _ = await probe("空教室占用数据", scope: scope) {
                        try await schedule.fetchClassrooms(buildingID: building.id, term: term)
                    }
                } else {
                    recordFailure("空教室教学楼列表", "服务器返回空列表", scope: scope)
                }
            } else {
                recordFailure("空教室校区列表", "服务器返回空列表", scope: scope)
            }
        } else {
            recordFailure("切换学期列表", "服务器返回空列表，无法继续验证课表与空教室", scope: scope)
        }

        let calendarURL = await probe("乐学日历订阅地址", scope: scope) {
            try await schedule.refreshLexueCalendarURL()
        }
        if let calendarURL {
            _ = await probe("乐学 DDL 下载", scope: scope) {
                try await schedule.syncDDLEvents(existingEvents: [], storedURL: calendarURL)
            }
        }

        // 成绩页与可信成绩单同样属于学校网络链路；短信二次验证时记录为
        // AUTH_BLOCKED，而不是误判为网络故障。
        let scoreChallenge = await probe("成绩认证接口", scope: scope) {
            try await scoreService.startScoreChallenge()
        }
        if let scoreChallenge {
            _ = await probe("成绩简略列表", scope: scope) {
                try await scoreService.fetchScores(detail: false, authenticatedBy: scoreChallenge)
            }
            _ = await probe("成绩详细列表", scope: scope) {
                try await scoreService.fetchScores(detail: true, authenticatedBy: scoreChallenge)
            }
        }

        _ = await probe("App Store 更新接口", scope: scope) {
            try await Self.fetchWebPage("https://itunes.apple.com/lookup?id=6761147125&country=cn")
        }
        _ = await probe("紧急更新配置接口", scope: scope) {
            try await Self.fetchWebPage(
                "https://update.aihelpme.dev/emergency-update.json"
            )
        }
        _ = await probe("feedback.aihelpme.dev 写入恢复", scope: scope) {
            try await FeedbackSubmissionClient.submitNetworkSmoke(runID: runID)
        }

        return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
    }

    private func finishReport(runID: String, scope: NetworkSmokeScope, startedAt: Date) async -> ReleaseNetworkSmokeReport {
        let report = ReleaseNetworkSmokeReport(
            runID: runID,
            scope: scope,
            startedAt: startedAt,
            finishedAt: Date(),
            passed: failures.isEmpty && authenticationBlockers.isEmpty,
            failures: failures,
            authenticationBlockers: authenticationBlockers
        )
        print(report.summaryLine)
        if !report.passed {
            print(report.failureMessage)
        }
        try? ReleaseNetworkSmokeReportStore.write(report)
        return report
    }

    private func probe<Value>(
        _ name: String,
        scope: NetworkSmokeScope,
        operation: () async throws -> Value
    ) async -> Value? {
        guard scope.includes(name) else {
            print("NETWORK_SMOKE_SKIP name=\(name) scope=\(scope.rawValue)")
            return nil
        }
        let startedAt = Date()
        do {
            let value = try await operation()
            print("NETWORK_SMOKE_PASS name=\(name) elapsed=\(Self.duration(Date().timeIntervalSince(startedAt)))")
            return value
        } catch {
            let elapsed = Date().timeIntervalSince(startedAt)
            if Self.isAuthenticationBlocked(error) {
                recordAuthenticationBlocker(name, error.localizedDescription, scope: scope, elapsed: elapsed)
            } else {
                recordFailure(name, error.localizedDescription, scope: scope, elapsed: elapsed)
            }
            return nil
        }
    }

    private func recordFailure(_ name: String, _ message: String, scope: NetworkSmokeScope, elapsed: TimeInterval? = nil) {
        guard scope.includes(name) else { return }
        let timing = elapsed.map { " elapsed=\(Self.duration($0))" } ?? ""
        let line = "[\(name)] \(message)\(timing)"
        failures.append(line)
        print("NETWORK_SMOKE_FAIL \(line)")
    }

    private func recordAuthenticationBlocker(
        _ name: String,
        _ message: String,
        scope: NetworkSmokeScope,
        elapsed: TimeInterval
    ) {
        guard scope.includes(name) else { return }
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
