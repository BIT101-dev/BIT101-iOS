import Foundation

enum NetworkSmokeScope: String, Codable {
    case all
    case bit101
    case school
    case transcript
    case schedule
    case ddl

    func includes(_ name: String) -> Bool {
        if name == "课程历史缓存验证" {
            return self == .all || self == .bit101
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
        case .ddl:
            return name == "BIT101 登录状态"
                || name == "乐学日历订阅地址"
                || name == "乐学 DDL 下载"
        }
    }
}

enum NetworkSmokeCapture: String, Codable {
    case none
    case courseHistory
    case cachedCourseHistory
    case scheduleCache
    case rawCourseResponse
}

struct ScheduleCacheAuditCourse: Codable {
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

struct ScheduleCacheAuditSnapshot: Codable {
    let currentTerm: String
    let firstDayString: String
    let sourceFirstDayString: String
    let normalizationOffset: Int
    let courseCount: Int
    let courses: [ScheduleCacheAuditCourse]
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
    let scheduleCache: ScheduleCacheAuditSnapshot?
    let executedProbes: [String]
    let skippedProbes: [String]
    let schoolSMSCoverage: String

    var elapsed: TimeInterval {
        finishedAt.timeIntervalSince(startedAt)
    }

    var summaryLine: String {
        "NETWORK_SMOKE_SUMMARY run_id=\(runID) scope=\(scope.rawValue) passed=\(passed) failures=\(failures.count) auth_blocked=\(authenticationBlockers.count) executed=\(executedProbes.count) sms_coverage=\(schoolSMSCoverage) elapsed=\(Self.duration(elapsed))"
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
    static let rawCourseResponseFileName = "raw-course-response.json"
    private static let rawCourseCaptureKey = "release-network-smoke.capture.raw-course-response"

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

    static var rawCourseCaptureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: rawCourseCaptureKey) }
        set { UserDefaults.standard.set(newValue, forKey: rawCourseCaptureKey) }
    }

    static func clearRawCourseResponse() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ScheduleSharedContainer.identifier
        ) else { return }
        let fileURL = containerURL
            .appending(path: "Library/NetworkSmoke", directoryHint: .isDirectory)
            .appending(path: rawCourseResponseFileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func writeRawCourseResponse(_ data: Data) {
        guard rawCourseCaptureEnabled,
              let containerURL = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: ScheduleSharedContainer.identifier
              )
        else { return }
        let directory = containerURL.appending(path: "Library/NetworkSmoke", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: rawCourseResponseFileName), options: .atomic)
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

        guard let pathScopeValue = (url.pathComponents
            .filter { $0 != "/" }
            .first) else { return nil }
        guard let pathScope = NetworkSmokeScope(rawValue: pathScopeValue) else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let runID = components?.queryItems?.first(where: { $0.name == "run" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let captureValue = components?.queryItems?.first(where: { $0.name == "capture" })?.value
        let capture: NetworkSmokeCapture
        if let captureValue {
            guard let parsedCapture = NetworkSmokeCapture(rawValue: captureValue) else { return nil }
            capture = parsedCapture
        } else {
            capture = .none
        }

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
