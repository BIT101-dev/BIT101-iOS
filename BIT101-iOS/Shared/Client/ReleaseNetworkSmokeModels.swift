import StorageCore
import TransportCore
import SchedulePorts
import ScheduleDomain
import MineFeature
import CommunityCore
import CommunityTransport
import PaperFeature
import ScheduleContracts
import ScheduleSharedStore
import Foundation
import OSLog
import ClientCore
import GalleryFeature
import CourseFeature
import ScoreDomain
import ScorePorts
import ScoreInfrastructure
import ScheduleInfrastructure
import MediaKit

enum NetworkSmokeScope: String, Codable, CaseIterable, Sendable {
    case all
    case bit101
    case school
    case transcript
    case schedule
    case ddl
    case communityWrites = "community-writes"
    case communityCleanup = "community-cleanup"

    func includes(_ area: NetworkSmokeArea) -> Bool {
        switch self {
        case .all:
            return area == .authentication || area == .bit101 || area == .schedule
                || area == .ddl || area == .school || area == .transcript
        case .bit101:
            return area == .authentication || area == .bit101
        case .school:
            return area == .schedule
                || area == .ddl
                || area == .school
                || area == .transcript
        case .transcript:
            return area == .transcript
        case .schedule:
            return area == .schedule
        case .ddl:
            return area == .ddl
        case .communityWrites:
            return area == .authentication || area == .communityWrites || area == .communityWriteImages
        case .communityCleanup:
            return area == .authentication || area == .communityWrites
        }
    }

    var requiredProbes: [String] {
        NetworkSmokeArea.allCases.filter(includes).flatMap(\.requiredProbes)
    }

    var requiredSMSPurposes: Set<String> {
        switch self {
        case .all, .school: ["jwb", "jwb_cjd", "webvpn", "school_sso_second_factor"]
        case .transcript: ["jwb_cjd"]
        case .schedule: ["webvpn"]
        case .ddl: ["webvpn", "school_sso_second_factor"]
        case .bit101, .communityWrites, .communityCleanup: []
        }
    }

}

enum NetworkSmokeProbe: String, CaseIterable, Sendable {
    case login = "community.login"
    case communityWrites = "community.writes"
    case homeRedirect = "web.home"
    case appAssociation = "web.association"
    case shareIcon = "web.share-icon"
    case feedbackPreflight = "feedback.preflight"
    case galleryNewest = "gallery.newest"
    case galleryFollowing = "gallery.following"
    case galleryHot = "gallery.hot"
    case galleryDetail = "gallery.detail"
    case galleryComments = "gallery.comments"
    case galleryImage = "gallery.image"
    case galleryWeb = "gallery.web"
    case galleryRecommend = "gallery.recommend"
    case galleryBots = "gallery.bots"
    case galleryClaims = "gallery.claims"
    case gallerySubscriptions = "gallery.subscriptions"
    case reportTypes = "community.report-types"
    case productionSession = "community.session"
    case gallerySearch = "gallery.search"
    case messageUnread = "message.unread"
    case courseList = "course.list"
    case courseSearch = "course.search"
    case courseDetail = "course.detail"
    case courseComments = "course.comments"
    case courseHistory = "course.history"
    case courseWeb = "course.web"
    case paperList = "paper.list"
    case paperSearch = "paper.search"
    case paperDetail = "paper.detail"
    case paperImage = "paper.image"
    case paperComments = "paper.comments"
    case paperWeb = "paper.web"
    case myProfile = "profile.mine"
    case myFollowing = "profile.following"
    case myFollowers = "profile.followers"
    case myPosts = "profile.posts"
    case userProfile = "user.profile"
    case userPosts = "user.posts"
    case appStoreUpdate = "update.app-store"
    case emergencyUpdate = "update.emergency"
    case feedbackRecovery = "feedback.recovery"
    case currentTerm = "schedule.current-term"
    case teachingCenter = "schedule.teaching-center"
    case schoolSession = "school.session"
    case termList = "schedule.terms"
    case scheduleSync = "schedule.sync"
    case classroomCampuses = "classroom.campuses"
    case classroomBuildings = "classroom.buildings"
    case classroomOccupancy = "classroom.occupancy"
    case eclassAuthentication = "eclass.authentication"
    case eclassDDL = "eclass.ddl"
    case lexueCalendar = "lexue.calendar"
    case lexueDDL = "lexue.ddl"
    case scoreAuthentication = "score.authentication"
    case scoreBrief = "score.brief"
    case scoreDetail = "score.detail"
    case transcript = "score.transcript"
    case messageComment = "message.comment"
    case messageLike = "message.like"
    case messageFollow = "message.follow"
    case messageSystem = "message.system"
    case messageSubscription = "message.subscription"
    case paperNewest = "paper.list.newest"
    case paperLikes = "paper.list.like"
    case paperCommentSort = "paper.list.comment"

