import StorageCore
import ScheduleContracts
import Foundation
import OSLog

/// App 持久化路径、当前账号会话和本地文件服务的统一入口。
enum AppFileDirectories {
    nonisolated static let files: any AppFileService = {
#if BIT101_UI_TESTING
        return UITestAppFileService()
#else
        return AppFileSystem.files
#endif
    }()
    @concurrent
    static func preparePersistentBackups() async {
        let logger = Logger(subsystem: "BIT101", category: "PersistentBackup")
        for directory in [FileManager.SearchPathDirectory.libraryDirectory, .documentDirectory, .applicationSupportDirectory] {
            guard let url = files.directoryURL(directory), files.fileExists(at: url) else { continue }
            do { try files.setBackupExcluded(false, at: url, recursively: directory != .libraryDirectory) }
            catch { logger.error("Persistent backup metadata awaits preparation: \(error.localizedDescription, privacy: .public)") }
        }
    }

    nonisolated static var defaultsDomain: String {
#if BIT101_UI_TESTING
        if isRunningUITest { return uiTestDefaultsSuiteName }
#endif
        guard let identifier = Bundle.main.bundleIdentifier else {
            preconditionFailure("App preferences domain is unavailable")
        }
        return identifier
    }

    nonisolated static var defaults: UserDefaults {
#if BIT101_UI_TESTING
        if isRunningUITest {
            guard let suite = UserDefaults(suiteName: uiTestDefaultsSuiteName) else {
                preconditionFailure("UI test defaults suite is unavailable")
            }
            return suite
        }
#endif
        return .standard
    }

#if BIT101_UI_TESTING
    nonisolated static var isRunningUITest: Bool {
        let process = ProcessInfo.processInfo
        return process.arguments.contains("--ui-testing")
            && process.environment["BIT101_UI_TESTING"] == "1"
            && !(process.environment["BIT101_UI_TEST_RUN_ID"] ?? "").isEmpty
    }

    nonisolated static var uiTestRunIdentifier: String {
        let rawValue = ProcessInfo.processInfo.environment["BIT101_UI_TEST_RUN_ID"] ?? ""
        guard !rawValue.isEmpty else { return "unconfigured" }
        return rawValue.utf8.map { String(format: "%02X", $0) }.joined()
    }

    nonisolated static var uiTestDefaultsSuiteName: String {
        "harrybit.BIT101-iOS.ui-tests.\(uiTestRunIdentifier)"
    }
#else
    nonisolated static let isRunningUITest = false
#endif

    nonisolated static let applicationSupport: URL = {
        guard let url = files.directoryURL(.applicationSupportDirectory) else {
            preconditionFailure("Application Support directory is unavailable")
        }
        return url
    }()

    @MainActor static var currentSession: AppStorageSession { AppAccountSession.currentSession }

    @MainActor static var scoreCacheSession: AppStorageSession {
#if BIT101_UI_TESTING
        if isRunningUITest { return currentSession }
#endif
#if ICLOUD_CROSS_DEVICE_SMOKE
        return currentSession
#elseif DEBUG
        let environment = ProcessInfo.processInfo.environment
        if NSClassFromString("XCTestCase") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil {
            return AppStorageSession(accountIdentifier: "__bit101_tests__")
        }
        return currentSession
#else
        return currentSession
#endif
    }

    nonisolated static func applicationSupportDirectoryURL(named directory: String) -> URL {
        applicationSupport.appending(path: directory, directoryHint: .isDirectory)
    }

    nonisolated static func accountSupportFileURL(
        accountDirectoryName: String,
        named filename: String
    ) -> URL {
        applicationSupport
            .appending(path: "BIT101-iOS", directoryHint: .isDirectory)
            .appending(path: accountDirectoryName, directoryHint: .isDirectory)
            .appending(path: filename)
    }

    nonisolated static func cacheDirectoryURL(named directory: String) -> URL? {
        files.directoryURL(.cachesDirectory)?.appending(path: directory, directoryHint: .isDirectory)
    }

    nonisolated static func documentFileURL(named filename: String) -> URL? {
        guard let directory = files.directoryURL(.documentDirectory) else { return nil }
        return directory.appending(path: filename)
    }

    nonisolated static func appGroupFileURL(
        groupIdentifier: String,
        directories: [String],
        named filename: String
    ) -> URL? {
        let container = files.appGroupContainerURL(identifier: groupIdentifier)
        if let container { try? files.setBackupExcluded(true, at: container) }
        return directories.reduce(container) { url, directory in
            url?.appending(path: directory, directoryHint: .isDirectory)
        }?.appending(path: filename)
    }
}
