import Foundation

// MARK: - Release network smoke

#if DEBUG || RELEASE_NETWORK_SMOKE

/// NetworkSmokeScope 表示发布前网络冒烟执行的范围。
///
/// NetworkSmokeScope 使用与脚本入口一致的名称和语义；正式 App、测试宿主和命令行脚本复用同一组探针。
enum NetworkSmokeScope: String, Codable {
    case all
    case bit101
    case school
    case transcript
    case schedule

    func includes(_ name: String) -> Bool {
        if name == "课程历史缓存验证" {
            return true
        }

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
            return name == "BIT101 登录状态"
                || name == "可信成绩单接口"
        case .schedule:
            return name == "BIT101 登录状态"
                || name == "当前学期"
                || name == "切换学期列表"
                || name == "课表、考试与首周同步"
        }
    }
}

enum NetworkSmokeCapture: String, Codable {
    case none
    case courseHistory
    case cachedCourseHistory
}

struct CourseHistoryAuditSample: Codable, Equatable {
    let courseID: Int
    let courseName: String
    let courseNumber: String
    let teachersName: String
    let grades: [CourseHistoryGrade]
}

struct CourseHistoryAuditMetrics: Codable, Equatable {
    let courseCount: Int
    let gradeCount: Int
    let labeledGradeCount: Int
    let uncertainGradeCount: Int
    let predictedCandidateCount: Int
    let truePositive: Int
    let falsePositive: Int
    let falseNegative: Int
    let trueNegative: Int

    var precision: Double {
        let denominator = truePositive + falsePositive
        return denominator == 0 ? 0 : Double(truePositive) / Double(denominator)
    }

    var recall: Double {
        let denominator = truePositive + falseNegative
        return denominator == 0 ? 0 : Double(truePositive) / Double(denominator)
    }
}

/// ReleaseNetworkSmokeReport 保存一次网络冒烟执行的结果。
struct ReleaseNetworkSmokeReport: Codable {
    let runID: String
    let scope: NetworkSmokeScope
    let startedAt: Date
    let finishedAt: Date
    let passed: Bool
    let failures: [String]
    let authenticationBlockers: [String]
    let courseHistorySamples: [CourseHistoryAuditSample]
    let courseHistoryAuditMetrics: CourseHistoryAuditMetrics?

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

/// ReleaseNetworkSmokeReportStore 保存网络冒烟报告。
enum ReleaseNetworkSmokeReportStore {
    private static let directoryName = "NetworkSmoke"
    static let cachedFixtureFileName = "course-history-audit-fixture.json"

    static var fileURL: URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ScheduleSharedContainer.identifier
        ) else {
            return nil
        }

        return containerURL
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: "release-network-smoke.json")
    }

    static func write(_ report: ReleaseNetworkSmokeReport) throws {
        guard let fileURL else {
            throw ScheduleExternalSnapshotStoreError.sharedContainerUnavailable
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: fileURL, options: [.atomic])
    }

    static func readCachedCourseHistoryFixture() throws -> CourseHistoryAuditFixture {
        let fileURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: cachedFixtureFileName)
        return try JSONDecoder().decode(CourseHistoryAuditFixture.self, from: Data(contentsOf: fileURL))
    }
}

/// ReleaseNetworkSmokeLaunchRequest 解析 `bit101://network-smoke/...` 触发参数。
struct ReleaseNetworkSmokeLaunchRequest {
    let scope: NetworkSmokeScope
    let runID: String
    let capture: NetworkSmokeCapture

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
        let capture = components?.queryItems?.first(where: { $0.name == "capture" })?.value
            .flatMap(NetworkSmokeCapture.init(rawValue:)) ?? .none

        self.scope = pathScope
        self.capture = capture
        if let runID, !runID.isEmpty {
            self.runID = runID
        } else {
            self.runID = UUID().uuidString
        }
    }
}

/// ReleaseNetworkSmokeRunner 在当前进程执行发布前网络探针。
///
/// 这份实现同时服务于：
/// - 真机上的正式 App：通过 `bit101://network-smoke/...` 在当前进程内复用会话执行；
/// - XCTest：保留一个直接调用入口，方便回归和未来 CI 复用同一组探针。
@MainActor
final class ReleaseNetworkSmokeRunner {
    private var failures: [String] = []
    private var authenticationBlockers: [String] = []
    private var courseHistorySamples: [CourseHistoryAuditSample] = []
    private var courseHistoryAuditMetrics: CourseHistoryAuditMetrics?