    var requiresCommunitySession: Bool {
        switch self {
        case .communityWrites, .galleryNewest, .galleryFollowing, .galleryHot, .galleryDetail, .galleryComments, .galleryImage,
             .galleryRecommend, .galleryBots, .galleryClaims, .gallerySubscriptions, .reportTypes, .productionSession, .gallerySearch,
             .messageUnread, .messageComment, .messageLike, .messageFollow, .messageSystem, .messageSubscription,
             .courseList, .courseSearch, .courseDetail, .courseComments, .courseHistory,
             .paperList, .paperSearch, .paperDetail, .paperImage, .paperComments, .paperNewest, .paperLikes, .paperCommentSort,
             .myProfile, .myFollowing, .myFollowers, .myPosts, .userProfile, .userPosts: true
        default: false
        }
    }

    var displayName: String {
        switch self {
        case .login: "BIT101 登录状态"
        case .communityWrites: "社区写入与清理"
        case .homeRedirect: "open.aihelpme.dev 首页跳转"
        case .appAssociation: "App 链接关联配置"
        case .shareIcon: "分享图标下载"
        case .feedbackPreflight: "反馈接口跨域预检"
        case .galleryNewest: "话廊最新列表"
        case .galleryFollowing: "话廊关注流"
        case .galleryHot: "话廊热门流"
        case .galleryDetail: "话廊帖子详情"
        case .galleryComments: "话廊帖子评论"
        case .galleryImage: "话廊图片下载"
        case .galleryWeb: "话廊网页详情"
        case .galleryRecommend: "话廊推荐流"
        case .galleryBots: "话廊机器人流"
        case .galleryClaims: "帖子声明列表"
        case .gallerySubscriptions: "话廊收藏列表"
        case .reportTypes: "社区举报类型"
        case .productionSession: "生产共享会话"
        case .gallerySearch: "话廊搜索"
        case .messageUnread: "消息未读数"
        case .courseList: "学业课程列表"
        case .courseSearch: "学业课程关键词搜索"
        case .courseDetail: "学业课程详情"
        case .courseComments: "学业课程评论"
        case .courseHistory: "学业课程历史成绩"
        case .courseWeb: "学业课程网页详情"
        case .paperList: "文章列表"
        case .paperSearch: "文章关键词搜索"
        case .paperDetail: "文章详情"
        case .paperImage: "文章正文图片下载"
        case .paperComments: "文章评论"
        case .paperWeb: "文章网页详情"
        case .myProfile: "我的资料"
        case .myFollowing: "我的关注"
        case .myFollowers: "我的粉丝"
        case .myPosts: "我的帖子"
        case .userProfile: "用户资料详情"
        case .userPosts: "用户帖子"
        case .appStoreUpdate: "App Store 更新接口"
        case .emergencyUpdate: "紧急更新配置接口"
        case .feedbackRecovery: "feedback.aihelpme.dev 写入恢复"
        case .currentTerm: "当前学期"
        case .teachingCenter: "教学中心接口预热"
        case .schoolSession: "生产学校会话"
        case .termList: "切换学期列表"
        case .scheduleSync: "课表、考试与首周同步"
        case .classroomCampuses: "空教室校区列表"
        case .classroomBuildings: "空教室教学楼列表"
        case .classroomOccupancy: "空教室占用数据"
        case .eclassAuthentication: "课程中心原生认证"
        case .eclassDDL: "课程中心 DDL 下载"
        case .lexueCalendar: "乐学日历订阅地址"
        case .lexueDDL: "乐学 DDL 下载"
        case .scoreAuthentication: "成绩认证接口"
        case .scoreBrief: "成绩简略列表"
        case .scoreDetail: "成绩详细列表"
        case .transcript: "可信成绩单接口"
        case .messageComment: "消息列表-comment"
        case .messageLike: "消息列表-like"
        case .messageFollow: "消息列表-follow"
        case .messageSystem: "消息列表-system"
        case .messageSubscription: "消息列表-subscription"
        case .paperNewest: "文章列表-最新"
        case .paperLikes: "文章列表-高赞"
        case .paperCommentSort: "文章列表-热评"
        }
    }

