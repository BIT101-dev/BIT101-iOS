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
    var communityWriteEvidence: [String] = []

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
    var communityWriteProbe: @MainActor (String, Bool) async throws -> [String] = {
        try await CommunityWriteSmoke(operations: .production()).run(marker: $0, cleanupOnly: $1)
    }
    var externalHTTPClient: HTTPClient = .shared
    var aasaHTTPClient = HTTPClient(transport: NetworkSessionPool.appLinkAssociation)
    var feedbackProbe: @MainActor (String) async throws -> Void = { try await FeedbackSubmissionClient.submitNetworkSmoke(runID: $0) }
    var loadScheduleCache: @MainActor () async -> ScheduleCache = { await ScheduleCacheStore.loadAsync() }
    var makeScores: @MainActor () -> any ScoreListServicing & TrustedTranscriptServicing = { ScoreService() }
    var makeSchedule: @MainActor (((Data) -> Void)?) -> any NetworkSmokeScheduleServicing = { ScheduleServiceFactory.make(rawCourseResponseHandler: $0) }
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

#if DEBUG || RELEASE_NETWORK_SMOKE
/// 线上写入的事务记录原子保存到本机专用文件，清理复用服务端读取与删除入口。
@MainActor
final class CommunityWriteSmoke {
    enum Kind: String, Codable, CaseIterable { case poster, paper, course }
    struct Content { let text: String; let owned: Bool; let liked: Bool }
    struct Operations {
        var identity: () -> CommunitySessionIdentity
        var account: () async throws -> Int
        var course: () async throws -> Int
        var create: (Kind, String) async throws -> Int
        var find: (Kind, String) async throws -> [Int]
        var read: (Kind, Int) async throws -> Content?
        var edit: (Kind, Int, String) async throws -> Void
        var delete: (Kind, Int) async throws -> Void
        var comments: (String) async throws -> [CommunityComment]
        var comment: (String, String) async throws -> CommunityComment
        var deleteComment: (Int) async throws -> Void
        var like: (Kind, Int) async throws -> Bool

        func scoped(to owner: CommunitySessionIdentity) -> Self {
            Self(identity: identity,
                account: { try await Self.checked(identity, owner) { try await account() } },
                course: { try await Self.checked(identity, owner) { try await course() } },
                create: { kind, text in try await Self.checked(identity, owner) { try await create(kind, text) } },
                find: { kind, text in try await Self.checked(identity, owner) { try await find(kind, text) } },
                read: { kind, id in try await Self.checked(identity, owner) { try await read(kind, id) } },
                edit: { kind, id, text in try await Self.checked(identity, owner) { try await edit(kind, id, text) } },
                delete: { kind, id in try await Self.checked(identity, owner) { try await delete(kind, id) } },
                comments: { object in try await Self.checked(identity, owner) { try await comments(object) } },
                comment: { object, text in try await Self.checked(identity, owner) { try await comment(object, text) } },
                deleteComment: { id in try await Self.checked(identity, owner) { try await deleteComment(id) } },
                like: { kind, id in try await Self.checked(identity, owner) { try await like(kind, id) } })
        }

        private static func checked<Value>(_ identity: () -> CommunitySessionIdentity, _ owner: CommunitySessionIdentity,
            operation: () async throws -> Value) async throws -> Value {
            guard identity() == owner else { throw CancellationError() }
            let result: Result<Value, any Error>
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            guard identity() == owner else { throw CancellationError() }
            return try result.get()
        }

        static func isMissingContent(_ error: NSError, kind: Kind) -> Bool {
            if error.code == 404 { return true }
            switch kind {
            case .paper: return error.domain == "BIT101.Paper" && error.localizedDescription == "文章不存在Orz"
            case .poster: return error.domain == "BIT101.Gallery" && error.localizedDescription == "帖子不存在Orz"
            case .course: return false
            }
        }

