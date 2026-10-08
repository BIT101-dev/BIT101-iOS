import StorageCore
import Foundation
import Combine

struct AppCacheCleanupResult {
    let reclaimedBytes: Int64
    let succeeded: Bool
}

/// 清理能力与资源归属由应用组装入口选择。
@MainActor
struct AppLocalDataActions {
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
    let clearMedia: () async -> Void
    let resetSettings: () -> Void
}

/// 应用本地数据清理由操作服务承接，页面绑定进度与结果。
@MainActor
final class AppLocalDataService: ObservableObject {
    @Published private(set) var isCleaning = false
    private let files: any AppFileService
    private let actions: AppLocalDataActions

    init(files: any AppFileService, actions: AppLocalDataActions) {
        self.files = files
        self.actions = actions
    }

    func resetAllLocalData(onLogout: () -> Void) async -> Bool {
        guard !isCleaning else { return false }
        isCleaning = true
        defer { isCleaning = false }
        let didClearLoginData = actions.clearLogin()
        await actions.suspendStorageOperations()
        let didClearSchedule = await actions.clearSchedule()
        let didClearSharedSnapshot = await actions.clearSharedSnapshot()
        let didClearSmokeArtifacts = actions.clearReports()
        await actions.clearDiagnostics()
        actions.clearPreferences()
        await actions.clearMedia()
        let didClearSandboxFiles = clearSandboxFileData()
        actions.clearURLCache()
        await actions.clearWebData()
        actions.resetSettings()
        actions.resumeStorageOperations()
        onLogout()
        return didClearLoginData && didClearSchedule && didClearSharedSnapshot && didClearSmokeArtifacts && didClearSandboxFiles
    }

    func clearCaches() async -> AppCacheCleanupResult {
        guard !isCleaning else { return AppCacheCleanupResult(reclaimedBytes: 0, succeeded: false) }
        isCleaning = true
        defer { isCleaning = false }
        let directories = Set([files.directoryURL(.cachesDirectory), files.temporaryDirectoryURL].compactMap { $0 })
        let originalBytes = directories.reduce(Int64(0)) { $0 + files.totalRegularFileSize(at: $1) }
        await actions.clearMedia()
        var succeeded = true
        for directory in directories { succeeded = files.removeContents(of: directory) && succeeded }
        actions.clearURLCache()
        let remainingBytes = directories.reduce(Int64(0)) { $0 + files.totalRegularFileSize(at: $1) }
        return AppCacheCleanupResult(reclaimedBytes: max(0, originalBytes - remainingBytes), succeeded: succeeded)
    }

    /// 该方法清空文稿、应用支持、缓存和临时目录中的内容。
    private func clearSandboxFileData() -> Bool {
        let directories: [FileManager.SearchPathDirectory] = [
            .documentDirectory,
            .applicationSupportDirectory,
            .cachesDirectory,
        ]
        let urls = Set(directories.compactMap { files.directoryURL($0) } + [files.temporaryDirectoryURL])
        var succeeded = true
        for url in urls { succeeded = files.removeContents(of: url) && succeeded }
        return succeeded
    }

}