    static func message(_ type: GalleryMessageType) -> Self {
        switch type {
        case .comment: .messageComment
        case .like: .messageLike
        case .follow: .messageFollow
        case .system: .messageSystem
        case .subscription: .messageSubscription
        }
    }

    static func paperSort(_ order: PaperSortOrder) -> Self {
        switch order {
        case .newest: .paperNewest
        case .like: .paperLikes
        case .comment: .paperCommentSort
        }
    }
}

enum NetworkSmokeArea: CaseIterable, Hashable, Sendable {
    case authentication
    case bit101
    case schedule
    case ddl
    case school
    case transcript
    case communityWrites
    case communityWriteImages

    var probeKinds: [NetworkSmokeProbe] {
        switch self {
        case .authentication:
            [.login]
        case .communityWrites:
            [.communityWrites]
        case .communityWriteImages:
            [.galleryImage]
        case .bit101:
            [
                .homeRedirect,
                .appAssociation,
                .shareIcon,
                .feedbackPreflight,
                .galleryNewest,
                .galleryFollowing,
                .galleryHot,
                .galleryDetail,
                .galleryComments,
                .galleryImage,
                .galleryWeb,
                .galleryRecommend,
                .galleryBots,
                .galleryClaims,
                .gallerySubscriptions,
                .reportTypes,
                .productionSession,
                .gallerySearch,
                .messageUnread,
                .courseList,
                .courseSearch,
                .courseDetail,
                .courseComments,
                .courseHistory,
                .courseWeb,
                .paperList,
                .paperSearch,
                .paperDetail,
                .paperImage,
                .paperComments,
                .paperWeb,
                .myProfile,
                .myFollowing,
                .myFollowers,
                .myPosts,
                .userProfile,
                .userPosts,
                .appStoreUpdate,
                .emergencyUpdate,
                .feedbackRecovery,
            ] + GalleryMessageType.allCases.map(NetworkSmokeProbe.message)
                + PaperSortOrder.allCases.map(NetworkSmokeProbe.paperSort)
        case .schedule:
            [
                .currentTerm,
                .teachingCenter,
                .schoolSession,
                .termList,
                .scheduleSync,
                .classroomCampuses,
                .classroomBuildings,
                .classroomOccupancy,
            ]
        case .ddl:
            [
                .eclassAuthentication,
                .eclassDDL,
                .lexueCalendar,
                .lexueDDL,
            ]
        case .school:
            [
                .scoreAuthentication,
                .scoreBrief,
                .scoreDetail,
            ]
        case .transcript:
            [
                .transcript,
            ]
        }
    }


    var requiredProbes: [String] { probeKinds.map(\.rawValue) }

}

enum NetworkSmokeCapture: String, Codable, Sendable {
    case none
    case scheduleCache
    case rawCourseResponse
    case communityFixtures
}

struct ScheduleCacheAuditCourse: Codable, Sendable {
    let id: String
    let name: String
    let number: String
    let teacher: String
    let classroom: String
    let weeks: [Int]
    let weekday: Int
    let startSection: Int
    let endSection: Int
}

struct ScheduleCacheAuditSnapshot: Codable, Sendable {
    let currentTerm: String
    let firstDayString: String
    let sourceFirstDayString: String
    let normalizationOffset: Int
    let courseCount: Int
    let courses: [ScheduleCacheAuditCourse]
}

