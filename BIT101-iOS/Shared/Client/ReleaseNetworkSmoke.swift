import SchedulePorts
import ClientCore
import ScoreDomain
import ScoreInfrastructure
import MineFeature
import PaperFeature
import CourseFeature
import GalleryFeature
import TransportCore
import ScoreFeature
import CommunityCore
import Foundation
import ScheduleDomain
import ScheduleInfrastructure
import MediaKit

// MARK: - Release network smoke

#if DEBUG || RELEASE_NETWORK_SMOKE

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
/// NetworkSmokeScope 使用与脚本入口一致的名称和语义；采样宿主、测试入口和命令行脚本复用同一组探针。
@MainActor
private final class NetworkSmokeExecutionGate {
    private var isRunning = false
    private var waiting: [(UUID, CheckedContinuation<Bool, Never>)] = []

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isRunning else { isRunning = true; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiting.firstIndex(where: { $0.0 == id }) else { return }
                self.waiting.remove(at: index).1.resume(returning: false)
            }
        }
    }

    func release() {
        if waiting.isEmpty { isRunning = false }
        else { waiting.removeFirst().1.resume(returning: true) }
    }
}

@MainActor
final class ReleaseNetworkSmokeRunner {
    private static let executionGate = NetworkSmokeExecutionGate()
    private let dependencies: ReleaseNetworkSmokeDependencies
    private var failures: [String] = []
    private var communityWriteEvidence: [String] = []
    private var authenticationBlockers: [String] = []
    private var scheduleCache: ScheduleCacheAuditSnapshot?
    private var eclassDDL: EclassDDLAudit?
    private var executedProbes: [String] = []
    private var skippedProbes: [String] = []
    private var coverageGaps: [String] = []
    private var schoolSMSHandler: SchoolSMSCodeHandler?
    private var schoolSMSSchedule: (any NetworkSmokeScheduleServicing)?
    private var smsSubmissions = 0
    private var submittedSMSPurposes: [String] = []
    private var verifiedSMSProbes: [SchoolSMSProbeEvidence] = []

    init(dependencies: ReleaseNetworkSmokeDependencies = .init()) { self.dependencies = dependencies }

