import StorageCore
import Foundation

struct AppCacheCleanupResult {
    let reclaimedBytes: Int64
    let succeeded: Bool
}

/// 清理能力与资源归属由应用组装入口选择。
@MainActor
struct AppLocalDataActions {
    let clearLogin: () -> Bool
    let clearSchedule: () async -> Bool
    let clearSharedSnapshot: () async -> Bool
    let clearReports: () -> Bool
    let clearPreferences: () -> Void
    let clearURLCache: () -> Void
    let clearWebData: () async -> Void
    let clearMedia: () async -> Void
    let resetSettings: () -> Void
}

/// 应用本地数据清理由操作服务承接，页面绑定进度与结果。
@MainActor
struct AppLocalDataService {
    private let files: any AppFileService
    private let actions: AppLocalDataActions

    init(files: any AppFileService, actions: AppLocalDataActions) {
        self.files = files
        self.actions = actions
    }

    func resetAllLocalData(onLogout: () -> Void) async -> Bool {
        let didClearLoginData = actions.clearLogin()
        onLogout()
        let didClearSchedule = await actions.clearSchedule()
        let didClearSharedSnapshot = await actions.clearSharedSnapshot()
        let didClearSmokeArtifacts = actions.clearReports()
        actions.clearPreferences()
        let didClearSandboxFiles = clearSandboxFileData()
        actions.clearURLCache()
        await actions.clearWebData()
        await actions.clearMedia()
        actions.resetSettings()
        return didClearLoginData && didClearSchedule && didClearSharedSnapshot && didClearSmokeArtifacts && didClearSandboxFiles
    }

    func clearCaches() async -> AppCacheCleanupResult {
        let directories = Set([files.directoryURL(.cachesDirectory), files.temporaryDirectoryURL].compactMap { $0 })
        let reclaimedBytes = directories.reduce(Int64(0)) { $0 + files.totalRegularFileSize(at: $1) }
        var succeeded = true
        for directory in directories { succeeded = files.removeContents(of: directory) && succeeded }
        actions.clearURLCache()
        await actions.clearMedia()
        return AppCacheCleanupResult(reclaimedBytes: reclaimedBytes, succeeded: succeeded)
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