/// ReleaseNetworkSmokeReport 保存一次网络冒烟执行的结果。
struct EclassDDLAudit: Codable {
    let nativeAuthenticationVerified: Bool
    let courseCount: Int
    let activityCount: Int
    let activityTypes: [String: Int]
    let deadlineCount: Int
    let upcomingDeadlineCount: Int
    let recentDeadlineCount: Int
    let homeworkWithoutDeadlineCount: Int
    let retentionDays: Int
    let visibleDeadlineCount: Int
    let cachedEclassCount: Int
    let earliestDeadline: Date?
    let latestDeadline: Date?
}

struct SchoolSMSProbeEvidence: Codable {
    let purpose: String
    let probe: String
}

struct ReleaseNetworkSmokeReport: Codable {
    let runID: String
    let scope: NetworkSmokeScope
    let startedAt: Date
    let finishedAt: Date
    var passed: Bool
    var failures: [String]
    let authenticationBlockers: [String]
    let scheduleCache: ScheduleCacheAuditSnapshot?
    let executedProbes: [String]
    let skippedProbes: [String]
    let coverageGaps: [String]
    let schoolSMSCoverage: String
    var eclassDDL: EclassDDLAudit? = nil
    var requiredProbes: [String] = []
    var verifiedSMSProbes: [SchoolSMSProbeEvidence] = []
    var authenticatedSchoolProbes: [SchoolSMSProbeEvidence] = []
    var requestedSMSPurposes: [String] = []
    var communityWriteEvidence: [String] = []
    var productionSessionEvidence: [String] = []
    var communityConfiguration: NetworkSmokeCommunityConfiguration? = nil
    var requestedTerm: String? = nil
    var currentTerm: String? = nil
    var validatedTerm: String? = nil
    var requestEvidence: [NetworkSmokeRequestEvidence] = []
    var requestEvidenceRequired = true
    var probeLabels = Dictionary(uniqueKeysWithValues: NetworkSmokeProbe.allCases.map { ($0.rawValue, $0.displayName) })

    var elapsed: TimeInterval {
        finishedAt.timeIntervalSince(startedAt)
    }

    var missingRequiredProbes: [String] {
        scope.requiredProbes.filter { !executedProbes.contains($0) }
    }

    var coverageComplete: Bool {
        coverageGaps.isEmpty && missingRequiredProbes.isEmpty
    }

    var summaryLine: String {
        "NETWORK_SMOKE_SUMMARY run_id=\(runID) scope=\(scope.rawValue) passed=\(passed) coverage_complete=\(coverageComplete) failures=\(failures.count) auth_blocked=\(authenticationBlockers.count) executed=\(executedProbes.count) skipped=\(skippedProbes.count) sms_coverage=\(schoolSMSCoverage) elapsed=\(Self.duration(elapsed))"
    }

    var failureMessage: String {
        let failureSection = failures.isEmpty ? "" : "\n网络或业务失败：\n" + failures.joined(separator: "\n")
        let authenticationSection = authenticationBlockers.isEmpty ? "" : "\n需要人工认证，相关路径尚未完成验证：\n" + authenticationBlockers.joined(separator: "\n")
        let coverageSection = coverageGaps.isEmpty ? "" : "\n验证覆盖不完整：\n" + coverageGaps.joined(separator: "\n")
        return "发布前网络冒烟结果：" + failureSection + authenticationSection + coverageSection
    }

    private static func duration(_ interval: TimeInterval) -> String {
        String(format: "%.2fs", interval)
    }
}

/// ReleaseNetworkSmokeReportStore 保存网络冒烟报告。
enum ReleaseNetworkSmokeReportStore {
    private static let logger = Logger(subsystem: "BIT101", category: "ReleaseNetworkSmoke")
    private static let directoryName = "NetworkSmoke"
    static let rawCourseResponseFileName = "raw-course-response.json"
    static let communityJournalFileName = "community-write-journal.json"
    static let communityJournalPreferenceKey = "network-smoke.community-writes.pending"