        static func production(papers: PaperService = PaperService(), courses: CourseService = CourseService()) -> Self {
            let gallery = GalleryService()
            let mine = MineService()
            return Self(identity: { AppAccountSession.storage.communityCredentials.identity }, account: { try await mine.fetchMyInfo().user.id }, course: {
                guard let course = try await courses.fetchCourses(search: "", page: 0).first else { throw URLError(.zeroByteResource) }
                return course.id
            }, create: { kind, text in
                switch kind {
                case .poster: return try await gallery.createPoster(title: "功能验收", text: text,
                    imageMids: [], anonymous: false, tags: [], claimID: 0, isPublic: false)
                case .paper: return try await papers.createPaper(title: text, intro: text,
                    content: PaperEditorContentBuilder.editorJSON(from: text), anonymous: false, publicEdit: false)
                case .course: throw URLError(.unsupportedURL)
                }
            }, find: { kind, text in
                var result: Set<Int> = []
                var progress = CommunityPageProgress<Int>()
                var page = 0
                while true {
                    if kind == .poster {
                        let rows = try await mine.fetchMyPosters(page: page)
                        if rows.isEmpty { return result.sorted() }
                        try progress.record(rows.map(\.id))
                        result.formUnion(rows.filter { $0.text.contains(text) }.map(\.id))
                    } else {
                        let rows = try await papers.fetchPapers(search: text, order: .newest, page: page)
                        if rows.isEmpty { return result.sorted() }
                        try progress.record(rows.map(\.id))
                        for row in rows {
                            do {
                                let detail = try await papers.fetchPaper(id: row.id)
                                if detail.own && PaperEditorContentBuilder.plainText(from: detail.content).contains(text) { result.insert(row.id) }
                            } catch let error as NSError where Self.isMissingContent(error, kind: .paper) { continue }
                        }
                    }
                    page += 1
                }
            }, read: { kind, id in
                do {
                    switch kind {
                    case .poster:
                        let value = try await gallery.fetchPoster(id: id)
                        return Content(text: value.text, owned: value.own, liked: value.like)
                    case .paper:
                        let value = try await papers.fetchPaper(id: id)
                        return Content(text: PaperEditorContentBuilder.plainText(from: value.content), owned: value.own, liked: value.like)
                    case .course:
                        let value = try await courses.fetchCourse(id: id)
                        return Content(text: "", owned: false, liked: value.like)
                    }
                } catch let error as NSError where Self.isMissingContent(error, kind: kind) {
                    return nil
                }
            }, edit: { kind, id, text in
                switch kind {
                case .poster: try await gallery.updatePoster(id: id, title: "功能验收", text: text,
                    imageMids: [], anonymous: false, tags: [], claimID: 0, isPublic: false)
                case .paper:
                    let current = try await papers.fetchPaper(id: id)
                    try await papers.updatePaper(id: id, title: text, intro: text,
                        content: PaperEditorContentBuilder.editorJSON(from: text), anonymous: false, publicEdit: false,
                        lastUpdatedAt: current.updateTime)
                case .course: throw URLError(.unsupportedURL)
                }
            }, delete: { kind, id in
                if kind == .poster { try await gallery.deletePoster(id: id) }
                else { try await papers.deletePaper(id: id) }
            }, comments: { object in
                var result: [Int: CommunityComment] = [:]
                var progress = CommunityPageProgress<Int>()
                var page = 0
                while true {
                    let rows: [CommunityComment]
                    do { rows = try await gallery.fetchRawComments(objectID: object, order: .oldest, page: page) }
                    catch let error as NSError where error.code == 404 { return result.values.sorted { $0.id < $1.id } }
                    if rows.isEmpty { return result.values.sorted { $0.id < $1.id } }
                    try progress.record(rows.map(\.id))
                    for row in rows { result[row.id] = row }
                    page += 1
                }
            }, comment: { object, text in
                let value: CommunityComment
                if object.hasPrefix("course") { value = try await courses.createComment(objectID: object, text: text, rate: 6) }
                else if object.hasPrefix("paper") { value = try await papers.createComment(objectID: object, text: text) }
                else { value = try await gallery.createComment(objectID: object, text: text) }
                try await Task.sleep(for: .seconds(1))
                return value
            }, deleteComment: { try await gallery.deleteComment(id: $0) }, like: { kind, id in
                let value: Bool
                switch kind {
                case .poster: value = try await gallery.like(objectID: "poster\(id)").like
                case .paper: value = try await papers.likePaper(id: id).like
                case .course: value = try await courses.like(objectID: "course\(id)").like
                }
                try await Task.sleep(for: .seconds(1))
                return value
            })
        }
    }
    private struct Target: Codable, Hashable { let kind: Kind; let id: Int }
    private struct Like: Codable { let target: Target; let original: Bool }
    private struct Journal: Codable {
        let marker: String
        let account: Int
        var attempts: [Kind] = []
        var targets: [Target] = []
        var parents: [String] = []
        var comments: [Int] = []
        var likes: [Like] = []
        var evidence: [String] = []
    }
    private let operations: Operations
    private let load: () throws -> Data?
    private let save: (Data?) throws -> Void
    private static let journalKey = "network-smoke.community-writes.pending"

