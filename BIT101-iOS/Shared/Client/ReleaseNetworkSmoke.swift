import CommunityCore
import ClientCore
import Foundation
import ImageIO

// MARK: - Release network smoke

#if DEBUG || RELEASE_NETWORK_SMOKE

nonisolated private struct AppStoreNetworkSmokeResponse: Decodable {
    nonisolated struct Result: Decodable {
        let version: String
        let bundleID: String?
        let trackViewURL: URL?

        enum CodingKeys: String, CodingKey {
            case version
            case bundleID = "bundleId"
            case trackViewURL = "trackViewUrl"
        }
    }

    let resultCount: Int
    let results: [Result]
}

nonisolated private struct EmergencyUpdateSmokeEnvelope: Decodable {
    let schemaVersion: Int
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case enabled
        case schemaVersion = "schema_version"
    }
}

/// NetworkSmokeScope 表示发布前网络冒烟执行的范围。
///
/// NetworkSmokeScope 使用与脚本入口一致的名称和语义；正式 App、测试宿主和命令行脚本复用同一组探针。
@MainActor
final class ReleaseNetworkSmokeRunner {
    private var failures: [String] = []
    private var authenticationBlockers: [String] = []
    private var scheduleCache: ScheduleCacheAuditSnapshot?
    private var executedProbes: [String] = []
    private var skippedProbes: [String] = []
    private var coverageGaps: [String] = []