    @MainActor
    static func complete(_ source: ReleaseNetworkSmokeReport,
        writer: @MainActor (ReleaseNetworkSmokeReport) throws -> Void) -> ReleaseNetworkSmokeReport {
        var report = source
        do { try writer(report) }
        catch {
            report.passed = false
            report.failures.append("网络 Smoke 报告写入失败：" + ErrorReportRedactor.sanitized(error.localizedDescription))
            FileHandle.standardOutput.write(Data("NETWORK_SMOKE_REPORT_WRITE_FAIL run_id=\(report.runID) error=\(ErrorReportRedactor.sanitized(error.localizedDescription))\n".utf8))
        }
        FileHandle.standardOutput.write(Data((report.summaryLine + "\n").utf8))
        if !report.passed { logger.error("\(report.failureMessage, privacy: .public)") }
        return report
    }

    static func hasPendingCommunityWrites(files: any AppFileService = AppFileDirectories.files,
        directory: URL = AppFileDirectories.applicationSupport.appendingPathComponent(directoryName, isDirectory: true),
        legacyData: Data? = AppFileDirectories.defaults.data(forKey: communityJournalPreferenceKey)) -> Bool {
        if legacyData != nil { return true }
        do {
            _ = try files.readData(at: directory.appendingPathComponent(communityJournalFileName))
            return true
        } catch { return !AppFileSystem.isMissingFile(error) }
    }

    static var fileURL: URL? {
        AppFileDirectories.appGroupFileURL(
            groupIdentifier: ScheduleSharedContainer.identifier,
            directories: ["Library", directoryName],
            named: "release-network-smoke.json"
        )
    }

    private static var rawCourseResponseFileURL: URL? {
        AppFileDirectories.appGroupFileURL(
            groupIdentifier: ScheduleSharedContainer.identifier,
            directories: ["Library", directoryName],
            named: rawCourseResponseFileName
        )
    }

    static func write(_ report: ReleaseNetworkSmokeReport) throws {
        guard let fileURL else {
            throw ScheduleExternalSnapshotStoreError.sharedContainerUnavailable
        }

        try AppFileDirectories.files.createDirectory(at: fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try AppFileDirectories.files.writeData(data, to: fileURL, options: [.atomic, .completeFileProtection])
    }

    static func clearRawCourseResponse() throws {
        guard let fileURL = rawCourseResponseFileURL else { throw ScheduleExternalSnapshotStoreError.sharedContainerUnavailable }
        try AppFileDirectories.files.removeItemIfPresent(at: fileURL)
    }

    @discardableResult
    static func clearLocalArtifacts() -> Bool {
        guard let directoryURL = fileURL?.deletingLastPathComponent() else {
            return false
        }
        do {
            try AppFileDirectories.files.removeItemIfPresent(at: directoryURL)
            return true
        } catch {
            return false
        }
    }

    static func writeRawCourseResponse(_ data: Data, runID: String) throws {
        guard let fileURL = rawCourseResponseFileURL else { throw ScheduleExternalSnapshotStoreError.sharedContainerUnavailable }
        let response = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        let envelope = try JSONSerialization.data(withJSONObject: ["runID": runID, "response": response], options: [.prettyPrinted, .sortedKeys])
        try AppFileDirectories.files.createDirectory(at: fileURL.deletingLastPathComponent())
        try AppFileDirectories.files.writeData(envelope, to: fileURL, options: [.atomic, .completeFileProtection])
    }

}

#if DEBUG || RELEASE_NETWORK_SMOKE
@MainActor
protocol NetworkSmokeGalleryServicing: GalleryFeedServicing, GalleryMessageServicing, GallerySubscriptionServicing {
    func fetchPoster(id: Int) async throws -> GalleryPosterDetail
    func fetchComments(objectID: String, order: CommunityCommentOrder, page: Int?) async throws -> GalleryPageBatch<CommunityComment>
    func fetchClaims() async throws -> [CommunityClaim]
    func fetchReportTypes() async throws -> [GalleryReportType]
}
extension GalleryService: NetworkSmokeGalleryServicing {}

@MainActor
protocol NetworkSmokeCourseServicing: CourseListServicing {
    func fetchCourse(id: Int) async throws -> CourseDetail
    func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade]
    func fetchComments(courseID: Int, page: Int?) async throws -> [CommunityComment]
}
extension CourseService: NetworkSmokeCourseServicing {}