    static func loadJournal(files: any AppFileService = AppFileDirectories.files,
        directory: URL = AppFileDirectories.applicationSupport.appendingPathComponent("NetworkSmoke", isDirectory: true),
        legacyData: Data? = AppFileDirectories.defaults.data(forKey: journalKey),
        removeLegacy: () -> Void = { AppFileDirectories.defaults.removeObject(forKey: journalKey) }) throws -> Data? {
        let url = directory.appendingPathComponent("community-write-journal.json")
        if files.fileExists(at: url) { return try files.readData(at: url) }
        if let legacyData {
            try saveJournal(legacyData, files: files, directory: directory)
            removeLegacy()
            return legacyData
        }
        return nil
    }

    static func saveJournal(_ data: Data?, files: any AppFileService = AppFileDirectories.files,
        directory: URL = AppFileDirectories.applicationSupport.appendingPathComponent("NetworkSmoke", isDirectory: true)) throws {
        let url = directory.appendingPathComponent("community-write-journal.json")
        if let data {
            try files.createDirectory(at: directory)
            try files.writeData(data, to: url, options: AppFileSystem.protectedDataWritingOptions)
        } else if files.fileExists(at: url) {
            try files.removeItem(at: url)
        }
    }

    init(operations: Operations, load: @escaping () throws -> Data? = {
        try CommunityWriteSmoke.loadJournal()
    }, save: @escaping (Data?) throws -> Void = {
        try CommunityWriteSmoke.saveJournal($0)
    }) {
        self.operations = operations; self.load = load; self.save = save
    }