    func run(
        scope: NetworkSmokeScope,
        runID: String = UUID().uuidString,
        capture: NetworkSmokeCapture = .none
    ) async -> ReleaseNetworkSmokeReport {
        failures = []
        authenticationBlockers = []
        courseHistorySamples = []
        courseHistoryAuditMetrics = nil
        let startedAt = Date()

        let loginStartedAt = Date()
        do {
            let loginResult = try await LoginService().checkLogin()
            guard let signedInStudentID = loginResult, !signedInStudentID.isEmpty else {
                recordFailure("BIT101 登录状态", "真机没有有效登录状态，无法执行发布前网络冒烟测试", scope: scope)
                return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
            }
            print("NETWORK_SMOKE_PASS name=BIT101 登录状态 elapsed=\(Self.duration(Date().timeIntervalSince(loginStartedAt)))")
        } catch {
            recordFailure("BIT101 登录状态", error.localizedDescription, scope: scope, elapsed: Date().timeIntervalSince(loginStartedAt))
            return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
        }

        let gallery = GalleryService()
        let courses = CourseService()
        if capture == .cachedCourseHistory {
            validateCachedCourseHistoryFixture(scope: scope)
        }
        if capture == .courseHistory {
            courseHistorySamples = await captureCourseHistorySamples(using: courses, scope: scope)
            return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
        }

        _ = await probe("open.aihelpme.dev 首页", scope: scope) {
            try await Self.fetchDataCount(urlString: "https://open.aihelpme.dev")
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
                    try await Self.fetchDataCount(urlString: image.lowUrl.isEmpty ? image.url : image.lowUrl)
                }
            }
            _ = await probe("话廊网页详情", scope: scope) {
                try await Self.fetchDataCount(urlString: "https://open.aihelpme.dev/gallery/\(poster.id)")
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
                try await Self.fetchDataCount(urlString: "https://open.aihelpme.dev/course/\(course.id)")
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

        // 可信成绩单探针位于学校相关探针的首段，模拟用户手动点击“申请可信成绩单”的路径。
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

        // 成绩页与可信成绩单同属学校网络链路；短信二次验证时记录为 AUTH_BLOCKED，
        // 区分认证阻塞与网络故障。
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
            try await Self.fetchDataCount(urlString: "https://itunes.apple.com/lookup?id=6761147125&country=cn")
        }
        _ = await probe("紧急更新配置接口", scope: scope) {
            try await Self.fetchDataCount(
                urlString: "https://update.aihelpme.dev/emergency-update.json"
            )
        }
        _ = await probe("feedback.aihelpme.dev 写入恢复", scope: scope) {
            try await FeedbackSubmissionClient.submitNetworkSmoke(runID: runID)
        }

