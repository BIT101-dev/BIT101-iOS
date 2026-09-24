import Foundation

enum NetworkSmokeScope: String, Codable, CaseIterable, Sendable {
    case all
    case bit101
    case school
    case transcript
    case schedule
    case ddl

    func includes(_ area: NetworkSmokeArea) -> Bool {
        switch self {
        case .all:
            return true
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
struct ReleaseNetworkSmokeReport: Codable {
    let runID: String
    let scope: NetworkSmokeScope
    let startedAt: Date
    let finishedAt: Date
    let passed: Bool
    let failures: [String]
    let authenticationBlockers: [String]
    let scheduleCache: ScheduleCacheAuditSnapshot?
    let executedProbes: [String]
    let skippedProbes: [String]
    let coverageGaps: [String]
    let schoolSMSCoverage: String

    var elapsed: TimeInterval {
        finishedAt.timeIntervalSince(startedAt)
    }

    var coverageComplete: Bool {
        coverageGaps.isEmpty
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
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
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
        try? data.write(
            to: directory.appending(path: rawCourseResponseFileName),
            options: [.atomic, .completeFileProtection]
        )
    }

}

/// ReleaseNetworkSmokeLaunchRequest 解析 `bit101://network-smoke/...` 触发参数。
struct ReleaseNetworkSmokeLaunchRequest: Codable, Sendable {
    let scope: NetworkSmokeScope
    let runID: String
    let capture: NetworkSmokeCapture
    let term: String?

    private static var pendingFileURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appending(path: "network-smoke-request.json")
    }

    static func readPendingFile() -> Self? {
        guard let pendingFileURL,
              let data = try? Data(contentsOf: pendingFileURL)
        else { return nil }
        try? FileManager.default.removeItem(at: pendingFileURL)
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

/// ReleaseNetworkSmokeRunner 在当前进程执行发布前网络探针。
///
/// 这份实现同时服务于：
/// - 真机上的正式 App：通过 `bit101://network-smoke/...` 在当前进程内复用会话执行；
/// - XCTest：保留一个直接调用入口，方便回归和未来 CI 复用同一组探针。