    func run(marker: String, cleanupOnly: Bool = false) async throws -> [String] {
        let owner = self.operations.identity()
        let operations = self.operations.scoped(to: owner)
        let account = try await operations.account()
        if let data = try load() {
            var previous = try JSONDecoder().decode(Journal.self, from: data)
            guard previous.account == account else { throw failure("请登录创建验收内容的账号以完成清理") }
            try await cleanup(&previous, operations: operations, owner: owner)
        }
        guard !cleanupOnly else { return ["服务端清理确认完成"] }
        var journal = Journal(marker: "功能验收 " + marker, account: account)
        var businessError: (any Error)?
        var operation = "创建内容"
        do {
            for kind in [Kind.poster, .paper] {
                try Task.checkCancellation()
                journal.attempts.append(kind); try persist(journal)
                operation = "创建 " + kind.rawValue
                let id = try await operations.create(kind, journal.marker)
                let target = Target(kind: kind, id: id)
                journal.targets.append(target); journal.evidence.append("创建 \(kind.rawValue)\(id)")
                try persist(journal)
                operation = "读取 " + kind.rawValue
                guard let created = try await operations.read(kind, id), created.owned,
                      created.text == journal.marker else { throw failure("验收内容创建结果异常") }
                let edited = journal.marker + " 编辑"
                operation = "编辑 " + kind.rawValue
                try await operations.edit(kind, id, edited)
                guard try await operations.read(kind, id)?.text == edited else { throw failure("验收编辑结果异常") }
            }
            operation = "选择课程"
            let course = try await operations.course()
            journal.targets.append(Target(kind: .course, id: course)); try persist(journal)
            for target in journal.targets {
                operation = "点赞 " + target.kind.rawValue
                try Task.checkCancellation()
                guard try await operations.account() == account else { throw failure("验收账号已切换") }
                guard let before = try await operations.read(target.kind, target.id) else { throw failure("验收目标缺失") }
                journal.likes.append(Like(target: target, original: before.liked)); try persist(journal)
                guard try await operations.like(target.kind, target.id) != before.liked,
                      try await operations.read(target.kind, target.id)?.liked == !before.liked else { throw failure("验收点赞结果异常") }
                guard try await operations.like(target.kind, target.id) == before.liked,
                      try await operations.read(target.kind, target.id)?.liked == before.liked else { throw failure("验收点赞恢复异常") }
                journal.evidence.append("点赞恢复 \(target.kind.rawValue)\(target.id)")
                let parent = target.kind.rawValue + String(target.id)
                journal.parents.append(parent); try persist(journal)
                operation = "评论 " + target.kind.rawValue
                let comment = try await operations.comment(parent, journal.marker)
                guard comment.id > 0, !journal.comments.contains(comment.id) else { throw failure("验收评论标识重复或无效") }
                journal.comments.append(comment.id); journal.evidence.append("创建 comment\(comment.id) 目标 \(parent)")
                let replies = "comment\(comment.id)"
                journal.parents.append(replies); try persist(journal)
                guard comment.own, comment.text == journal.marker,
                      try await operations.comments(parent).contains(where: { $0.id == comment.id }) else { throw failure("验收评论创建结果异常") }
                operation = "回复 " + target.kind.rawValue
                let reply = try await operations.comment(replies, journal.marker)
                guard reply.id > 0, !journal.comments.contains(reply.id) else { throw failure("验收回复标识重复或无效") }
                journal.comments.append(reply.id); journal.evidence.append("创建 comment\(reply.id) 目标 \(replies)")
                try persist(journal)
                guard reply.own, reply.text == journal.marker,
                      try await operations.comments(replies).contains(where: { $0.id == reply.id }) else { throw failure("验收回复创建结果异常") }
            }
        } catch { businessError = failure(operation + "：" + error.localizedDescription) }
        let snapshot = journal
        let cleaned = await Task { @MainActor [self] in
            var pending = snapshot
            do { try await cleanup(&pending, operations: operations, owner: owner); return Result<[String], any Error>.success(pending.evidence) }
            catch { return .failure(error) }
        }.value
        let evidence = try cleaned.get()
        if let businessError { throw failure("写入验收待完成，服务端清理已确认：" + businessError.localizedDescription) }
        return evidence
    }

    private func persist(_ journal: Journal) throws { try save(JSONEncoder().encode(journal)) }

