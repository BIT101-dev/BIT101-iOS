import Foundation

/// 当前登录账号的本地存储会话。
///
/// 业务模块按当前用户读写数据；账号标识、稳定键后缀与磁盘目录名由存储层统一映射。
nonisolated struct AppStorageSession: Sendable, Equatable {
    let accountIdentifier: String

    init(accountIdentifier: String) {
        self.accountIdentifier = accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isGuest: Bool { accountIdentifier.isEmpty }

    func key(_ prefix: String, guestIdentifier: String = "guest") -> String {
        "\(prefix).\(isGuest ? guestIdentifier : accountStorageIdentifier)"
    }

    /// Previous defaults key used the account identifier verbatim.
    func legacyKey(_ prefix: String, guestIdentifier: String = "guest") -> String {
        "\(prefix).\(isGuest ? guestIdentifier : accountIdentifier)"
    }

    /// 保留旧版账号映射，供 CloudKit 标识和本地数据迁移沿用。
    var accountDirectoryName: String {
        guard !isGuest else { return "__default__" }
        let invalid = CharacterSet.alphanumerics.inverted
        guard accountIdentifier.rangeOfCharacter(from: invalid) != nil else { return accountIdentifier }
        return "__encoded__" + accountIdentifier.utf8.map { String(format: "%02X", $0) }.joined()
    }

    /// 本地存储使用稳定摘要作为账号命名空间。
    var accountStorageIdentifier: String {
        guard !isGuest else { return "__default__" }
#if BIT101_UI_TESTING
        if accountIdentifier.hasPrefix("__ui_tests__.") { return accountDirectoryName }
#endif
        return ScheduleSharedAccountIdentity.stableToken(for: accountIdentifier)
    }

    /// 旧版账号文件夹名，用于现有缓存迁移。
    var legacyAccountDirectoryName: String {
        guard !isGuest else { return "__default__" }
        let invalid = CharacterSet.alphanumerics.inverted
        return accountIdentifier.components(separatedBy: invalid).joined(separator: "_")
    }

    /// 兼容迁移沿用既有稳定账号目录名；规范化旧目录保留为独立历史路径。
    var legacyAccountDirectoryNameForMigration: String {
        accountDirectoryName
    }
}

/// App 持久化路径、当前账号会话和本地文件服务的统一入口。
enum AppFileDirectories {
    nonisolated static let files = AppFileSystem.files
    private nonisolated static let backupExclusionConfiguration: Bool = {
        for directory in [FileManager.SearchPathDirectory.libraryDirectory, .documentDirectory] {
            if let url = files.directoryURL(directory) {
                try? files.setExcludedFromBackup(at: url)
            }
        }
        return true
    }()

    nonisolated static var defaults: UserDefaults {
        _ = backupExclusionConfiguration
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
        try? files.setExcludedFromBackup(at: url)
        return url
    }()

    @MainActor static var currentSession: AppStorageSession {
#if BIT101_UI_TESTING
        if isRunningUITest {
            let studentID = defaults.string(forKey: "ui-test.session.student-id") ?? ""
            let isolatedAccount = studentID.isEmpty ? "guest" : studentID
            return AppStorageSession(accountIdentifier: "__ui_tests__.\(uiTestRunIdentifier).\(isolatedAccount)")
        }
#endif
        return AppStorageSession(accountIdentifier: LoginStorage.shared.currentStudentID)
    }

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
        try? files.setExcludedFromBackup(at: directory)
        return directory.appending(path: filename)
    }

    nonisolated static func appGroupFileURL(
        groupIdentifier: String,
        directories: [String],
        named filename: String
    ) -> URL? {
        let container = files.appGroupContainerURL(identifier: groupIdentifier)
        if let container { try? files.setExcludedFromBackup(at: container) }
        return directories.reduce(container) { url, directory in
            url?.appending(path: directory, directoryHint: .isDirectory)
        }?.appending(path: filename)
    }
}
