import StorageCore
import Foundation
import Combine
import OSLog

nonisolated struct AppCacheCleanupResult: Sendable {
    let reclaimedBytes: Int64
    let succeeded: Bool
}

/// 清理能力与资源归属由应用组装入口选择。
@MainActor
struct AppLocalDataActions {
    let hasPendingRecovery: () -> Bool
    let clearLogin: () -> Bool
    let suspendStorageOperations: () async -> Void
    let resumeStorageOperations: () -> Void
    let clearSchedule: () async -> Bool
    let clearSharedSnapshot: () async -> Bool
    let clearReports: () -> Bool
    let clearDiagnostics: () async -> Void
    let clearPreferences: () -> Void
    let clearURLCache: () -> Void
    let clearWebData: () async -> Void
    let clearMedia: () async -> Bool
    let resetSettings: () -> Void
}

/// 应用本地数据清理由操作服务承接，页面绑定进度与结果。
@MainActor
final class AppLocalDataService: ObservableObject {
    private static let logger = Logger(subsystem: "BIT101", category: "LocalDataCleanup")
    @Published private(set) var isCleaning = false
    private(set) var resetFailureMessage: String?
    private let files: any AppFileService
    private let actions: AppLocalDataActions
    private let cacheDirectories: Set<URL>

    init(files: any AppFileService, actions: AppLocalDataActions, cacheDirectories: Set<URL> = []) {
        self.files = files
        self.actions = actions
        self.cacheDirectories = cacheDirectories
    }

    func resetAllLocalData(onLogout: () -> Void) async -> Bool {
        guard !isCleaning else { return false }
        resetFailureMessage = nil
        guard !actions.hasPendingRecovery() else {
            resetFailureMessage = "请先完成在线验收操作的恢复，再清理本机数据。"
            return false
        }
        isCleaning = true
        defer { isCleaning = false }
        let didClearLoginData = actions.clearLogin()
        await actions.suspendStorageOperations()
        let didClearSchedule = await actions.clearSchedule()
        let didClearSharedSnapshot = await actions.clearSharedSnapshot()
        let didClearSmokeArtifacts = actions.clearReports()
        await actions.clearDiagnostics()
        actions.clearPreferences()
        let didClearMedia = await actions.clearMedia()
        let didClearSandboxFiles = await clearSandboxFileData()
        actions.clearURLCache()
        await actions.clearWebData()
        actions.resetSettings()
        actions.resumeStorageOperations()
        onLogout()
        let failures = [
            (didClearLoginData, "登录凭据"),
            (didClearSchedule, "课表缓存"),
            (didClearSharedSnapshot, "小组件与手表数据"),
            (didClearSmokeArtifacts, "网络验收记录"),
            (didClearMedia, "图片缓存"),
            (didClearSandboxFiles, "本机文稿与应用数据"),
        ].filter { !$0.0 }.map(\.1)
        if !failures.isEmpty {
            let items = failures.joined(separator: "、")
            resetFailureMessage = "以下本机数据仍待清理：\(items)。请稍后重试。"
            Self.logger.error("Local data cleanup pending: \(items, privacy: .public)")
        }
        return failures.isEmpty
    }

    func clearCaches() async -> AppCacheCleanupResult {
        guard !isCleaning else { return AppCacheCleanupResult(reclaimedBytes: 0, succeeded: false) }
        isCleaning = true
        defer { isCleaning = false }
        let originalBytes = await AppLocalFileCleanup.usedBytes(files: files, directories: cacheDirectories)
        let succeeded = await actions.clearMedia()
        actions.clearURLCache()
        let remainingBytes = await AppLocalFileCleanup.usedBytes(files: files, directories: cacheDirectories)
        return AppCacheCleanupResult(reclaimedBytes: max(0, originalBytes - remainingBytes), succeeded: succeeded)
    }

    /// 账号存储暂停后清理文稿与应用持有的存储目录。
    private func clearSandboxFileData() async -> Bool {
        await AppLocalFileCleanup.removeLocalData(files: files)
    }

}

nonisolated enum AppLocalFileCleanup {
    private static let logger = Logger(subsystem: "BIT101", category: "LocalDataCleanup")
    @concurrent static func usedBytes(files: any AppFileService, directories: Set<URL>) async -> Int64 {
        directories.reduce(Int64(0)) { $0 + files.totalRegularFileSize(at: $1) }
    }

    @concurrent static func removeLocalData(files: any AppFileService) async -> Bool {
        var succeeded = true
        if let support = files.directoryURL(.applicationSupportDirectory) {
            for name in ["BIT101-iOS", "ComposerDrafts", "NetworkSmoke"] {
                succeeded = removeItem(files: files, url: support.appending(path: name)) && succeeded
            }
        }
        if let documents = files.directoryURL(.documentDirectory) {
            do {
                for child in try files.contentsOfDirectory(at: documents, options: []) {
                    if child.lastPathComponent == "Inbox" {
                        succeeded = files.removeContents(of: child) && succeeded
                    } else {
                        succeeded = removeItem(files: files, url: child) && succeeded
                    }
                }
            } catch {
                if !AppFileSystem.isMissingFile(error) {
                    succeeded = false
                    recordFailure(error, at: documents)
                }
            }
        }
        return succeeded
    }

    private static func removeItem(files: any AppFileService, url: URL) -> Bool {
        do { try files.removeItemIfPresent(at: url); return true }
        catch { recordFailure(error, at: url); return false }
    }

    private static func recordFailure(_ error: any Error, at url: URL) {
        let failure = error as NSError
        logger.error("Local data removal failed: \(url.path, privacy: .private) domain=\(failure.domain, privacy: .public) code=\(failure.code)")
    }
}