    private func cleanup(_ journal: inout Journal, operations: Operations, owner: CommunitySessionIdentity) async throws {
        var failures: [String] = []
        var discovered: Set<Kind> = []
        var commentParents: [Int: String] = [:]
        for kind in Set(journal.attempts) {
            if try await recoverOperation("查找 " + kind.rawValue, failures: &failures, operation: {
                for id in try await operations.find(kind, journal.marker) {
                    let target = Target(kind: kind, id: id)
                    if !journal.targets.contains(target) { journal.targets.append(target) }
                }
            }) {
                discovered.insert(kind)
            }
        }
        try persist(journal)
        for like in journal.likes {
            if try await recoverOperation("恢复点赞 " + like.target.kind.rawValue, failures: &failures, operation: {
                if let current = try await operations.read(like.target.kind, like.target.id), current.liked != like.original {
                    _ = try await operations.like(like.target.kind, like.target.id)
                }
                if let restored = try await operations.read(like.target.kind, like.target.id), restored.liked != like.original {
                    throw failure("点赞恢复待完成")
                }
            }) {
                journal.likes.removeAll { $0.target == like.target }
            }
            try persist(journal)
        }
        for parent in journal.parents {
            _ = try await recoverOperation("查找评论 " + parent, failures: &failures, operation: {
                for comment in try await operations.comments(parent) where comment.own && comment.text == journal.marker {
                    if !journal.comments.contains(comment.id) { journal.comments.append(comment.id) }
                    commentParents[comment.id] = parent
                }
            })
        }
        journal.comments = journal.comments.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        try persist(journal)
        let commentIDs = journal.comments
        for id in journal.comments.reversed() {
            guard commentParents[id] != nil else { continue }
            if try await recoverOperation("删除 comment\(id)", failures: &failures, operation: {
                let replies = "comment\(id)"
                if journal.parents.contains(replies) {
                    guard try await operations.comments(replies).allSatisfy({ !commentIDs.contains($0.id) && !($0.own && $0.text == journal.marker) })
                    else { throw failure("验收回复清理待完成") }
                    retireComments(replies, parents: commentParents, journal: &journal)
                    try persist(journal)
                }
                do { try await operations.deleteComment(id) }
                catch let error as NSError where error.code == 404 { journal.evidence.append("已清理 comment\(id)") }
            }) {
                journal.comments.removeAll { $0 == id }
                journal.evidence.append("删除 comment\(id)")
            }
            try persist(journal)
        }
        for parent in journal.parents {
            if try await recoverOperation("确认评论删除 " + parent, failures: &failures, operation: {
                guard try await operations.comments(parent).allSatisfy({ !commentIDs.contains($0.id) && !($0.own && $0.text == journal.marker) })
                else { throw failure("验收评论清理待完成") }
            }) {
                retireComments(parent, parents: commentParents, journal: &journal)
            }
            try persist(journal)
        }
        if journal.parents.isEmpty {
            journal.comments.removeAll()
            for id in commentIDs where !journal.evidence.contains("服务端确认删除 comment\(id)") {
                journal.evidence.append("服务端确认删除 comment\(id)")
            }
        }
        for target in journal.targets.reversed() where target.kind != .course {
            if try await recoverOperation("删除 " + target.kind.rawValue, failures: &failures, operation: {
                guard !journal.parents.contains(target.kind.rawValue + String(target.id)) else { throw failure("验收评论清理待完成") }
                if let current = try await operations.read(target.kind, target.id) {
                    guard current.owned, current.text.hasPrefix(journal.marker) else { throw failure("验收清理目标身份异常") }
                    try await operations.delete(target.kind, target.id)
                }
                guard try await operations.read(target.kind, target.id) == nil else { throw failure("验收内容清理待完成") }
            }) {
                journal.targets.removeAll { $0 == target }
                journal.likes.removeAll { $0.target == target }
                journal.evidence.append("服务端确认删除 \(target.kind.rawValue)\(target.id)")
            }
            try persist(journal)
        }
        journal.attempts.removeAll { kind in discovered.contains(kind) && !journal.targets.contains(where: { $0.kind == kind }) }
        guard operations.identity() == owner else { throw failure("验收账号已切换，清理记录已保留") }
        if !failures.isEmpty { try persist(journal); throw failure(failures.joined(separator: "；")) }
        try save(nil)
    }

    private func retireComments(_ parent: String, parents: [Int: String], journal: inout Journal) {
        let ids = parents.filter { $0.value == parent }.map(\.key)
        journal.comments.removeAll { ids.contains($0) }
        journal.parents.removeAll { $0 == parent }
        for id in ids where !journal.evidence.contains("服务端确认删除 comment\(id)") {
            journal.evidence.append("服务端确认删除 comment\(id)")
        }
    }

    private func recoverOperation(_ name: String, failures: inout [String], operation: () async throws -> Void) async throws -> Bool {
        do { try await operation(); return true }
        catch {
            if TaskCancellation.matches(error) { throw error }
            failures.append(name + "：" + error.localizedDescription)
            return false
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "BIT101.CommunityWriteSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif

/// ReleaseNetworkSmokeRunner 在当前进程执行发布前网络探针。
///
/// 这份实现同时服务于：
/// - 真机采样宿主：通过 `bit101://network-smoke/...` 在当前进程内复用会话执行；
/// - XCTest：保留一个直接调用入口，方便回归和未来 CI 复用同一组探针。