    func run(
        scope: NetworkSmokeScope,
        runID: String = UUID().uuidString,
        capture: NetworkSmokeCapture = .none,
        term requestedTerm: String? = nil,
        schoolSMSCodeHandler: SchoolSMSCodeHandler? = nil
    ) async -> ReleaseNetworkSmokeReport {
        let startedAt = Date()
        let acquired = await Self.executionGate.acquire()
        guard acquired && !Task.isCancelled else {
            if acquired { Self.executionGate.release() }
            return ReleaseNetworkSmokeReport(runID: runID, scope: scope, startedAt: startedAt, finishedAt: Date(),
                passed: false, failures: ["网络 Smoke 排队已取消"], authenticationBlockers: [], scheduleCache: nil,
                executedProbes: [], skippedProbes: [], coverageGaps: ["执行已取消"], schoolSMSCoverage: "not_run",
                requiredProbes: scope.requiredProbes)
        }
        defer { Self.executionGate.release() }
        failures = []
        communityWriteEvidence = []
        authenticationBlockers = []
        scheduleCache = nil
        eclassDDL = nil
        executedProbes = []
        skippedProbes = []
        coverageGaps = []
        smsSubmissions = 0
        submittedSMSPurposes = []
        verifiedSMSProbes = []
        if let handler = schoolSMSCodeHandler {
            schoolSMSHandler = { [weak self] request in
                let code = try await handler(request)
                self?.smsSubmissions += 1
                self?.submittedSMSPurposes.append(request.purpose)
                return code
            }
        } else {
            schoolSMSHandler = nil
        }
        defer { schoolSMSHandler = nil; schoolSMSSchedule = nil }

        if scope != .communityCleanup && scope != .communityWrites {
            do { try dependencies.clearRawCourseResponse() }
            catch {
                recordFailure("原始课表采样清理", error.localizedDescription, area: .authentication, scope: scope)
                return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
            }
        }

        executedProbes.append("BIT101 登录状态")
        let loginStartedAt = Date()
        do {
            let loginResult = try await dependencies.checkLogin()
            guard let signedInStudentID = loginResult, !signedInStudentID.isEmpty else {
                recordFailure("BIT101 登录状态", "真机没有有效登录状态，无法执行发布前网络冒烟测试", area: .authentication, scope: scope)
                return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
            }
            print("NETWORK_SMOKE_PASS name=BIT101 登录状态 elapsed=\(Self.duration(Date().timeIntervalSince(loginStartedAt)))")
        } catch {
            recordFailure("BIT101 登录状态", error.localizedDescription, area: .authentication, scope: scope, elapsed: Date().timeIntervalSince(loginStartedAt))
            return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
        }

        if scope == .communityWrites || scope == .communityCleanup {
            communityWriteEvidence = await probe("社区写入与清理", area: .communityWrites, scope: scope) {
                try await self.dependencies.communityWriteProbe(runID, scope == .communityCleanup)
            } ?? []
            return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
        }

        let gallery = dependencies.makeGallery()
        let courses = dependencies.makeCourses()
        await runInParallel([
            {
                _ = await self.probe("App 链接关联配置", area: .bit101, scope: scope) {
                    let request = URLRequest(url: Self.aasaURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                    return try Self.validateAASA(try await self.dependencies.aasaHTTPClient.send(request))
                }
            },
            {
                _ = await self.probe("分享图标下载", area: .bit101, scope: scope) {
                    try await self.fetchImageCount(urlString: "https://open.aihelpme.dev/share-icon.jpg")
                }
            },
            {
                _ = await self.probe("反馈接口跨域预检", area: .bit101, scope: scope) {
                    var request = URLRequest(url: AppURL.required("https://feedback.aihelpme.dev/api/error-reports"))
                    request.httpMethod = "OPTIONS"
                    let response = try await self.dependencies.externalHTTPClient.send(request, accepting: 200..<300)
                    guard response.response.statusCode == 204, response.data.isEmpty,
                          response.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*"
                    else { throw URLError(.badServerResponse) }
                    return true
                }
            }
        ])
        // The Worker root intentionally redirects to the public gallery landing page.
        _ = await probe("open.aihelpme.dev 首页跳转", area: .bit101, scope: scope) {
            try await self.fetchHTMLCount(
                urlString: "https://open.aihelpme.dev",
                expectedHost: "bit101.cn",
                initialHost: "open.aihelpme.dev"
            )
        }
        let posters = await probe("话廊最新列表", area: .bit101, scope: scope) {
            try await gallery.fetchFeed(kind: .newest, page: nil).items
        }
        if let poster = posters?.first {
            await runInParallel([
                {
                    _ = await self.probe("话廊帖子详情", area: .bit101, scope: scope) {
                        try await gallery.fetchPoster(id: poster.id)
                    }
                },
                {
                    _ = await self.probe("话廊帖子评论", area: .bit101, scope: scope) {
                        try await gallery.fetchComments(
                            objectID: "poster\(poster.id)",
                            order: .newest,
                            page: nil
                        )
                    }
                }
            ])
            let image = poster.images.first ?? poster.user.avatar
            let imageURL = image.lowUrl.isEmpty ? image.url : image.lowUrl
            if imageURL.isEmpty {
                recordSkip("话廊图片下载", "帖子没有可用图片地址", area: .bit101, scope: scope)
            } else {
                _ = await probe("话廊图片下载", area: .bit101, scope: scope) {
                    try await self.fetchImageCount(urlString: imageURL)
                }
            }
            _ = await probe("话廊网页详情", area: .bit101, scope: scope) {
                try await self.fetchHTMLCount(
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
                    try await gallery.fetchMessages(type: messageType, lastID: .max)
                }
            }
        }
        await runInParallel(galleryOperations)

        let courseRows = await probe("学业课程列表", area: .bit101, scope: scope) {
            try await courses.fetchCourses(search: "", page: 0)
        }
        if let course = courseRows?.first {
            await runInParallel([
                {
                    _ = await self.probe("学业课程详情", area: .bit101, scope: scope) {
                        try await courses.fetchCourse(id: course.id)
                    }
                },
                {
                    _ = await self.probe("学业课程评论", area: .bit101, scope: scope) {
                        try await courses.fetchComments(courseID: course.id, page: nil)
                    }
                },
                {
                    _ = await self.probe("学业课程历史成绩", area: .bit101, scope: scope) {
                        try await courses.fetchCourseHistories(number: course.number)
                    }
                },
                {
                    _ = await self.probe("学业课程网页详情", area: .bit101, scope: scope) {
                        try await self.fetchHTMLCount(
                            urlString: "https://open.aihelpme.dev/course/\(course.id)",
                            expectedHost: "open.aihelpme.dev"
                        )
                    }
                }
            ])
        } else {
            let reason = courseRows == nil ? "列表探针没有可用数据" : "列表为空"
            recordSkip("学业课程详情", reason, area: .bit101, scope: scope)
            recordSkip("学业课程评论", reason, area: .bit101, scope: scope)
            recordSkip("学业课程历史成绩", reason, area: .bit101, scope: scope)
            recordSkip("学业课程网页详情", reason, area: .bit101, scope: scope)
        }

        let papers = dependencies.makePapers()
        let paperRows = await probe("文章列表", area: .bit101, scope: scope) {
            try await papers.fetchPapers(search: nil, order: .newest, page: 0)
        }
        if let paper = paperRows?.first {
            await runInParallel([
                {
                    _ = await self.probe("文章详情", area: .bit101, scope: scope) {
                        try await papers.fetchPaper(id: paper.id)
                    }
                },
                {
                    _ = await self.probe("文章评论", area: .bit101, scope: scope) {
                        try await papers.fetchComments(paperID: paper.id, order: .newest, page: nil)
                    }
                },
                {
                    _ = await self.probe("文章网页详情", area: .bit101, scope: scope) {
                        try await self.fetchHTMLCount(urlString: "https://open.aihelpme.dev/paper/\(paper.id)",
                                                     expectedHost: "open.aihelpme.dev")
                    }
                }
            ])
        } else {
            let reason = paperRows == nil ? "列表探针没有可用数据" : "列表为空"
            recordSkip("文章详情", reason, area: .bit101, scope: scope)
            recordSkip("文章评论", reason, area: .bit101, scope: scope)
            recordSkip("文章网页详情", reason, area: .bit101, scope: scope)
        }
        await runInParallel(PaperSortOrder.allCases.map { order in
            {
                _ = await self.probe("文章列表-\(order.title)", area: .bit101, scope: scope) {
                    try await papers.fetchPapers(search: "BIT101", order: order, page: 0)
                }
            }
        })

        let mine = dependencies.makeMine()
        let myInfo = await probe("我的资料", area: .bit101, scope: scope) { try await mine.fetchMyInfo() }
        await runInParallel([
            { _ = await self.probe("我的关注", area: .bit101, scope: scope) { try await mine.fetchFollowings(page: 0) } },
            { _ = await self.probe("我的粉丝", area: .bit101, scope: scope) { try await mine.fetchFollowers(page: 0) } },
            { _ = await self.probe("我的帖子", area: .bit101, scope: scope) { try await mine.fetchMyPosters(page: 0) } }
        ])
        if let myInfo {
            await runInParallel([
                {
                    _ = await self.probe("用户资料详情", area: .bit101, scope: scope) { try await mine.fetchUserInfo(id: myInfo.user.id) }
                },
                {
                    _ = await self.probe("用户帖子", area: .bit101, scope: scope) { try await mine.fetchUserPosters(userID: myInfo.user.id, page: 0) }
                }
            ])
        } else {
            recordSkip("用户资料详情", "资料探针没有可用数据", area: .bit101, scope: scope)
            recordSkip("用户帖子", "资料探针没有可用数据", area: .bit101, scope: scope)
        }

        // 可信成绩单探针位于学校相关探针的首段，模拟用户手动点击“申请可信成绩单”的路径。
        let scoreService = dependencies.makeScores()
        _ = await probe("可信成绩单接口", area: .transcript, scope: scope) {
            let pages: [Data]
            do { pages = try await scoreService.fetchTrustedTranscriptPages() }
            catch ScoreServiceError.secondFactorRequired(let challenge) {
                guard let handler = self.schoolSMSHandler else { throw ScoreServiceError.secondFactorRequired(challenge) }
                let code = try await handler(SchoolSMSCodeRequest(maskedPhone: challenge.maskedPhone ?? "", purpose: "jwb_cjd"))
                pages = try await scoreService.submitTranscriptSMSCode(code, for: challenge)
            }
            return try Self.validateTrustedTranscriptPages(pages)
        }

        var rawCourseResponseHandler: ((Data) -> Void)?
        if capture == .rawCourseResponse {
            rawCourseResponseHandler = { data in
                do { try self.dependencies.writeRawCourseResponse(data, runID) }
                catch { self.recordFailure("原始课表采样写入", error.localizedDescription, area: .schedule, scope: scope) }
            }
        }
        let schedule = dependencies.makeSchedule(rawCourseResponseHandler)
        schoolSMSSchedule = schedule
        let currentTerm = await probe("当前学期", area: .schedule, scope: scope) { try await schedule.fetchCurrentTermOnly() }
        _ = await probe("切换学期列表", area: .schedule, scope: scope) {
            try await schedule.fetchAvailableTerms()
        }
        let normalizedRequestedTerm = requestedTerm?.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = normalizedRequestedTerm?.isEmpty == false
            ? normalizedRequestedTerm
            : currentTerm
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
            let reason = "当前学期探针缺少可用学期"
            recordSkip("课表、考试与首周同步", reason, area: .schedule, scope: scope)
            recordSkip("空教室校区列表", reason, area: .schedule, scope: scope)
            recordSkip("空教室教学楼列表", reason, area: .schedule, scope: scope)
            recordSkip("空教室占用数据", reason, area: .schedule, scope: scope)
        }
        let nativeEclass = await probe("课程中心原生认证", area: .ddl, scope: scope) {
            let service = try self.dependencies.makeEclassSchedule()
            if let handler = self.schoolSMSHandler { return try await service.fetchEclassDDLEvents(schoolSMSCodeHandler: handler) }
            return try await service.fetchEclassDDLEventsForPreflight()
        }
        if let eclass = await probe("课程中心 DDL 下载", area: .ddl, scope: scope, operation: {
            if let handler = self.schoolSMSHandler { return try await schedule.fetchEclassDDLEvents(schoolSMSCodeHandler: handler) }
            return try await schedule.fetchEclassDDLEventsForPreflight()
        }) {
            let now = Date()
            let cache = await dependencies.loadScheduleCache()
            let retentionDays = min(max(cache.ddlAfterDay, 0), 30)
            let threshold = now.addingTimeInterval(TimeInterval(-retentionDays * 24 * 3600))
            eclassDDL = EclassDDLAudit(nativeAuthenticationVerified: nativeEclass != nil,
                courseCount: eclass.courseCount, activityCount: eclass.activityCount,
                activityTypes: eclass.activityTypes, deadlineCount: eclass.events.count,
                upcomingDeadlineCount: eclass.events.filter { $0.dueAt >= now }.count,
                recentDeadlineCount: eclass.events.filter { $0.dueAt >= now.addingTimeInterval(-7 * 24 * 3600) }.count,
                homeworkWithoutDeadlineCount: eclass.homeworkWithoutDeadlineCount,
                retentionDays: retentionDays, visibleDeadlineCount: eclass.events.filter { $0.dueAt >= threshold }.count,
                cachedEclassCount: cache.ddlEvents.filter { $0.group == "eclass" }.count,
                earliestDeadline: eclass.events.first?.dueAt, latestDeadline: eclass.events.last?.dueAt)
        }
        let calendarURL = await probe("乐学日历订阅地址", area: .ddl, scope: scope) {
            if let handler = self.schoolSMSHandler { return try await schedule.refreshLexueCalendarURL(schoolSMSCodeHandler: handler) }
            return try await schedule.refreshLexueCalendarURLForPreflight()
        }
        if let calendarURL {
            _ = await probe("乐学 DDL 下载", area: .ddl, scope: scope) {
                try await schedule.syncDDLEventsForPreflight(
                    existingEvents: [],
                    storedURL: calendarURL
                )
            }
        } else {
            recordSkip("乐学 DDL 下载", "日历订阅地址探针没有可用数据", area: .ddl, scope: scope)
        }

        // 成绩页与可信成绩单同属学校网络链路；短信二次验证时记录为 AUTH_BLOCKED，
        // 区分认证阻塞与网络故障。
        let scoreChallenge = await probe("成绩认证接口", area: .school, scope: scope) {
            do { return try await scoreService.startScoreChallenge() }
            catch ScoreServiceError.secondFactorRequired(let challenge) {
                guard let handler = self.schoolSMSHandler else { throw ScoreServiceError.secondFactorRequired(challenge) }
                let code = try await handler(SchoolSMSCodeRequest(maskedPhone: challenge.maskedPhone ?? "", purpose: "jwb"))
                return try await scoreService.submitScoreSMSCode(code, for: challenge)
            }
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
                    try await self.fetchAppStoreLookup()
                }
            },
            {
                _ = await self.probe("紧急更新配置接口", area: .bit101, scope: scope) {
                    try await self.fetchEmergencyUpdateConfiguration()
                }
            },
            {
                _ = await self.probe("feedback.aihelpme.dev 写入恢复", area: .bit101, scope: scope) {
                    try await self.dependencies.feedbackProbe(runID)
                }
            }
        ])

        return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
    }

    private func finishReport(runID: String, scope: NetworkSmokeScope, startedAt: Date) async -> ReleaseNetworkSmokeReport {
        let missingSMSPurposes = scope.requiredSMSPurposes.subtracting(verifiedSMSProbes.map(\.purpose))
        if schoolSMSHandler != nil {
            coverageGaps += missingSMSPurposes.sorted().map { "短信专项需要完成认证与业务继续：" + $0 }
        }
        for name in scope.requiredProbes where !executedProbes.contains(name) {
            if !coverageGaps.contains(where: { $0.hasPrefix(name + "（") }) {
                coverageGaps.append("必需探针缺失：" + name)
            }
        }

        let schoolSMSCoverage: String
        if schoolSMSHandler != nil {
            schoolSMSCoverage = smsSubmissions > 0 && missingSMSPurposes.isEmpty && failures.isEmpty && authenticationBlockers.isEmpty ? "verified" : "pending"
        } else { switch scope {
        case .all, .school, .ddl:
            schoolSMSCoverage = "preflight_only"
        default:
            schoolSMSCoverage = "not_run"
        } }
        var report = ReleaseNetworkSmokeReport(
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
        report.eclassDDL = eclassDDL
        report.requiredProbes = scope.requiredProbes
        report.verifiedSMSProbes = verifiedSMSProbes
        report.communityWriteEvidence = communityWriteEvidence
        do {
            try dependencies.writeReport(report)
        } catch {
            report.passed = false
            report.failures.append("网络 Smoke 报告写入失败：" + ErrorReportRedactor.sanitized(error.localizedDescription))
            FileHandle.standardOutput.write(Data("NETWORK_SMOKE_REPORT_WRITE_FAIL run_id=\(runID) error=\(ErrorReportRedactor.sanitized(error.localizedDescription))\n".utf8))
        }
        print(report.summaryLine)
        if !report.passed { print(report.failureMessage) }
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

    nonisolated static func validateCourseSyncPayload(_ payload: CourseSyncPayload) throws {
        guard payload.courses.allSatisfy(\.hasValidPlacement) else { throw URLError(.cannotParseResponse) }
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
        else { throw URLError(.cannotParseResponse) }
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
        guard value.count == 10, parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        guard let date = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: parts[0],
            month: parts[1],
            day: parts[2]
        )) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == parts[0], resolved.month == parts[1], resolved.day == parts[2] else { return nil }
        return date
    }

    static func freshEclassService() throws -> ScheduleService {
        guard let cookies = URLSessionConfiguration.ephemeral.httpCookieStorage else {
            throw ScheduleServiceError.invalidResponse
        }
        let copySchoolSession: @MainActor @Sendable () -> Void = {
            for cookie in AppSchoolSession.teachingCenter.cookieStorage.cookies ?? []
                where cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == "sso.bit.edu.cn" {
                cookies.setCookie(cookie)
            }
        }
        copySchoolSession()
        let restorer = AppScheduleSchoolSessionRestorer {
            let studentID = try await LoginService().restoreSchoolSessionIfNeeded()
            copySchoolSession()
            return studentID
        }
        return ScheduleService(credentials: AppAccountSession.storage, crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: restorer, teachingCenterState: TeachingCenterSessionState(cookieStorage: cookies),
            transport: NetworkSessionPool.teachingCenter(cookieStorage: cookies),
            observer: HTTPClient.appObserver)
    }

    private func probe<Value>(
        _ name: String,
        area: NetworkSmokeArea,
        scope: NetworkSmokeScope,
        operation: () async throws -> Value
    ) async -> Value? {
        guard scope.includes(area) else { return nil }
        executedProbes.append(name)
        let startedAt = Date()
        let smsStart = submittedSMSPurposes.count
        do {
            let value = try await operationWithSchoolAuthentication(operation)
            verifiedSMSProbes += submittedSMSPurposes.dropFirst(smsStart).map { SchoolSMSProbeEvidence(purpose: $0, probe: name) }
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

    private func operationWithSchoolAuthentication<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do { return try await operation() }
        catch ScheduleServiceError.secondFactorRequired(let challenge) {
            guard let handler = schoolSMSHandler, let schedule = schoolSMSSchedule else {
                throw ScheduleServiceError.secondFactorRequired(challenge)
            }
            let code = try await handler(SchoolSMSCodeRequest(maskedPhone: challenge.maskedPhone ?? "", purpose: "webvpn"))
            try await schedule.submitSMSCodeForTeachingCenterAuthentication(code, for: challenge)
            return try await operation()
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
             ScheduleServiceError.eclassAuthenticationFailed,
             ScheduleServiceError.schoolSecondFactorRequired,
             ScoreServiceError.secondFactorRequired:
            return true
        default:
            return false
        }
    }

    private func fetchDataCount(urlString: String) async throws -> Int {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        return try await fetch(url).count
    }

    private func fetchImageCount(urlString: String) async throws -> Int {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let response = try await fetchResponse(url, maximumBytes: RemoteImageResourceLimits.maximumEncodedBytes)
        try Self.validateImageData(response.data)
        return response.data.count
    }

    private nonisolated static func validateImageData(_ data: Data) throws {
        guard BoundedStillImageDecoder.image(from: data) != nil
        else {
            throw URLError(.cannotDecodeContentData)
        }
    }

    private func fetchHTMLCount(
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
        return try Self.validateHTMLResponse(
            response.data,
            finalURL: response.response.url,
            expectedHost: expectedHost,
            expectedPath: initialHost == nil ? url.path : "/gallery/",
            expectedAppURL: expectedHost == "open.aihelpme.dev" ? "bit101:/" + url.path : nil
        )
    }

    nonisolated static func validateHTMLResponse(
        _ data: Data,
        finalURL: URL?,
        expectedHost: String,
        expectedPath: String? = nil,
        expectedAppURL: String? = nil
    ) throws -> Int {
        guard finalURL?.host?.lowercased() == expectedHost else {
            throw URLError(.badServerResponse)
        }
        if let expectedPath,
           finalURL?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            throw URLError(.badServerResponse)
        }
        let body = String(decoding: data, as: UTF8.self).lowercased()
        if let expectedAppURL, !body.contains("href=\"\(expectedAppURL.lowercased())\"") {
            throw URLError(.cannotParseResponse)
        }
        guard body.contains("<html") || body.contains("<!doctype html") else {
            throw URLError(.cannotParseResponse)
        }
        return data.count
    }

    private nonisolated static let aasaURL = AppURL.required("https://open.aihelpme.dev/.well-known/apple-app-site-association")

    nonisolated static func validateAASA(_ response: HTTPResponse) throws -> Int {
        guard response.statusCode == 200, response.response.url == aasaURL,
              response.response.mimeType?.lowercased() == "application/json", response.data.count <= 128 * 1024,
              let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let appLinks = root["applinks"] as? [String: Any],
              let details = appLinks["details"] as? [[String: Any]],
              let entry = details.first(where: { $0["appID"] as? String == "Y2T72736G3.BIT101-dev.BIT101-iOS" }),
              let paths = entry["paths"] as? [String],
              paths.count == 3, Set(paths) == Set(["/gallery/*", "/course/*", "/paper/*"])
        else { throw URLError(.cannotParseResponse) }
        return paths.count
    }

    nonisolated static func validateAppStoreLookup(_ data: Data) throws -> Int {
        try AppStoreLookup.parse(data).count
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
            try Self.validateImageData(page)
        }
        return pages.count
    }

    private func fetchAppStoreLookup() async throws -> Int {
        let request = try AppStoreLookup.makeRequest()
        let response = try await dependencies.externalHTTPClient.send(request)
        guard AppURL.isSameOrigin(response.response.url, as: request.url) else {
            throw URLError(.badServerResponse)
        }
        return try Self.validateAppStoreLookup(response.data)
    }

    private func fetchEmergencyUpdateConfiguration() async throws -> Bool {
        let url = AppURL.required("https://update.aihelpme.dev/emergency-update.json")
        let response = try await fetchResponse(url)
        guard AppURL.isSameOrigin(response.response.url, as: url) else {
            throw URLError(.badServerResponse)
        }
        return try Self.validateEmergencyUpdateConfiguration(response.data)
    }

    private func fetch(_ url: URL) async throws -> Data {
        try await fetchResponse(url).data
    }

    private func fetchResponse(_ url: URL, maximumBytes: Int? = nil) async throws -> HTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("BIT101-iOS release network smoke", forHTTPHeaderField: "User-Agent")
        let response = try await self.dependencies.externalHTTPClient.send(request, accepting: 200 ..< 300, maximumBytes: maximumBytes)
        guard !response.data.isEmpty else { throw URLError(.zeroByteResource) }
        return response
    }

    private nonisolated static func duration(_ interval: TimeInterval) -> String {
        String(format: "%.2fs", interval)
    }
}

#endif