        return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
    }

    private func validateCachedCourseHistoryFixture(scope: NetworkSmokeScope) {
        do {
            let fixture = try ReleaseNetworkSmokeReportStore.readCachedCourseHistoryFixture()
            var mismatches: [String] = []
            let expectedGradeCount = fixture.courses.reduce(0) { $0 + $1.grades.count }
            var uncertainGradeCount = 0
            var predictedCandidateCount = 0
            var truePositive = 0
            var falsePositive = 0
            var falseNegative = 0
            var trueNegative = 0

            if fixture.sampledCourseCount != fixture.courses.count {
                mismatches.append("课程数量元数据与缓存内容不一致")
            }
            if fixture.sampledGradeCount != expectedGradeCount {
                mismatches.append("学期记录数量元数据与缓存内容不一致")
            }

            for course in fixture.courses {
                let grades = course.grades.map(\.courseHistoryGrade)
                let hiddenTerms = CourseHistoryMakeupPolicy.hiddenTerms(in: grades)
                predictedCandidateCount += hiddenTerms.count
                for grade in course.grades {
                    let predicted = hiddenTerms.contains(grade.term)
                    switch grade.manualLabel {
                    case "likely_makeup":
                        truePositive += predicted ? 1 : 0
                        falseNegative += predicted ? 0 : 1
                    case "likely_formal":
                        trueNegative += predicted ? 0 : 1
                        falsePositive += predicted ? 1 : 0
                    case "uncertain":
                        uncertainGradeCount += 1
                    default:
                        mismatches.append("\(course.courseNumber) \(grade.term) 的人工标签无法识别")
                    }
                }
            }

            courseHistoryAuditMetrics = CourseHistoryAuditMetrics(
                courseCount: fixture.courses.count,
                gradeCount: expectedGradeCount,
                labeledGradeCount: truePositive + falsePositive + falseNegative + trueNegative,
                uncertainGradeCount: uncertainGradeCount,
                predictedCandidateCount: predictedCandidateCount,
                truePositive: truePositive,
                falsePositive: falsePositive,
                falseNegative: falseNegative,
                trueNegative: trueNegative
            )

            if mismatches.isEmpty {
                print(
                    "NETWORK_SMOKE_PASS name=课程历史缓存验证 "
                        + "courses=\(fixture.courses.count) grades=\(expectedGradeCount) "
                        + "predicted=\(predictedCandidateCount) "
                        + "precision=\(String(format: "%.1f%%", courseHistoryAuditMetrics?.precision ?? 0)) "
                        + "recall=\(String(format: "%.1f%%", courseHistoryAuditMetrics?.recall ?? 0))"
                )
            } else {
                recordFailure(
                    "课程历史缓存验证",
                    mismatches.joined(separator: "；"),
                    scope: scope
                )
            }
        } catch {
            recordFailure("课程历史缓存验证", error.localizedDescription, scope: scope)
        }
    }

    private func captureCourseHistorySamples(
        using courses: CourseService,
        scope: NetworkSmokeScope
    ) async -> [CourseHistoryAuditSample] {
        let startedAt = Date()
        var courseRows: [CourseSummary] = []
        for page in 0 ..< 8 {
            do {
                let pageRows = try await courses.fetchCourses(search: "", page: page)
                guard !pageRows.isEmpty else { break }
                courseRows.append(contentsOf: pageRows)
            } catch {
                recordFailure("学业课程历史数据采样课程列表", error.localizedDescription, scope: scope)
                break
            }
        }

        var seenNumbers = Set<String>()
        let candidates = courseRows.filter { course in
            let number = course.number.trimmingCharacters(in: .whitespacesAndNewlines)
            return !number.isEmpty && seenNumbers.insert(number).inserted
        }

        var samples: [CourseHistoryAuditSample] = []
        var requestFailures = 0
        for course in candidates.prefix(80) {
            do {
                let grades = try await courses.fetchCourseHistories(number: course.number)
                guard !grades.isEmpty else { continue }
                samples.append(
                    CourseHistoryAuditSample(
                        courseID: course.id,
                        courseName: course.name,
                        courseNumber: course.number,
                        teachersName: course.teachersName,
                        grades: grades
                    )
                )
            } catch {
                requestFailures += 1
                if Self.isAuthenticationBlocked(error) {
                    recordAuthenticationBlocker(
                        "学业课程历史数据采样",
                        error.localizedDescription,
                        scope: scope,
                        elapsed: Date().timeIntervalSince(startedAt)
                    )
                    break
                }
            }
        }

        if samples.isEmpty, failures.isEmpty, authenticationBlockers.isEmpty {
            recordFailure("学业课程历史数据采样", "课程历史接口返回空数据", scope: scope)
        }
        print(
            "NETWORK_SMOKE_PASS name=学业课程历史数据采样 "
                + "courses=\(candidates.prefix(80).count) samples=\(samples.count) "
                + "request_failures=\(requestFailures) elapsed=\(Self.duration(Date().timeIntervalSince(startedAt)))"
        )
        return samples
    }

    private func finishReport(runID: String, scope: NetworkSmokeScope, startedAt: Date) async -> ReleaseNetworkSmokeReport {
        let report = ReleaseNetworkSmokeReport(
            runID: runID,
            scope: scope,
            startedAt: startedAt,
            finishedAt: Date(),
            passed: failures.isEmpty && authenticationBlockers.isEmpty,
            failures: failures,
            authenticationBlockers: authenticationBlockers,
            courseHistorySamples: courseHistorySamples,
            courseHistoryAuditMetrics: courseHistoryAuditMetrics
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

    private nonisolated static func fetchDataCount(urlString: String) async throws -> Int {
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