    func run(
        scope: NetworkSmokeScope,
        runID: String = UUID().uuidString,
        capture: NetworkSmokeCapture = .none,
        term requestedTerm: String? = nil
    ) async -> ReleaseNetworkSmokeReport {
        failures = []
        authenticationBlockers = []
        scheduleCache = nil
        ReleaseNetworkSmokeReportStore.rawCourseCaptureEnabled = capture == .rawCourseResponse
        ReleaseNetworkSmokeReportStore.clearRawCourseResponse()
        executedProbes = []
        skippedProbes = []
        coverageGaps = []
        let startedAt = Date()

        executedProbes.append("BIT101 登录状态")
        let loginStartedAt = Date()
        do {
            let loginResult = try await LoginService().checkLogin()
            guard let signedInStudentID = loginResult, !signedInStudentID.isEmpty else {
                recordFailure("BIT101 登录状态", "真机没有有效登录状态，无法执行发布前网络冒烟测试", area: .authentication, scope: scope)
                return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
            }
            print("NETWORK_SMOKE_PASS name=BIT101 登录状态 elapsed=\(Self.duration(Date().timeIntervalSince(loginStartedAt)))")
        } catch {
            recordFailure("BIT101 登录状态", error.localizedDescription, area: .authentication, scope: scope, elapsed: Date().timeIntervalSince(loginStartedAt))
            return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
        }

        let gallery = GalleryService()
        let courses = CourseService()
        // The Worker root intentionally redirects to the public gallery landing page.
        _ = await probe("open.aihelpme.dev 首页跳转", area: .bit101, scope: scope) {
            try await Self.fetchHTMLCount(
                urlString: "https://open.aihelpme.dev",
                expectedHost: "bit101.cn",
                initialHost: "open.aihelpme.dev"
            )
        }
        let posters = await probe("话廊最新列表", area: .bit101, scope: scope) {
            try await gallery.fetchFeed(kind: .newest, page: nil)
        }
        if let poster = posters?.first {
            _ = await probe("话廊帖子详情", area: .bit101, scope: scope) {
                try await gallery.fetchPoster(id: poster.id)
            }
            _ = await probe("话廊帖子评论", area: .bit101, scope: scope) {
                try await gallery.fetchComments(
                    objectID: "poster\(poster.id)",
                    order: .newest,
                    page: nil
                )
            }
            let image = poster.images.first ?? poster.user.avatar
            let imageURL = image.lowUrl.isEmpty ? image.url : image.lowUrl
            if imageURL.isEmpty {
                recordSkip("话廊图片下载", "帖子没有可用图片地址", area: .bit101, scope: scope)
            } else {
                _ = await probe("话廊图片下载", area: .bit101, scope: scope) {
                    try await Self.fetchImageCount(urlString: imageURL)
                }
            }
            _ = await probe("话廊网页详情", area: .bit101, scope: scope) {
                try await Self.fetchHTMLCount(
                    urlString: "https://open.aihelpme.dev/gallery/\(poster.id)",
                    expectedHost: "open.aihelpme.dev"
                )
            }
        } else {
            let reason = posters == nil ? "列表探针没有可用数据" : "列表为空"
            recordSkip("话廊帖子详情", reason, area: .bit101, scope: scope)
            recordSkip("话廊帖子评论", reason, area: .bit101, scope: scope)
            recordSkip("话廊图片下载", reason, area: .bit101, scope: scope)
            recordSkip("话廊网页详情", reason, area: .bit101, scope: scope)
        }
        var galleryOperations: [@MainActor () async -> Void] = [
            { _ = await self.probe("话廊推荐流", area: .bit101, scope: scope) { try await gallery.fetchRecommendPage(sourcePage: 0) } },
            { _ = await self.probe("话廊机器人流", area: .bit101, scope: scope) { try await gallery.fetchBotFeed(startPage: 0) } },
            { _ = await self.probe("帖子声明列表", area: .bit101, scope: scope) { try await gallery.fetchClaims() } },
            {
                _ = await self.probe("话廊搜索", area: .bit101, scope: scope) {
                    try await gallery.searchPosters(query: GallerySearchQuery(text: "BIT101"), page: 0)
                }
            },
            { _ = await self.probe("消息未读数", area: .bit101, scope: scope) { try await gallery.fetchMessageUnreadCounts() } }
        ]
        for messageType in GalleryMessageType.allCases {
            galleryOperations.append { [messageType] in
                _ = await self.probe("消息列表-\(messageType.rawValue)", area: .bit101, scope: scope) {
                    try await gallery.fetchMessages(type: messageType, lastID: nil)
                }
            }
        }
        await runInParallel(galleryOperations)

        let courseRows = await probe("学业课程列表", area: .bit101, scope: scope) {
            try await courses.fetchCourses(search: "", page: 0)
        }
        if let course = courseRows?.first {
            _ = await probe("学业课程详情", area: .bit101, scope: scope) {
                try await courses.fetchCourse(id: course.id)
            }
            _ = await probe("学业课程评论", area: .bit101, scope: scope) {
                try await courses.fetchComments(courseID: course.id, page: nil)
            }
            _ = await probe("学业课程历史成绩", area: .bit101, scope: scope) {
                try await courses.fetchCourseHistories(number: course.number)
            }
            _ = await probe("学业课程网页详情", area: .bit101, scope: scope) {
                try await Self.fetchHTMLCount(
                    urlString: "https://open.aihelpme.dev/course/\(course.id)",
                    expectedHost: "open.aihelpme.dev"
                )
            }
        } else {
            let reason = courseRows == nil ? "列表探针没有可用数据" : "列表为空"
            recordSkip("学业课程详情", reason, area: .bit101, scope: scope)
            recordSkip("学业课程评论", reason, area: .bit101, scope: scope)
            recordSkip("学业课程历史成绩", reason, area: .bit101, scope: scope)
            recordSkip("学业课程网页详情", reason, area: .bit101, scope: scope)
        }

        let papers = PaperService()
        let paperRows = await probe("文章列表", area: .bit101, scope: scope) {
            try await papers.fetchPapers(search: nil, order: .newest, page: 0)
        }
        if let paper = paperRows?.first {
            _ = await probe("文章详情", area: .bit101, scope: scope) {
                try await papers.fetchPaper(id: paper.id)
            }
            _ = await probe("文章评论", area: .bit101, scope: scope) {
                try await papers.fetchComments(paperID: paper.id, order: .newest, page: nil)
            }
        } else {
            let reason = paperRows == nil ? "列表探针没有可用数据" : "列表为空"
            recordSkip("文章详情", reason, area: .bit101, scope: scope)
            recordSkip("文章评论", reason, area: .bit101, scope: scope)
        }
        await runInParallel(PaperSortOrder.allCases.map { order in
            {
                _ = await self.probe("文章列表-\(order.title)", area: .bit101, scope: scope) {
                    try await papers.fetchPapers(search: "BIT101", order: order, page: 0)
                }
            }
        })

        let mine = MineService()
        let myInfo = await probe("我的资料", area: .bit101, scope: scope) { try await mine.fetchMyInfo() }
        await runInParallel([
            { _ = await self.probe("我的关注", area: .bit101, scope: scope) { try await mine.fetchFollowings(page: 0) } },
            { _ = await self.probe("我的粉丝", area: .bit101, scope: scope) { try await mine.fetchFollowers(page: 0) } },
            { _ = await self.probe("我的帖子", area: .bit101, scope: scope) { try await mine.fetchMyPosters(page: 0) } }
        ])
        if let myInfo {
            _ = await probe("用户资料详情", area: .bit101, scope: scope) { try await mine.fetchUserInfo(id: myInfo.user.id) }
            _ = await probe("用户帖子", area: .bit101, scope: scope) { try await mine.fetchUserPosters(userID: myInfo.user.id, page: 0) }
        } else {
            recordSkip("用户资料详情", "资料探针没有可用数据", area: .bit101, scope: scope)
            recordSkip("用户帖子", "资料探针没有可用数据", area: .bit101, scope: scope)
        }

        // 可信成绩单探针位于学校相关探针的首段，模拟用户手动点击“申请可信成绩单”的路径。
        let scoreService = ScoreService()
        _ = await probe("可信成绩单接口", area: .transcript, scope: scope) {
            let pages = try await scoreService.fetchTrustedTranscriptPages()
            return try Self.validateTrustedTranscriptPages(pages)
        }

        let schedule = ScheduleService()
        _ = await probe("当前学期", area: .schedule, scope: scope) { try await schedule.fetchCurrentTermOnly() }
        let terms = await probe("切换学期列表", area: .schedule, scope: scope) {
            try await schedule.fetchAvailableTerms()
        }
        let normalizedRequestedTerm = requestedTerm?.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = normalizedRequestedTerm?.isEmpty == false
            ? normalizedRequestedTerm
            : terms?.first
        if let term {
            let syncPayload = await probe("课表、考试与首周同步", area: .schedule, scope: scope) {
                let payload = try await schedule.syncCourses(term: term)
                try Self.validateCourseSyncPayload(payload)
                return payload
            }
            if capture == .scheduleCache, let syncPayload {
                scheduleCache = captureScheduleCache(from: syncPayload)
            }

            let campuses = await probe("空教室校区列表", area: .schedule, scope: scope) {
                try await schedule.fetchCampuses()
            }
            if let campus = campuses?.first {
                let buildings = await probe("空教室教学楼列表", area: .schedule, scope: scope) {
                    try await schedule.fetchBuildings(campusCode: campus.code)
                }
                if let building = buildings?.first {
                    _ = await probe("空教室占用数据", area: .schedule, scope: scope) {
                        try await schedule.fetchClassrooms(buildingID: building.id, term: term)
                    }
                } else {
                    let reason = buildings == nil ? "教学楼探针没有可用数据" : "教学楼列表为空"
                    recordSkip("空教室占用数据", reason, area: .schedule, scope: scope)
                }
            } else {
                let reason = campuses == nil ? "校区探针没有可用数据" : "校区列表为空"
                recordSkip("空教室教学楼列表", reason, area: .schedule, scope: scope)
                recordSkip("空教室占用数据", reason, area: .schedule, scope: scope)
            }
        } else {
            let reason = terms == nil ? "学期探针没有可用数据" : "学期列表为空"
            recordSkip("课表、考试与首周同步", reason, area: .schedule, scope: scope)
            recordSkip("空教室校区列表", reason, area: .schedule, scope: scope)
            recordSkip("空教室教学楼列表", reason, area: .schedule, scope: scope)
            recordSkip("空教室占用数据", reason, area: .schedule, scope: scope)
        }
        let calendarURL = await probe("乐学日历订阅地址", area: .ddl, scope: scope) {
            try await schedule.refreshLexueCalendarURL(
                schoolSMSCodeHandler: nil,
                smsDeliveryMode: .preflight
            )
        }
        if let calendarURL {
            _ = await probe("乐学 DDL 下载", area: .ddl, scope: scope) {
                try await schedule.syncDDLEvents(
                    existingEvents: [],
                    storedURL: calendarURL,
                    schoolSMSCodeHandler: nil,
                    smsDeliveryMode: .preflight
                )
            }
        } else {
            recordSkip("乐学 DDL 下载", "日历订阅地址探针没有可用数据", area: .ddl, scope: scope)
        }

        // 成绩页与可信成绩单同属学校网络链路；短信二次验证时记录为 AUTH_BLOCKED，
        // 区分认证阻塞与网络故障。
        let scoreChallenge = await probe("成绩认证接口", area: .school, scope: scope) {
            try await scoreService.startScoreChallenge()
        }
        if let scoreChallenge {
            _ = await probe("成绩简略列表", area: .school, scope: scope) {
                try await scoreService.fetchScores(detail: false, authenticatedBy: scoreChallenge)
            }
            _ = await probe("成绩详细列表", area: .school, scope: scope) {
                try await scoreService.fetchScores(detail: true, authenticatedBy: scoreChallenge)
            }
        }

        await runInParallel([
            {
                _ = await self.probe("App Store 更新接口", area: .bit101, scope: scope) {
                    try await Self.fetchAppStoreLookup()
                }
            },
            {
                _ = await self.probe("紧急更新配置接口", area: .bit101, scope: scope) {
                    try await Self.fetchEmergencyUpdateConfiguration()
                }
            },
            {
                _ = await self.probe("feedback.aihelpme.dev 写入恢复", area: .bit101, scope: scope) {
                    try await FeedbackSubmissionClient.submitNetworkSmoke(runID: runID)
                }
            }
        ])

        return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
    }

