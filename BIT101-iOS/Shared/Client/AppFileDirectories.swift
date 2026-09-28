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
        "\(prefix).\(isGuest ? guestIdentifier : accountIdentifier)"
    }

    /// 账号级文件夹名沿用稳定的安全编码规则。
    var accountDirectoryName: String {
        guard !isGuest else { return "__default__" }
        let invalid = CharacterSet.alphanumerics.inverted
        guard accountIdentifier.rangeOfCharacter(from: invalid) != nil else { return accountIdentifier }
        return "__encoded__" + accountIdentifier.utf8.map { String(format: "%02X", $0) }.joined()
    }

    /// 旧版账号文件夹名，用于现有缓存迁移。
    var legacyAccountDirectoryName: String {
        guard !isGuest else { return "__default__" }
        let invalid = CharacterSet.alphanumerics.inverted
        return accountIdentifier.components(separatedBy: invalid).joined(separator: "_")
    }
}

/// App 持久化路径、当前账号会话和本地文件服务的统一入口。
enum AppFileDirectories {
    nonisolated static let files = AppFileSystem.files
    nonisolated static var defaults: UserDefaults { UserDefaults.standard }

    nonisolated static let applicationSupport: URL = {
        guard let url = files.directoryURL(.applicationSupportDirectory) else {
            preconditionFailure("Application Support directory is unavailable")
        }
        return url
    }()

    @MainActor static var currentSession: AppStorageSession {
        AppStorageSession(accountIdentifier: LoginStorage.shared.currentStudentID)
    }

    @MainActor static var scoreCacheSession: AppStorageSession {
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
        files.directoryURL(.documentDirectory)?.appending(path: filename)
    }

    nonisolated static func appGroupFileURL(
        groupIdentifier: String,
        directories: [String],
        named filename: String
    ) -> URL? {
        directories.reduce(files.appGroupContainerURL(identifier: groupIdentifier)) { url, directory in
            url?.appending(path: directory, directoryHint: .isDirectory)
        }?.appending(path: filename)
    }
}