@MainActor
protocol NetworkSmokePaperServicing: PaperListServicing {
    func fetchComments(paperID: Int, order: CommunityCommentOrder, page: Int?) async throws -> [CommunityComment]
}
extension PaperService: NetworkSmokePaperServicing {}

@MainActor
protocol NetworkSmokeMineServicing: MineOverviewServicing {
    func fetchUserInfo(id: Int) async throws -> MineUserInfo
    func fetchUserPosters(userID: Int, page: Int) async throws -> [CommunityPoster]
}
extension MineService: NetworkSmokeMineServicing {}

@MainActor
protocol NetworkSmokeScheduleServicing: ScheduleCourseServicing, ScheduleClassroomServicing {
    func fetchEclassDDLEvents(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> EclassDDLResult
    func fetchEclassDDLEventsForPreflight() async throws -> EclassDDLResult
    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String
    func refreshLexueCalendarURLForPreflight() async throws -> String
    func syncDDLEventsForPreflight(existingEvents: [DDLEventRecord], storedURL: String) async throws -> DDLSyncPayload
}
extension ScheduleService: NetworkSmokeScheduleServicing {}

@MainActor
struct ReleaseNetworkSmokeDependencies {
    static let communityPreferences = CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [],
        hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)

    static func mineService(session: CommunitySession = .appSession()) -> MineService {
        MineService(session: session, preferences: { communityPreferences })
    }

    var requiresRequestEvidence = true
    var communityIdentity: @MainActor () -> CommunitySessionIdentity = { AppAccountSession.storage.communityCredentials.identity }
    var checkLogin: @MainActor () async throws -> String? = { try await LoginService().checkLogin() }
    var writeReport: @MainActor (ReleaseNetworkSmokeReport) throws -> Void = ReleaseNetworkSmokeReportStore.write
    var clearRawCourseResponse: @MainActor () throws -> Void = ReleaseNetworkSmokeReportStore.clearRawCourseResponse
    var writeRawCourseResponse: @MainActor (Data, String) throws -> Void = { try ReleaseNetworkSmokeReportStore.writeRawCourseResponse($0, runID: $1) }
    var makeGallery: @MainActor () -> any NetworkSmokeGalleryServicing = {
        GalleryService(session: .appSession(), preferences: {
            communityPreferences
        })
    }
    var makeCourses: @MainActor () -> any NetworkSmokeCourseServicing = { CourseService() }
    var makePapers: @MainActor () -> any NetworkSmokePaperServicing = { PaperService() }
    var makeMine: @MainActor () -> any NetworkSmokeMineServicing = { mineService() }
    var communityWriteProbe: @MainActor (String, Bool, Int?, Int?, NetworkSmokeFixtures?, CommunityWriteRecoveryConfirmation?, @escaping @MainActor ([CommunityImage]) async throws -> Void) async throws -> [String] = {
        try await CommunityWriteSmoke(operations: CommunityWriteSmoke.Operations.production(followTarget: $2, courseFixture: $4, verifyImages: $6))
            .run(marker: $0, cleanupOnly: $1, expectedAccount: $3, recoveryConfirmation: $5)
    }
    var productionSessionProbe: @MainActor () async throws -> [String] = NetworkSmokeProductionSession.run
    var externalHTTPClient: HTTPClient = .shared
    var imageProbe: @MainActor (URL) async throws -> Int = ReleaseNetworkSmokeDependencies.probeRemoteImage
    var aasaHTTPClient = HTTPClient(transport: NetworkSessionPool.appLinkAssociation)
    var feedbackProbe: @MainActor (String) async throws -> Void = { try await FeedbackSubmissionClient.submitNetworkSmoke(runID: $0) }
    var loadScheduleCache: @MainActor () async -> ScheduleCache = { await ScheduleCacheStore.loadAsync() }
    var makeScores: @MainActor () -> any ScoreListServicing & TrustedTranscriptServicing = ReleaseNetworkSmokeRunner.freshScoreService
    var makeSchedule: @MainActor (((Data) -> Void)?) -> any NetworkSmokeScheduleServicing = ReleaseNetworkSmokeRunner.freshSchoolService
    var makeProductionSchedule: @MainActor () -> any NetworkSmokeScheduleServicing = NetworkSmokeProductionSession.school
    var makeEclassSchedule: @MainActor () throws -> any NetworkSmokeScheduleServicing = ReleaseNetworkSmokeRunner.freshEclassService