    private func finishReport(runID: String, scope: NetworkSmokeScope, startedAt: Date) async -> ReleaseNetworkSmokeReport {
        if scope == .ddl {
            let required = ["BIT101 登录状态", "乐学日历订阅地址", "乐学 DDL 下载"]
            let missing = required.filter { !executedProbes.contains($0) }
            if !missing.isEmpty, authenticationBlockers.isEmpty {
                let line = "[DDL Smoke 覆盖] 必需探针缺失：" + missing.joined(separator: "、")
                failures.append(line)
                print("NETWORK_SMOKE_FAIL \(line)")
            }
        }

        let schoolSMSCoverage: String
        switch scope {
        case .all, .school, .ddl:
            schoolSMSCoverage = "preflight_only"
        default:
            schoolSMSCoverage = "not_run"
        }
        let report = ReleaseNetworkSmokeReport(
            runID: runID,
            scope: scope,
            startedAt: startedAt,
            finishedAt: Date(),
            passed: failures.isEmpty && authenticationBlockers.isEmpty,
            failures: failures,
            authenticationBlockers: authenticationBlockers,
            scheduleCache: scheduleCache,
            executedProbes: executedProbes,
            skippedProbes: skippedProbes,
            coverageGaps: coverageGaps,
            schoolSMSCoverage: schoolSMSCoverage
        )
        print(report.summaryLine)
        if !report.passed {
            print(report.failureMessage)
        }
        do {
            try ReleaseNetworkSmokeReportStore.write(report)
        } catch {
            print("NETWORK_SMOKE_REPORT_WRITE_FAIL error=\(ErrorReportRedactor.sanitized(error.localizedDescription))")
        }
        return report
    }

