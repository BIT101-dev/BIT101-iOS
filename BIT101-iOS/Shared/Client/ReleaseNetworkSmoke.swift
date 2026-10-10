import SchedulePorts
import ClientCore
import ScoreDomain
import ScorePorts
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
import ScheduleContracts
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
    private var productionSessionEvidence: [String] = []
    private var authenticationBlockers: [String] = []
    private var scheduleCache: ScheduleCacheAuditSnapshot?
    private var eclassDDL: EclassDDLAudit?
    private var executedProbes: [String] = []
    private var skippedProbes: [String] = []
    private var coverageGaps: [String] = []
    private var requestEvidence: [NetworkSmokeRequestEvidence] = []
    private var schoolSMSHandler: SchoolSMSCodeHandler?
    private var schoolSMSSchedule: (any NetworkSmokeScheduleServicing)?
    private var smsSubmissions = 0
    private var submittedSMSPurposes: [String] = []
    private var verifiedSMSProbes: [SchoolSMSProbeEvidence] = []
    private var authenticatedSchoolProbes: [SchoolSMSProbeEvidence] = []
    private var requestedSMSPurposes: [String] = []
    private var requestedScheduleTerm: String?
    private var currentScheduleTerm: String?
    private var validatedScheduleTerm: String?

    init(dependencies: ReleaseNetworkSmokeDependencies = .init()) { self.dependencies = dependencies }

    func run(
        scope: NetworkSmokeScope,
        runID: String = UUID().uuidString,
        capture: NetworkSmokeCapture = .none,
        term requestedTerm: String? = nil,
        communityFollowTarget: Int? = nil,
        communityExpectedAccount: Int? = nil,
        communityRecoveryConfirmation: CommunityWriteRecoveryConfirmation? = nil,
        fixtures: NetworkSmokeFixtures? = nil,
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
        productionSessionEvidence = []
        authenticationBlockers = []
        scheduleCache = nil
        eclassDDL = nil
        executedProbes = []
        skippedProbes = []
        coverageGaps = []
        requestEvidence = []
        smsSubmissions = 0
        submittedSMSPurposes = []
        verifiedSMSProbes = []
        authenticatedSchoolProbes = []
        requestedSMSPurposes = []
        let normalizedTerm = requestedTerm?.trimmingCharacters(in: .whitespacesAndNewlines)
        requestedScheduleTerm = normalizedTerm?.isEmpty == false ? normalizedTerm : nil
        currentScheduleTerm = nil
        validatedScheduleTerm = nil
        if let handler = schoolSMSCodeHandler {
            schoolSMSHandler = { [weak self] request in
                self?.requestedSMSPurposes.append(request.purpose)
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
                let area: NetworkSmokeArea = scope.includes(.authentication) ? .authentication : scope.includes(.schedule) ? .schedule : scope.includes(.ddl) ? .ddl : .transcript
                recordFailure("原始课表采样清理", error.localizedDescription, area: area, scope: scope)
                return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
            }
        }

        if scope.includes(.authentication) {
            executedProbes.append("BIT101 登录状态")
            let loginStartedAt = Date()
            do {
                let loginResult = try await captureNetworkRequests("BIT101 登录状态", required: true) {
                    try await self.dependencies.checkLogin()
                }
                guard let signedInStudentID = loginResult, !signedInStudentID.isEmpty else {
                    recordFailure("BIT101 登录状态", "真机没有有效登录状态，无法执行发布前网络冒烟测试", area: .authentication, scope: scope)
                    return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
                }
                print("NETWORK_SMOKE_PASS name=BIT101 登录状态 elapsed=\(Self.duration(Date().timeIntervalSince(loginStartedAt)))")
            } catch {
                recordFailure("BIT101 登录状态", error.localizedDescription, area: .authentication, scope: scope, elapsed: Date().timeIntervalSince(loginStartedAt))
                return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
            }
        }

        if scope == .communityWrites || scope == .communityCleanup {
            communityWriteEvidence = await probe("社区写入与清理", area: .communityWrites, scope: scope) {
                try await self.dependencies.communityWriteProbe(runID, scope == .communityCleanup, communityFollowTarget, communityExpectedAccount, fixtures, communityRecoveryConfirmation)
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
                    request.setValue("https://bit101.cn", forHTTPHeaderField: "Origin")
                    request.setValue("POST", forHTTPHeaderField: "Access-Control-Request-Method")
                    request.setValue("content-type", forHTTPHeaderField: "Access-Control-Request-Headers")
                    let response = try await self.dependencies.externalHTTPClient.send(request, accepting: 200..<300)
                    let methods = Set((response.response.value(forHTTPHeaderField: "Access-Control-Allow-Methods") ?? "")
                        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
                    let headers = Set((response.response.value(forHTTPHeaderField: "Access-Control-Allow-Headers") ?? "")
                        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                    guard response.response.statusCode == 204, response.data.isEmpty,
                          response.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*",
                          methods.contains("POST"), headers.contains("content-type")
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
        _ = await probe("话廊最新列表", area: .bit101, scope: scope) {
            try await NetworkSmokePaging.batch(currentIdentity: self.dependencies.communityIdentity) { try await gallery.fetchFeed(kind: .newest, page: $0 == 0 ? nil : $0) }.items
        }
        let validatedFixtures = fixtures.flatMap { $0.isValid ? $0 : nil }
        if let fixture = validatedFixtures {
            await runInParallel([
                {
                    let detail = await self.probe("话廊帖子详情", area: .bit101, scope: scope, expectedParameters: ["path": "/posters/\(fixture.posterID)"]) {
                        let detail = try await gallery.fetchPoster(id: fixture.posterID)
                        try Self.validateEntityIdentity(expected: fixture.posterID, actual: detail.id)
                        return detail
                    }
                    if let detail {
                        _ = await self.probe("话廊图片下载", area: .bit101, scope: scope) {
                            guard let imageURL = NetworkSmokePaging.imageURL(in: detail.images)
                            else { throw URLError(.resourceUnavailable) }
                            return try await self.fetchImageCount(urlString: imageURL)
                        }
                    } else {
                        self.recordSkip("话廊图片下载", "维护帖子详情读取失败", area: .bit101, scope: scope)
                    }
                },
                {
                    let objectID = "poster\(fixture.posterID)"
                    _ = await self.probe("话廊帖子评论", area: .bit101, scope: scope, expectedParameters: ["obj": objectID]) {
                        try await NetworkSmokePaging.batch(currentIdentity: self.dependencies.communityIdentity) {
                            let batch = try await gallery.fetchComments(objectID: objectID, order: .newest, page: $0 == 0 ? nil : $0)
                            try NetworkSmokePaging.checkComments(batch.items, for: objectID)
                            return batch
                        }
                    }
                }
            ])
            _ = await probe("话廊网页详情", area: .bit101, scope: scope, expectedParameters: ["path": "/gallery/\(fixture.posterID)"]) {
                try await self.fetchHTMLCount(
                    urlString: "https://open.aihelpme.dev/gallery/\(fixture.posterID)",
                    expectedHost: "open.aihelpme.dev"
                )
            }
        } else {
            let reason = "社区详情验收需要有效的维护对象配置 BIT101_NETWORK_SMOKE_FIXTURES"
            recordSkip("话廊帖子详情", reason, area: .bit101, scope: scope)
            recordSkip("话廊帖子评论", reason, area: .bit101, scope: scope)
            recordSkip("话廊网页详情", reason, area: .bit101, scope: scope)
            recordSkip("话廊图片下载", reason, area: .bit101, scope: scope)
        }
        var galleryOperations: [@MainActor () async -> Void] = [
            { _ = await self.probe("话廊关注流", area: .bit101, scope: scope) { try await NetworkSmokePaging.batch(currentIdentity: self.dependencies.communityIdentity) { try await gallery.fetchFeed(kind: .follow, page: $0 == 0 ? nil : $0) } } },
            { _ = await self.probe("话廊热门流", area: .bit101, scope: scope) { try await NetworkSmokePaging.batch(currentIdentity: self.dependencies.communityIdentity) { try await gallery.fetchFeed(kind: .hot, page: $0 == 0 ? nil : $0) } } },
            { _ = await self.probe("话廊推荐流", area: .bit101, scope: scope) { try await NetworkSmokePaging.batch(currentIdentity: self.dependencies.communityIdentity) { try await gallery.fetchRecommendPage(sourcePage: $0) } } },
            { _ = await self.probe("话廊机器人流", area: .bit101, scope: scope) {
                try await NetworkSmokePaging.batch(currentIdentity: self.dependencies.communityIdentity) {
                    let batch = try await gallery.fetchBotFeed(startPage: $0)
                    try NetworkSmokePaging.checkBotPosters(batch.items)
                    return batch
                }
            } },
            { _ = await self.probe("社区举报类型", area: .bit101, scope: scope) { try await gallery.fetchReportTypes() } },
            { _ = await self.probe("帖子声明列表", area: .bit101, scope: scope) { try await gallery.fetchClaims() } },
            {
                _ = await self.probe("话廊搜索", area: .bit101, scope: scope) {
                    try await NetworkSmokePaging.batch(currentIdentity: self.dependencies.communityIdentity) { try await gallery.searchPosters(query: GallerySearchQuery(text: "BIT101"), page: $0) }
                }
            },
            { _ = await self.probe("消息未读数", area: .bit101, scope: scope) { try await gallery.fetchMessageUnreadCounts() } }
        ]
        for messageType in GalleryMessageType.allCases {
            galleryOperations.append { [messageType] in
                _ = await self.probe("消息列表-\(messageType.rawValue)", area: .bit101, scope: scope) {
                    try await NetworkSmokePaging.messages(currentIdentity: self.dependencies.communityIdentity) { try await gallery.fetchMessages(type: messageType, lastID: $0) }
                }
            }
        }
        await runInParallel(galleryOperations)

        _ = await probe("学业课程列表", area: .bit101, scope: scope) {
            try await NetworkSmokePaging.arrayPage(requiresContent: validatedFixtures != nil, currentIdentity: self.dependencies.communityIdentity) { try await courses.fetchCourses(search: "", page: $0) }
        }
        if let fixture = validatedFixtures {
            await runInParallel([
                {
                    _ = await self.probe("学业课程详情", area: .bit101, scope: scope, expectedParameters: ["path": "/courses/\(fixture.courseID)"]) {
                        let detail = try await courses.fetchCourse(id: fixture.courseID)
                        try Self.validateEntityIdentity(expected: fixture.courseID, actual: detail.id)
                        guard detail.number == fixture.courseNumber else { throw URLError(.badServerResponse) }
                        return detail
                    }
                },
                {
                    let objectID = "course\(fixture.courseID)"
                    _ = await self.probe("学业课程评论", area: .bit101, scope: scope, expectedParameters: ["obj": objectID]) {
                        try await NetworkSmokePaging.arrayPage(currentIdentity: self.dependencies.communityIdentity) {
                            let comments = try await courses.fetchComments(courseID: fixture.courseID, page: $0 == 0 ? nil : $0)
                            try NetworkSmokePaging.checkComments(comments, for: objectID)
                            return comments
                        }
                    }
                },
                {
                    _ = await self.probe("学业课程历史成绩", area: .bit101, scope: scope, expectedParameters: ["path": "/courses/histories/\(fixture.courseNumber)"]) {
                        try await courses.fetchCourseHistories(number: fixture.courseNumber)
                    }
                },
                {
                    _ = await self.probe("学业课程网页详情", area: .bit101, scope: scope, expectedParameters: ["path": "/course/\(fixture.courseID)"]) {
                        try await self.fetchHTMLCount(
                            urlString: "https://open.aihelpme.dev/course/\(fixture.courseID)",
                            expectedHost: "open.aihelpme.dev"
                        )
                    }
                }
            ])
        } else {
            let reason = "社区详情验收需要有效的维护对象配置 BIT101_NETWORK_SMOKE_FIXTURES"
            recordSkip("学业课程详情", reason, area: .bit101, scope: scope)
            recordSkip("学业课程评论", reason, area: .bit101, scope: scope)
            recordSkip("学业课程历史成绩", reason, area: .bit101, scope: scope)
            recordSkip("学业课程网页详情", reason, area: .bit101, scope: scope)
        }

        let papers = dependencies.makePapers()
        _ = await probe("文章列表", area: .bit101, scope: scope) {
            try await NetworkSmokePaging.arrayPage(requiresContent: validatedFixtures != nil, currentIdentity: self.dependencies.communityIdentity) { try await papers.fetchPapers(search: nil, order: .newest, page: $0) }
        }
        if let fixture = validatedFixtures {
            await runInParallel([
                {
                    let detail = await self.probe("文章详情", area: .bit101, scope: scope, expectedParameters: ["path": "/papers/\(fixture.paperID)"]) {
                        _ = try await papers.fetchPreviewMetadata(id: fixture.paperID)
                        let detail = try await papers.fetchPaper(id: fixture.paperID)
                        try Self.validateEntityIdentity(expected: fixture.paperID, actual: detail.id)
                        _ = try NetworkSmokePaging.checkPaperContent(detail.content)
                        return detail
                    }
                    if let detail {
                        _ = await self.probe("文章正文图片下载", area: .bit101, scope: scope) {
                            for url in try NetworkSmokePaging.checkPaperContent(detail.content) {
                                _ = try await self.fetchImageCount(urlString: url)
                            }
                        }
                    } else {
                        self.recordSkip("文章正文图片下载", "文章正文探针需要可渲染的维护对象", area: .bit101, scope: scope)
                    }
                },
                {
                    let objectID = "paper\(fixture.paperID)"
                    _ = await self.probe("文章评论", area: .bit101, scope: scope, expectedParameters: ["obj": objectID]) {
                        try await NetworkSmokePaging.arrayPage(currentIdentity: self.dependencies.communityIdentity) {
                            let comments = try await papers.fetchComments(paperID: fixture.paperID, order: .newest, page: $0 == 0 ? nil : $0)
                            try NetworkSmokePaging.checkComments(comments, for: objectID)
                            return comments
                        }
                    }
                },
                {
                    _ = await self.probe("文章网页详情", area: .bit101, scope: scope, expectedParameters: ["path": "/paper/\(fixture.paperID)"]) {
                        try await self.fetchHTMLCount(urlString: "https://open.aihelpme.dev/paper/\(fixture.paperID)",
                                                     expectedHost: "open.aihelpme.dev")
                    }
                }
            ])
        } else {
            let reason = "社区详情验收需要有效的维护对象配置 BIT101_NETWORK_SMOKE_FIXTURES"
            recordSkip("文章详情", reason, area: .bit101, scope: scope)
            recordSkip("文章正文图片下载", reason, area: .bit101, scope: scope)
            recordSkip("文章评论", reason, area: .bit101, scope: scope)
            recordSkip("文章网页详情", reason, area: .bit101, scope: scope)
        }
        await runInParallel(PaperSortOrder.allCases.map { order in
            {
                _ = await self.probe("文章列表-\(order.title)", area: .bit101, scope: scope) {
                    let sample = try await NetworkSmokePaging.arrayPage(currentIdentity: self.dependencies.communityIdentity) {
                        let page = try await papers.fetchPapers(search: "BIT101", order: order, page: $0)
                        try NetworkSmokePaging.checkPapers(page, order: order)
                        return page
                    }
                    try NetworkSmokePaging.checkPapers(sample, order: order)
                    return sample
                }
            }
        })

        let mine = dependencies.makeMine()
        productionSessionEvidence = await probe("生产共享会话", area: .bit101, scope: scope) {
            try await self.dependencies.productionSessionProbe()
        } ?? []
        let myInfo = await probe("我的资料", area: .bit101, scope: scope) { try await mine.fetchMyInfo() }
        await runInParallel([
            { _ = await self.probe("我的关注", area: .bit101, scope: scope) { try await NetworkSmokePaging.arrayPage(currentIdentity: self.dependencies.communityIdentity) { try await mine.fetchFollowings(page: $0) } } },
            { _ = await self.probe("我的粉丝", area: .bit101, scope: scope) { try await NetworkSmokePaging.arrayPage(currentIdentity: self.dependencies.communityIdentity) { try await mine.fetchFollowers(page: $0) } } }
        ])
        if let myInfo {
            await runInParallel([
                {
                    _ = await self.probe("我的帖子", area: .bit101, scope: scope, expectedParameters: ["uid": "0"]) {
                        try await NetworkSmokePaging.arrayPage(currentIdentity: self.dependencies.communityIdentity) {
                            let posters = try await mine.fetchMyPosters(page: $0)
                            try NetworkSmokePaging.checkPosters(posters, for: myInfo.user.id)
                            return posters
                        }
                    }
                },
                {
                    _ = await self.probe("用户资料详情", area: .bit101, scope: scope, expectedParameters: ["path": "/user/info/\(myInfo.user.id)"]) { let detail = try await mine.fetchUserInfo(id: myInfo.user.id); try Self.validateEntityIdentity(expected: myInfo.user.id, actual: detail.user.id); return detail }
                },
                {
                    _ = await self.probe("用户帖子", area: .bit101, scope: scope, expectedParameters: ["uid": String(myInfo.user.id)]) {
                        try await NetworkSmokePaging.arrayPage(currentIdentity: self.dependencies.communityIdentity) {
                            let posters = try await mine.fetchUserPosters(userID: myInfo.user.id, page: $0)
                            try NetworkSmokePaging.checkPosters(posters, for: myInfo.user.id)
                            return posters
                        }
                    }
                }
            ])
        } else {
            recordSkip("我的帖子", "资料探针没有可用数据", area: .bit101, scope: scope)
            recordSkip("用户资料详情", "资料探针没有可用数据", area: .bit101, scope: scope)
            recordSkip("用户帖子", "资料探针没有可用数据", area: .bit101, scope: scope)
        }

        // 可信成绩单探针位于学校相关探针的首段，模拟用户手动点击“申请可信成绩单”的路径。
        let transcriptService = dependencies.makeScores()
        _ = await probe("可信成绩单接口", area: .transcript, scope: scope) {
            let pages: [Data]
            do { pages = try await transcriptService.fetchTrustedTranscriptPages() }
            catch ScoreServiceError.secondFactorRequired(let challenge) {
                guard let handler = self.schoolSMSHandler else { throw ScoreServiceError.secondFactorRequired(challenge) }
                let code = try await handler(SchoolSMSCodeRequest(maskedPhone: challenge.maskedPhone ?? "", purpose: "jwb_cjd"))
                pages = try await transcriptService.submitTranscriptSMSCode(code, for: challenge)
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
        let productionSchedule = dependencies.makeProductionSchedule()
        schoolSMSSchedule = productionSchedule
        _ = await probe("生产学校会话", area: .schedule, scope: scope) { try await productionSchedule.fetchCurrentTermOnly() }
        schoolSMSSchedule = schedule
        _ = await probe("教学中心接口预热", area: .schedule, scope: scope) { try await schedule.prepareTeachingCenterAccess() }
        let currentTerm = await probe("当前学期", area: .schedule, scope: scope) { try await schedule.fetchCurrentTermOnly() }
        currentScheduleTerm = currentTerm
        _ = await probe("切换学期列表", area: .schedule, scope: scope) {
            try await schedule.fetchAvailableTerms()
        }
        let term = requestedScheduleTerm ?? currentTerm
        if let term {
            let syncPayload = await probe("课表、考试与首周同步", area: .schedule, scope: scope, expectedParameters: ["XNXQDM": term]) {
                let payload = try await schedule.syncCourses(term: term)
                guard payload.term == term else { throw URLError(.badServerResponse) }
                try Self.validateCourseSyncPayload(payload)
                return payload
            }
            validatedScheduleTerm = syncPayload?.term
            if capture == .scheduleCache, let syncPayload {
                scheduleCache = captureScheduleCache(from: syncPayload)
            }

            let campuses = await probe("空教室校区列表", area: .schedule, scope: scope) {
                try await schedule.fetchCampuses()
            }
            if let campus = campuses?.first {
                let buildings = await probe("空教室教学楼列表", area: .schedule, scope: scope, expectedParameters: ["XXXQDM": campus.code]) {
                    let buildings = try await schedule.fetchBuildings(campusCode: campus.code)
                    try NetworkSmokePaging.checkBuildings(buildings, campusCode: campus.code)
                    return buildings
                }
                if let building = buildings?.first {
                    _ = await probe("空教室占用数据", area: .schedule, scope: scope, expectedParameters: ["XNXQDM": term, "JXLDM": building.id]) {
                        let classrooms = try await schedule.fetchClassrooms(buildingID: building.id, term: term)
                        guard classrooms.allSatisfy(\.hasValidOccupancy) else { throw URLError(.cannotParseResponse) }
                        return classrooms
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
        let scoreService = dependencies.makeScores()
        let scoreChallenge = await probe("成绩认证接口", area: .school, scope: scope) {
            do { return try await scoreService.startScoreChallenge() }
            catch ScoreServiceError.secondFactorRequired(let challenge) {
                guard let handler = self.schoolSMSHandler else { throw ScoreServiceError.secondFactorRequired(challenge) }
                let code = try await handler(SchoolSMSCodeRequest(maskedPhone: challenge.maskedPhone ?? "", purpose: "jwb"))
                return try await scoreService.submitScoreSMSCode(code, for: challenge)
            }
        }
        if let scoreChallenge {
            let briefScores = await probe("成绩简略列表", area: .school, scope: scope) {
                try await scoreService.fetchScores(detail: false, authenticatedBy: scoreChallenge)
            }
            _ = await probe("成绩详细列表", area: .school, scope: scope) {
                let detailed = try await scoreService.fetchScores(detail: true, authenticatedBy: scoreChallenge)
                guard let briefScores else { throw URLError(.cannotParseResponse) }
                try NetworkSmokePaging.checkScores(brief: briefScores, detailed: detailed)
                return detailed
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
        let missingSMSPurposes = scope.requiredSMSPurposes.subtracting(authenticatedSchoolProbes.map(\.purpose))
            .union(Set(requestedSMSPurposes).subtracting(verifiedSMSProbes.map(\.purpose)))
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
            schoolSMSCoverage = missingSMSPurposes.isEmpty && failures.isEmpty && authenticationBlockers.isEmpty
                ? (smsSubmissions > 0 ? "verified" : "not_required") : "pending"
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
        report.authenticatedSchoolProbes = authenticatedSchoolProbes
        report.requestedSMSPurposes = requestedSMSPurposes
        report.communityWriteEvidence = communityWriteEvidence
        report.productionSessionEvidence = productionSessionEvidence
        report.requestedTerm = requestedScheduleTerm
        report.currentTerm = currentScheduleTerm
        report.validatedTerm = validatedScheduleTerm
        report.requestEvidence = requestEvidence
        report.requestEvidenceRequired = dependencies.requiresRequestEvidence
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

    static func freshEclassService() throws -> ScheduleService {
        freshSchoolService(rawCourseResponseHandler: nil)
    }

    static func freshScoreService() -> ScoreService {
        ScoreService(authenticationHTTPClient: HTTPClient(transport: NetworkSessionPool.schoolCASTransport(
            state: AppSchoolSession.isolatedState(), followsRedirects: true)))
    }

    static func freshSchoolService(rawCourseResponseHandler: ((Data) -> Void)?) -> ScheduleService {
        let state = AppSchoolSession.isolatedState()
        let api = BIT101APIClient(
            httpClient: HTTPClient(transport: NetworkSessionPool.schoolCASTransport(state: state, followsRedirects: true)),
            noRedirectHTTPClient: HTTPClient(transport: NetworkSessionPool.schoolCASTransport(state: state, followsRedirects: false)))
        let restorer = AppScheduleSchoolSessionRestorer { try await LoginService(apiClient: api).restoreSchoolSessionIfNeeded() }
        return ScheduleService(credentials: AppAccountSession.storage, crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: restorer, teachingCenterState: state, rawCourseResponseHandler: rawCourseResponseHandler,
            transport: NetworkSessionPool.teachingCenter(state: state),
            observer: HTTPClient.appObserver)
    }

    private func probe<Value>(
        _ name: String,
        area: NetworkSmokeArea,
        scope: NetworkSmokeScope,
        expectedParameters: [String: String] = [:],
        operation: () async throws -> Value
    ) async -> Value? {
        guard scope.includes(area) else { return nil }
        executedProbes.append(name)
        let startedAt = Date()
        let smsStart = submittedSMSPurposes.count
        do {
            let value = try await captureNetworkRequests(name, required: scope != .communityCleanup, expectedParameters: expectedParameters) {
                try await self.operationWithSchoolAuthentication(operation)
            }
            verifiedSMSProbes += submittedSMSPurposes.dropFirst(smsStart).map { SchoolSMSProbeEvidence(purpose: $0, probe: name) }
            let canonicalPurposes = ["当前学期": "webvpn", "生产学校会话": "webvpn", "乐学日历订阅地址": "webvpn",
                "课程中心原生认证": "school_sso_second_factor", "成绩认证接口": "jwb", "可信成绩单接口": "jwb_cjd"]
            let purposes = Set(submittedSMSPurposes.dropFirst(smsStart)).union(canonicalPurposes[name].map { [$0] } ?? [])
            for purpose in purposes where !authenticatedSchoolProbes.contains(where: { $0.purpose == purpose }) {
                authenticatedSchoolProbes.append(SchoolSMSProbeEvidence(purpose: purpose, probe: name))
            }
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

    private func captureNetworkRequests<Value>(
        _ name: String, required: Bool, expectedParameters: [String: String] = [:], operation: () async throws -> Value
    ) async throws -> Value {
        let collector = NetworkSmokeRequestCollector()
        defer { requestEvidence.append(NetworkSmokeRequestEvidence(probe: name, requests: collector.requests, expectedParameters: expectedParameters)) }
        return try await collector.perform(operation, required: required && dependencies.requiresRequestEvidence, expectedParameters: expectedParameters)
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
        return try await dependencies.imageProbe(url)
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

    nonisolated static func validateEntityIdentity(expected: Int, actual: Int) throws {
        guard expected > 0, actual == expected else { throw URLError(.badServerResponse) }
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
        try NetworkSmokeHTML.validate(String(decoding: data, as: UTF8.self), appURL: expectedAppURL)
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
        var request = URLRequest(url: HTTPSURLUpgrade.upgradedURL(from: url), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
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
