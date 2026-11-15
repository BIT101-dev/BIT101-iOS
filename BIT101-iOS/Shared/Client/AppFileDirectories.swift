import Foundation
import OSLog
import ScheduleContracts
import StorageCore

/// App 持久化路径、当前账号会话和本地文件服务的统一入口。
enum AppFileDirectories {
    nonisolated static let files: any AppFileService = {
        #if DEBUG
        if isRunningUITest || isRunningIsolatedUnitTest || isRunningIsolatedNetworkSmoke {
            guard let support = AppFileSystem.files.directoryURL(.applicationSupportDirectory)
            else {
                preconditionFailure("Automated test Application Support directory is unavailable")
            }
            let folder = isRunningIsolatedNetworkSmoke ? "BIT101-NetworkSmoke" : "BIT101-UITests"
            return ScopedAppFileService(
                root: support.appending(path: folder, directoryHint: .isDirectory))
        }
        #endif
        return AppFileSystem.files
    }()
    private nonisolated static let persistentBackupPreparation = Task {
        await migrateBackupMetadata(files: files)
    }

    static func preparePersistentBackups() async {
        await persistentBackupPreparation.value
    }

    /// 历史文件迁移一次备份元数据，日常写入沿用文件服务的目录策略。
    @concurrent
    static func migrateBackupMetadata(files: any AppFileService, defaultsDomain: String? = nil)
        async
    {
        let defaults = Self.defaults(inDomain: defaultsDomain)
        let key = "storage.persistent-backup-metadata.prepared"
        guard !defaults.bool(forKey: key) else { return }
        let logger = Logger(subsystem: "BIT101", category: "PersistentBackup")
        var completed = true
        for directory in [
            FileManager.SearchPathDirectory.libraryDirectory, .documentDirectory,
            .applicationSupportDirectory,
        ] {
            guard let url = files.directoryURL(directory), files.fileExists(at: url) else {
                continue
            }
            do {
                try files.setBackupExcluded(
                    false, at: url, recursively: directory != .libraryDirectory)
            } catch {
                completed = false
                logger.error(
                    """
                    Persistent backup metadata awaits preparation: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
        if completed { defaults.set(true, forKey: key) }
    }

    nonisolated static var defaultsDomain: String {
        #if DEBUG
        if isRunningIsolatedUnitTest { return "harrybit.BIT101-iOS.tests" }
        if isRunningUITest { return uiTestDefaultsSuiteName }
        if isRunningIsolatedNetworkSmoke { return preparedNetworkSmokeDefaultsDomain }
        #endif
        guard let identifier = Bundle.main.bundleIdentifier else {
            preconditionFailure("App preferences domain is unavailable")
        }
        return identifier
    }

    nonisolated static func defaults(inDomain domain: String?) -> UserDefaults {
        guard let domain else { return defaults }
        guard let suite = UserDefaults(suiteName: domain) else {
            preconditionFailure("Injected preferences domain requires a valid suite")
        }
        return suite
    }

    nonisolated static var defaults: UserDefaults {
        #if DEBUG
        if isRunningIsolatedUnitTest {
            guard let suite = UserDefaults(suiteName: preparedAutomatedTestDefaultsDomain) else {
                preconditionFailure("Automated test defaults suite is unavailable")
            }
            return suite
        }
        if isRunningUITest {
            guard let suite = UserDefaults(suiteName: uiTestDefaultsSuiteName) else {
                preconditionFailure("UI test defaults suite is unavailable")
            }
            return suite
        }
        if isRunningIsolatedNetworkSmoke {
            guard let suite = UserDefaults(suiteName: preparedNetworkSmokeDefaultsDomain) else {
                preconditionFailure("Network smoke defaults suite is unavailable")
            }
            return suite
        }
        #endif
        return .standard
    }

    #if DEBUG
    nonisolated static var isRunningICloudSmoke: Bool {
        !(ProcessInfo.processInfo.environment["BIT101_ICLOUD_SMOKE_RUN_ID"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static var isRunningNetworkSmoke: Bool {
        guard !isRunningICloudSmoke else { return false }
        let environment = ProcessInfo.processInfo.environment
        return environment["BIT101_NETWORK_SMOKE_HOST"] == "1"
            || !(environment["BIT101_NETWORK_SMOKE_SCOPE"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ReleaseNetworkSmokeLaunchRequest.hasPendingFile
    }

    nonisolated static var isRunningUITest: Bool {
        guard !isRunningICloudSmoke, !isRunningNetworkSmoke else { return false }
        let process = ProcessInfo.processInfo
        return process.arguments.contains("--ui-testing")
            && !(process.environment["BIT101_UI_TEST_RUN_ID"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static var isRunningIsolatedUnitTest: Bool {
        guard !isRunningICloudSmoke, !isRunningNetworkSmoke, !isRunningUITest else {
            return false
        }
        let environment = ProcessInfo.processInfo.environment
        guard environment["BIT101_PRODUCTION_RUNTIME_TEST"] != "1" else { return false }
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    nonisolated static var isRunningAutomatedHost: Bool {
        isRunningICloudSmoke || isRunningNetworkSmoke || isRunningUITest
            || isRunningIsolatedUnitTest
    }

    nonisolated static var isRunningIsolatedNetworkSmoke: Bool {
        isRunningNetworkSmoke
            && ProcessInfo.processInfo.environment["BIT101_NETWORK_SMOKE_ISOLATED"] == "1"
    }

    nonisolated static var uiTestRunIdentifier: String {
        let rawValue = ProcessInfo.processInfo.environment["BIT101_UI_TEST_RUN_ID"] ?? ""
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unconfigured" }
        return trimmed.utf8.map { String(format: "%02X", $0) }.joined()
    }

    nonisolated static var uiTestDefaultsSuiteName: String {
        "harrybit.BIT101-iOS.ui-tests.\(uiTestRunIdentifier)"
    }

    nonisolated private static let preparedAutomatedTestDefaultsDomain: String = {
        let domain = "harrybit.BIT101-iOS.tests"
        guard let suite = UserDefaults(suiteName: domain) else {
            preconditionFailure("Automated test defaults suite is unavailable")
        }
        suite.removePersistentDomain(forName: domain)
        return domain
    }()

    nonisolated private static let preparedNetworkSmokeDefaultsDomain: String = {
        let pid = ProcessInfo.processInfo.processIdentifier
        let domain = "harrybit.BIT101-iOS.network-smoke.\(pid)"
        guard let suite = UserDefaults(suiteName: domain) else {
            preconditionFailure("Network smoke defaults suite is unavailable")
        }
        suite.removePersistentDomain(forName: domain)
        return domain
    }()
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

    @MainActor static var scoreCacheSession: AppStorageSession { currentSession }

    nonisolated static func appSupportURL(named directory: String) -> URL {
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
        if let container {
            do { try files.setBackupExcluded(true, at: container) } catch {
                Logger(subsystem: "BIT101", category: "PersistentBackup").error(
                    """
                    App Group backup metadata awaits preparation: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
        return directories.reduce(container) { url, directory in
            url?.appending(path: directory, directoryHint: .isDirectory)
        }?.appending(path: filename)
    }
}

/// 验收宿主的文件与缓存目录归调用方指定的固定隔离根路径。
nonisolated struct ScopedAppFileService: AppFileService {
    private let local = LocalAppFileService()
    let root: URL
    func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL? {
        root.appending(path: String(directory.rawValue), directoryHint: .isDirectory)
    }
    func appGroupContainerURL(identifier: String) -> URL? {
        root.appending(path: "AppGroup", directoryHint: .isDirectory)
    }
    var temporaryDirectoryURL: URL {
        root.appending(path: "Temporary", directoryHint: .isDirectory)
    }
    func fileExists(at url: URL) -> Bool { local.fileExists(at: url) }
    func readData(at url: URL) throws -> Data { try local.readData(at: url) }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try local.writeData(data, to: url, options: options)
    }
    func createDirectory(at url: URL) throws { try local.createDirectory(at: url) }
    func removeItem(at url: URL) throws { try local.removeItem(at: url) }
    func setPrivateFileProtection(at url: URL) throws {
        try local.setPrivateFileProtection(at: url)
    }
    func setBackupExcluded(_ excluded: Bool, at url: URL, recursively: Bool) throws {
        try local.setBackupExcluded(excluded, at: url, recursively: recursively)
    }
    func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws
        -> [URL]
    { try local.contentsOfDirectory(at: url, options: options) }
    func regularFileSize(at url: URL) -> Int? { local.regularFileSize(at: url) }
    func atomicFileIdentity(at url: URL) -> String? { local.atomicFileIdentity(at: url) }
    func isRegularFile(at url: URL) -> Bool { local.isRegularFile(at: url) }
    func modificationDate(at url: URL) -> Date? { local.modificationDate(at: url) }
    func setModificationDate(_ date: Date, at url: URL) throws {
        try local.setModificationDate(date, at: url)
    }
    func removeContents(of directory: URL) -> Bool { local.removeContents(of: directory) }
    func totalRegularFileSize(at directory: URL) -> Int64 {
        local.totalRegularFileSize(at: directory)
    }
    func canonicalFileURL(_ url: URL) -> URL { local.canonicalFileURL(url) }
}