    private func captureScheduleCache(from payload: CourseSyncPayload) -> ScheduleCacheAuditSnapshot {
        let courses = payload.courses.map {
            ScheduleCacheAuditCourse(
                id: $0.id,
                name: $0.name,
                number: $0.number,
                teacher: $0.teacher,
                classroom: $0.classroom,
                weeks: $0.weeks,
                weekday: $0.weekday,
                startSection: $0.startSection,
                endSection: $0.endSection
            )
        }
        return ScheduleCacheAuditSnapshot(
            currentTerm: payload.term,
            firstDayString: payload.firstDayString,
            sourceFirstDayString: payload.sourceFirstDayString,
            normalizationOffset: payload.normalizationOffset,
            courseCount: courses.count,
            courses: courses
        )
    }

    private nonisolated static func validateCourseSyncPayload(_ payload: CourseSyncPayload) throws {
        let expectedOffset = inferredWeekOffset(for: payload)
        guard payload.normalizationOffset == expectedOffset else {
            throw NSError(
                domain: "BIT101.NetworkSmoke",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "课表周次偏移证据与归一化结果不一致。"]
            )
        }

        let calendar = Calendar(identifier: .gregorian)
        guard let sourceDate = scheduleDate(payload.sourceFirstDayString),
              let normalizedDate = scheduleDate(payload.firstDayString)
        else { return }
        let dayDelta = calendar.dateComponents([.day], from: sourceDate, to: normalizedDate).day ?? 0
        guard dayDelta == expectedOffset * 7 else {
            throw NSError(
                domain: "BIT101.NetworkSmoke",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "课表首周日期与周次偏移结果不一致。"]
            )
        }
    }

    private nonisolated static func inferredWeekOffset(for payload: CourseSyncPayload) -> Int {
        guard payload.term.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-1"),
              payload.rawWeeksByCourse.count == payload.courses.count
        else { return 0 }

        struct Group {
            var rawWeeks = Set<Int>()
            var displayWeeks = Set<Int>()
        }

        var groups: [String: Group] = [:]
        for (index, course) in payload.courses.enumerated() {
            let key = "\(course.number)|\(course.name)|\(course.description)"
            var group = groups[key, default: Group()]
            group.rawWeeks.formUnion(payload.rawWeeksByCourse[index])
            group.displayWeeks.formUnion(course.weeks)
            groups[key] = group
        }

        var offsets = Set<Int>()
        var evidenceCount = 0
        for group in groups.values {
            let raw = group.rawWeeks.sorted()
            let display = group.displayWeeks.sorted()
            guard raw.count == display.count,
                  raw.count >= 2,
                  display.allSatisfy({ $0 > 0 })
            else { continue }
            let differences = Set(zip(raw, display).map(-))
            guard differences.count == 1, let offset = differences.first else { continue }
            offsets.insert(offset)
            evidenceCount += 1
        }

        guard offsets.count == 1, evidenceCount >= 2 else { return 0 }
        return offsets.first ?? 0
    }

    private nonisolated static func scheduleDate(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: parts[0],
            month: parts[1],
            day: parts[2]
        ))
    }

    private func probe<Value>(
        _ name: String,
        area: NetworkSmokeArea,
        scope: NetworkSmokeScope,
        operation: () async throws -> Value
    ) async -> Value? {
        guard scope.includes(area) else {
            skippedProbes.append(name)
            print("NETWORK_SMOKE_SKIP name=\(name) scope=\(scope.rawValue)")
            return nil
        }
        executedProbes.append(name)
        let startedAt = Date()
        do {
            let value = try await operation()
            print("NETWORK_SMOKE_PASS name=\(name) elapsed=\(Self.duration(Date().timeIntervalSince(startedAt)))")
            return value
        } catch {
            let elapsed = Date().timeIntervalSince(startedAt)
            if Self.isAuthenticationBlocked(error) {
                recordAuthenticationBlocker(name, error.localizedDescription, area: area, scope: scope, elapsed: elapsed)
            } else {
                recordFailure(name, error.localizedDescription, area: area, scope: scope, elapsed: elapsed)
            }
            return nil
        }
    }

    private func recordFailure(
        _ name: String,
        _ message: String,
        area: NetworkSmokeArea,
        scope: NetworkSmokeScope,
        elapsed: TimeInterval? = nil
    ) {
        guard scope.includes(area) else { return }
        let timing = elapsed.map { " elapsed=\(Self.duration($0))" } ?? ""
        let line = "[\(name)] \(ErrorReportRedactor.sanitized(message))\(timing)"
        failures.append(line)
        print("NETWORK_SMOKE_FAIL \(line)")
    }

    private func recordSkip(
        _ name: String,
        _ reason: String,
        area: NetworkSmokeArea,
        scope: NetworkSmokeScope
    ) {
        guard scope.includes(area) else { return }
        let entry = "\(name)（\(reason)）"
        skippedProbes.append(entry)
        coverageGaps.append(entry)
        print("NETWORK_SMOKE_SKIP name=\(name) reason=\(reason) scope=\(scope.rawValue)")
    }

    private func recordAuthenticationBlocker(
        _ name: String,
        _ message: String,
        area: NetworkSmokeArea,
        scope: NetworkSmokeScope,
        elapsed: TimeInterval
    ) {
        guard scope.includes(area) else { return }
        let line = "[\(name)] \(ErrorReportRedactor.sanitized(message)) elapsed=\(Self.duration(elapsed))"
        authenticationBlockers.append(line)
        print("NETWORK_SMOKE_AUTH_BLOCKED \(line)")
    }

    private func runInParallel(_ operations: [@MainActor () async -> Void]) async {
        await withTaskGroup(of: Void.self) { group in
            for operation in operations {
                group.addTask {
                    await operation()
                }
            }
        }
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

    private nonisolated static func fetchImageCount(urlString: String) async throws -> Int {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let response = try await fetchResponse(url)
        try validateImageData(response.data)
        return response.data.count
    }

    private nonisolated static func validateImageData(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else {
            throw URLError(.cannotDecodeContentData)
        }
    }

    private nonisolated static func fetchHTMLCount(
        urlString: String,
        expectedHost: String,
        initialHost: String? = nil
    ) async throws -> Int {
        guard let url = URL(string: urlString),
              url.host?.lowercased() == (initialHost ?? expectedHost).lowercased()
        else {
            throw URLError(.badURL)
        }
        let response = try await fetchResponse(url)
        return try validateHTMLResponse(
            response.data,
            finalURL: response.response.url,
            expectedHost: expectedHost
        )
    }

    nonisolated static func validateHTMLResponse(
        _ data: Data,
        finalURL: URL?,
        expectedHost: String
    ) throws -> Int {
        guard finalURL?.host?.lowercased() == expectedHost else {
            throw URLError(.badServerResponse)
        }
        let body = String(decoding: data, as: UTF8.self).lowercased()
        guard body.contains("<html") || body.contains("<!doctype html") else {
            throw URLError(.cannotParseResponse)
        }
        return data.count
    }

    nonisolated static func validateAppStoreLookup(_ data: Data) throws -> Int {
        let response = try JSONDecoder().decode(AppStoreNetworkSmokeResponse.self, from: data)
        guard response.resultCount > 0,
              response.resultCount == response.results.count,
              let result = response.results.first,
              !result.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.bundleID == "BIT101-dev.BIT101-iOS",
              let trackViewURL = result.trackViewURL,
              BIT101AppStore.acceptsUpdateURL(trackViewURL)
        else {
            throw URLError(.cannotParseResponse)
        }
        return response.resultCount
    }

    nonisolated static func validateEmergencyUpdateConfiguration(_ data: Data) throws -> Bool {
        let envelope = try JSONDecoder().decode(EmergencyUpdateSmokeEnvelope.self, from: data)
        guard envelope.schemaVersion == 1 else { throw URLError(.cannotParseResponse) }
        guard envelope.enabled else { return false }

        let notice = try JSONDecoder().decode(EmergencyUpdateNotice.self, from: data)
        guard !notice.noticeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !notice.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !notice.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw URLError(.cannotParseResponse)
        }
        return true
    }

    nonisolated static func validateTrustedTranscriptPages(_ pages: [Data]) throws -> Int {
        guard !pages.isEmpty else { throw URLError(.zeroByteResource) }
        for page in pages {
            try validateImageData(page)
        }
        return pages.count
    }

    private nonisolated static func fetchAppStoreLookup() async throws -> Int {
        let url = AppURL.required("https://itunes.apple.com/lookup?id=6761147125&country=cn")
        let response = try await fetchResponse(url)
        guard response.response.url?.host?.lowercased() == "itunes.apple.com" else {
            throw URLError(.badServerResponse)
        }
        return try validateAppStoreLookup(response.data)
    }

    private nonisolated static func fetchEmergencyUpdateConfiguration() async throws -> Bool {
        let url = AppURL.required("https://update.aihelpme.dev/emergency-update.json")
        let response = try await fetchResponse(url)
        guard response.response.url?.host?.lowercased() == "update.aihelpme.dev" else {
            throw URLError(.badServerResponse)
        }
        return try validateEmergencyUpdateConfiguration(response.data)
    }

    private nonisolated static func fetch(_ url: URL) async throws -> Data {
        try await fetchResponse(url).data
    }

    private nonisolated static func fetchResponse(_ url: URL) async throws -> HTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("BIT101-iOS release network smoke", forHTTPHeaderField: "User-Agent")
        let response = try await HTTPClient.shared.send(request, accepting: 200 ..< 400)
        guard !response.data.isEmpty else { throw URLError(.zeroByteResource) }
        return response
    }

    private nonisolated static func duration(_ interval: TimeInterval) -> String {
        String(format: "%.2fs", interval)
    }
}

#endif
