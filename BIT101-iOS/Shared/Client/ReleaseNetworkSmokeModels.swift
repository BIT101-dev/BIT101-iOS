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
import ClientCore
import GalleryFeature
import CourseFeature
import ScoreDomain
import ScorePorts
import ScoreInfrastructure
import ScheduleInfrastructure

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
            return area == .authentication
                || area == .schedule
                || area == .ddl
                || area == .school
                || area == .transcript
        case .transcript:
            return area == .authentication || area == .transcript
        case .schedule:
            return area == .authentication || area == .schedule
        case .ddl:
            return area == .authentication || area == .ddl
        case .communityWrites:
            return area == .authentication || area == .communityWrites
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

enum NetworkSmokeArea: CaseIterable, Hashable, Sendable {
    case authentication
    case bit101
    case schedule
    case ddl
    case school
    case transcript
    case communityWrites

    var requiredProbes: [String] {
        switch self {
        case .authentication:
            ["BIT101 登录状态"]
        case .communityWrites:
            ["社区写入与清理"]
        case .bit101:
            [
                "open.aihelpme.dev 首页跳转",
                "App 链接关联配置",
                "分享图标下载",
                "反馈接口跨域预检",
                "话廊最新列表",
                "话廊帖子详情",
                "话廊帖子评论",
                "话廊图片下载",
                "话廊网页详情",
                "话廊推荐流",
                "话廊机器人流",
                "帖子声明列表",
                "社区举报类型",
                "生产共享会话",
                "话廊搜索",
                "消息未读数",
                "学业课程列表",
                "学业课程详情",
                "学业课程评论",
                "学业课程历史成绩",
                "学业课程网页详情",
                "文章列表",
                "文章详情",
                "文章评论",
                "文章网页详情",
                "我的资料",
                "我的关注",
                "我的粉丝",
                "我的帖子",
                "用户资料详情",
                "用户帖子",
                "App Store 更新接口",
                "紧急更新配置接口",
                "feedback.aihelpme.dev 写入恢复",
            ] + GalleryMessageType.allCases.map { "消息列表-\($0.rawValue)" }
                + PaperSortOrder.allCases.map { "文章列表-\($0.title)" }
        case .schedule:
            [
                "当前学期",
                "生产学校会话",
                "切换学期列表",
                "课表、考试与首周同步",
                "空教室校区列表",
                "空教室教学楼列表",
                "空教室占用数据",
            ]
        case .ddl:
            [
                "课程中心原生认证",
                "课程中心 DDL 下载",
                "乐学日历订阅地址",
                "乐学 DDL 下载",
            ]
        case .school:
            [
                "成绩认证接口",
                "成绩简略列表",
                "成绩详细列表",
            ]
        case .transcript:
            [
                "可信成绩单接口",
            ]
        }
    }

}

enum NetworkSmokeCapture: String, Codable, Sendable {
    case none
    case scheduleCache
    case rawCourseResponse
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
    private static let directoryName = "NetworkSmoke"
    static let rawCourseResponseFileName = "raw-course-response.json"

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
        if AppFileDirectories.files.fileExists(at: fileURL) { try AppFileDirectories.files.removeItem(at: fileURL) }
    }

    @discardableResult
    static func clearLocalArtifacts() -> Bool {
        guard let directoryURL = fileURL?.deletingLastPathComponent() else {
            return false
        }
        let succeeded: Bool
        if !AppFileDirectories.files.fileExists(at: directoryURL) {
            succeeded = true
        } else {
            do {
                try AppFileDirectories.files.removeItem(at: directoryURL)
                succeeded = true
            } catch {
                succeeded = false
            }
        }
        return succeeded
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
protocol NetworkSmokeGalleryServicing: GalleryFeedServicing, GalleryMessageServicing {
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
    var checkLogin: @MainActor () async throws -> String? = { try await LoginService().checkLogin() }
    var writeReport: @MainActor (ReleaseNetworkSmokeReport) throws -> Void = ReleaseNetworkSmokeReportStore.write
    var clearRawCourseResponse: @MainActor () throws -> Void = ReleaseNetworkSmokeReportStore.clearRawCourseResponse
    var writeRawCourseResponse: @MainActor (Data, String) throws -> Void = { try ReleaseNetworkSmokeReportStore.writeRawCourseResponse($0, runID: $1) }
    var makeGallery: @MainActor () -> any NetworkSmokeGalleryServicing = { GalleryService() }
    var makeCourses: @MainActor () -> any NetworkSmokeCourseServicing = { CourseService() }
    var makePapers: @MainActor () -> any NetworkSmokePaperServicing = { PaperService() }
    var makeMine: @MainActor () -> any NetworkSmokeMineServicing = { MineService() }
    var communityWriteProbe: @MainActor (String, Bool, Int?, Int?) async throws -> [String] = {
        try await CommunityWriteSmoke(operations: .production(followTarget: $2)).run(marker: $0, cleanupOnly: $1, expectedAccount: $3)
    }
    var productionSessionProbe: @MainActor () async throws -> [String] = NetworkSmokeProductionSession.run
    var externalHTTPClient: HTTPClient = .shared
    var aasaHTTPClient = HTTPClient(transport: NetworkSessionPool.appLinkAssociation)
    var feedbackProbe: @MainActor (String) async throws -> Void = { try await FeedbackSubmissionClient.submitNetworkSmoke(runID: $0) }
    var loadScheduleCache: @MainActor () async -> ScheduleCache = { await ScheduleCacheStore.loadAsync() }
    var makeScores: @MainActor () -> any ScoreListServicing & TrustedTranscriptServicing = ReleaseNetworkSmokeRunner.freshScoreService
    var makeSchedule: @MainActor (((Data) -> Void)?) -> any NetworkSmokeScheduleServicing = ReleaseNetworkSmokeRunner.freshSchoolService
    var makeProductionSchedule: @MainActor () -> any NetworkSmokeScheduleServicing = NetworkSmokeProductionSession.school
    var makeEclassSchedule: @MainActor () throws -> any NetworkSmokeScheduleServicing = ReleaseNetworkSmokeRunner.freshEclassService
}
#endif

/// ReleaseNetworkSmokeLaunchRequest 解析 `bit101://network-smoke/...` 触发参数。
struct ReleaseNetworkSmokeLaunchRequest: Codable, Sendable {
    let scope: NetworkSmokeScope
    let runID: String
    let capture: NetworkSmokeCapture
    let term: String?
    var interactiveSMS: Bool? = nil
    var communityFollowTarget: Int? = nil
    var communityExpectedAccount: Int? = nil

    private static var pendingFileURL: URL? {
        AppFileDirectories.documentFileURL(named: "network-smoke-request.json")
    }

    static func readPendingFile() -> Self? {
        guard let pendingFileURL,
              let data = try? AppFileDirectories.files.readData(at: pendingFileURL)
        else { return nil }
        try? AppFileDirectories.files.removeItem(at: pendingFileURL)
        return try? JSONDecoder().decode(Self.self, from: data)
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

        self.communityFollowTarget = components?.queryItems?.first(where: { $0.name == "follow-target" })?.value.flatMap(Int.init)
        self.communityExpectedAccount = components?.queryItems?.first(where: { $0.name == "expected-account" })?.value.flatMap(Int.init)
        self.scope = pathScope
        self.capture = capture
        self.term = term?.isEmpty == true ? nil : term
        self.interactiveSMS = components?.queryItems?.contains { $0.name == "sms" && $0.value == "manual" } == true ? true : nil
        if let runID, !runID.isEmpty {
            guard runID.count <= 128,
                  runID.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
            else { return nil }
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