    static func probeRemoteImage(at url: URL) async throws -> Int {
        let files = ScopedAppFileService(root: AppFileDirectories.files.temporaryDirectoryURL
            .appending(path: "NetworkSmokeMedia", directoryHint: .isDirectory))
        if files.fileExists(at: files.root) { try files.removeItem(at: files.root) }
        let media = AppMedia.makeEnvironment(files: files, previewStorage: MediaPreviewStorage(files: files))
        let outcome: Result<Int, any Error>
        do { outcome = .success(try await media.verifyRemoteImage(at: url)) }
        catch { outcome = .failure(error) }
        await media.clearCaches()
        if files.fileExists(at: files.root) { try files.removeItem(at: files.root) }
        return try outcome.get()
    }
}
#endif

/// NetworkSmokeFixtures 指定由验收账号维护的社区详情对象。
nonisolated struct NetworkSmokeFixtures: Codable, Sendable {
    let posterID: Int
    let courseID: Int
    let courseNumber: String
    let paperID: Int

    var isValid: Bool {
        posterID > 0 && courseID > 0 && paperID > 0 && !courseNumber.isEmpty
            && courseNumber == courseNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated struct NetworkSmokeCommunityConfiguration: Codable, Sendable {
    let accountID: Int
    let followTarget: Int
    let fixtures: NetworkSmokeFixtures
}

/// ReleaseNetworkSmokeLaunchRequest 统一解析深链与 XCTest 环境中的网络验收参数。
struct ReleaseNetworkSmokeLaunchRequest: Codable, Sendable {
    let scope: NetworkSmokeScope
    let runID: String
    let capture: NetworkSmokeCapture
    let term: String?
    var interactiveSMS: Bool? = nil
    var communityFollowTarget: Int? = nil
    var communityExpectedAccount: Int? = nil
    var communityRecoveryConfirmation: CommunityWriteRecoveryConfirmation? = nil
    var fixtures: NetworkSmokeFixtures? = nil

    private enum CodingKeys: String, CodingKey {
        case scope, runID, capture, term, interactiveSMS, communityFollowTarget, communityExpectedAccount
        case communityRecoveryConfirmation, fixtures
    }

    private static func validRunID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45
        }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try values.decode(String.self, forKey: .runID)
        guard Self.validRunID(identifier) else {
            throw DecodingError.dataCorruptedError(forKey: .runID, in: values,
                debugDescription: "Smoke run ID requires 1–128 ASCII letters, digits or hyphens.")
        }
        runID = identifier
        scope = try values.decode(NetworkSmokeScope.self, forKey: .scope)
        capture = try values.decode(NetworkSmokeCapture.self, forKey: .capture)
        term = try values.decodeIfPresent(String.self, forKey: .term)
        interactiveSMS = try values.decodeIfPresent(Bool.self, forKey: .interactiveSMS)
        communityFollowTarget = try values.decodeIfPresent(Int.self, forKey: .communityFollowTarget)
        communityExpectedAccount = try values.decodeIfPresent(Int.self, forKey: .communityExpectedAccount)
        communityRecoveryConfirmation = try values.decodeIfPresent(CommunityWriteRecoveryConfirmation.self, forKey: .communityRecoveryConfirmation)
        fixtures = try values.decodeIfPresent(NetworkSmokeFixtures.self, forKey: .fixtures)
    }

    private static var pendingFileURL: URL? {
        AppFileDirectories.documentFileURL(named: "network-smoke-request.json")
    }

    static func readPendingFile(files: any AppFileService = AppFileDirectories.files, at fileURL: URL? = nil) throws -> Self {
        guard let pendingFileURL = fileURL ?? Self.pendingFileURL else { throw CocoaError(.fileNoSuchFile) }
        let data = try files.readData(at: pendingFileURL)
        let request = try JSONDecoder().decode(Self.self, from: data)
        try files.removeItem(at: pendingFileURL)
        return request
    }

    init?(scope: NetworkSmokeScope, environment: [String: String]) {
        var components = URLComponents()
        components.scheme = "bit101"
        components.host = "network-smoke"
        components.path = "/" + scope.rawValue
        components.queryItems = [
            ("run", "BIT101_VALIDATION_RUN_ID"), ("capture", "BIT101_NETWORK_SMOKE_CAPTURE"),
            ("term", "BIT101_NETWORK_SMOKE_TERM"), ("fixtures", "BIT101_NETWORK_SMOKE_FIXTURES"),
            ("follow-target", "BIT101_COMMUNITY_FOLLOW_TARGET"), ("expected-account", "BIT101_COMMUNITY_SMOKE_ACCOUNT")
        ].compactMap { name, key in
            guard let value = environment[key], !value.isEmpty else { return nil }
            return URLQueryItem(name: name, value: value)
        }
        guard let url = components.url else { return nil }
        self.init(url: url)
        if let value = environment["BIT101_COMMUNITY_RECOVERY_CONFIRMATION"], !value.isEmpty {
            guard scope == .communityCleanup,
                  let confirmation = try? JSONDecoder().decode(CommunityWriteRecoveryConfirmation.self, from: Data(value.utf8)) else { return nil }
            self.communityRecoveryConfirmation = confirmation
        }
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "bit101",
              url.host?.lowercased() == "network-smoke"
        else { return nil }

        guard let pathScopeValue = (url.pathComponents
            .filter { $0 != "/" }
            .first) else { return nil }
        guard let pathScope = NetworkSmokeScope(rawValue: pathScopeValue) else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let runID = components?.queryItems?.first(where: { $0.name == "run" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let captureValue = components?.queryItems?.first(where: { $0.name == "capture" })?.value
        let term = components?.queryItems?.first(where: { $0.name == "term" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let capture: NetworkSmokeCapture
        if let captureValue {
            guard let parsedCapture = NetworkSmokeCapture(rawValue: captureValue) else { return nil }
            capture = parsedCapture
        } else {
            capture = .none
        }

        if let value = components?.queryItems?.first(where: { $0.name == "follow-target" })?.value {
            guard let target = Int(value), target > 0 else { return nil }
            self.communityFollowTarget = target
        }
        if let value = components?.queryItems?.first(where: { $0.name == "expected-account" })?.value {
            guard let account = Int(value), account > 0 else { return nil }
            self.communityExpectedAccount = account
        }
        if let value = components?.queryItems?.first(where: { $0.name == "fixtures" })?.value {
            guard let fixtures = try? JSONDecoder().decode(NetworkSmokeFixtures.self, from: Data(value.utf8)), fixtures.isValid else { return nil }
            self.fixtures = fixtures
        }
        self.scope = pathScope
        self.capture = capture
        self.term = term?.isEmpty == true ? nil : term
        self.interactiveSMS = components?.queryItems?.contains { $0.name == "sms" && $0.value == "manual" } == true ? true : nil
        if let runID, !runID.isEmpty {
            guard Self.validRunID(runID) else { return nil }
            self.runID = runID
        } else {
            self.runID = UUID().uuidString
        }
    }
}

#if DEBUG || RELEASE_NETWORK_SMOKE
import Combine

@MainActor
final class ReleaseNetworkSmokeSMSPrompt: ObservableObject {
    @Published var request: SchoolSMSCodeRequest?
    private var continuation: CheckedContinuation<String, any Error>?

    func requestCode(_ value: SchoolSMSCodeRequest) async throws -> String {
        try Task.checkCancellation()
        guard request == nil else { throw CancellationError() }
        request = value
        defer { if request?.id == value.id { cancel() } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in if self.request?.id == value.id { self.cancel() } }
        }
    }

    func submit(_ code: String) {
        let pending = continuation
        continuation = nil
        request = nil
        pending?.resume(returning: code)
    }

    func cancel() {
        let pending = continuation
        continuation = nil
        request = nil
        pending?.resume(throwing: CancellationError())
    }
}
#endif
