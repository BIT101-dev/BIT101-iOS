import MediaKit
import StorageCore
import Foundation
import WebKit

struct AppCacheCleanupResult {
    let reclaimedBytes: Int64
    let succeeded: Bool
}

/// 应用本地数据清理由操作服务承接，页面绑定进度与结果。
@MainActor
struct AppLocalDataService {
    private let files: any AppFileService
    private let defaults: UserDefaults
    private let settings: AppSettingsStore

    init(
        files: any AppFileService = AppFileDirectories.files,
        defaults: UserDefaults = AppFileDirectories.defaults,
        settings: AppSettingsStore = .shared
    ) {
        self.files = files
        self.defaults = defaults
        self.settings = settings
    }

    func resetAllLocalData(onLogout: () -> Void) async -> Bool {
        let didClearLoginData = LoginStorage.shared.clearAllLocalData()
        onLogout()
        await ScheduleCacheStore.clear()
        let didClearSharedSnapshot = await ScheduleWidgetExporter.clearSharedSnapshot()
        let didClearSmokeArtifacts = ReleaseNetworkSmokeReportStore.clearLocalArtifacts()
        clearUserDefaults()
        let didClearSandboxFiles = clearSandboxFileData()
        URLCache.shared.removeAllCachedResponses()
        await clearWebData()
        settings.resetToDefaults()
        return didClearLoginData && didClearSharedSnapshot && didClearSmokeArtifacts && didClearSandboxFiles
    }

    func clearCaches() async -> AppCacheCleanupResult {
        let cachesURL = files.directoryURL(.cachesDirectory)
        let temporaryURL = files.temporaryDirectoryURL
        let reclaimedBytes = (cachesURL.map { files.totalRegularFileSize(at: $0) } ?? 0)
            + files.totalRegularFileSize(at: temporaryURL)
        var succeeded = true
        if let cachesURL { succeeded = files.removeContents(of: cachesURL) }
        succeeded = files.removeContents(of: temporaryURL) && succeeded
        URLCache.shared.removeAllCachedResponses()
        await AppMedia.environment.clearAvatars()
        return AppCacheCleanupResult(reclaimedBytes: reclaimedBytes, succeeded: succeeded)
    }

    private func clearUserDefaults() {
        if let bundleID = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleID)
        }
    }

    /// 该方法清空文稿、应用支持、缓存和临时目录中的内容。
    private func clearSandboxFileData() -> Bool {
        let directories: [FileManager.SearchPathDirectory] = [
            .documentDirectory,
            .applicationSupportDirectory,
            .cachesDirectory,
        ]
        var succeeded = true

        for directory in directories {
            guard let url = files.directoryURL(directory) else { continue }
            succeeded = files.removeContents(of: url) && succeeded
        }

        succeeded = files.removeContents(of: files.temporaryDirectoryURL) && succeeded
        return succeeded
    }

    /// 该方法清空 `WKWebView` 站点数据。
    private func clearWebData() async {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: dataTypes,
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }
}
