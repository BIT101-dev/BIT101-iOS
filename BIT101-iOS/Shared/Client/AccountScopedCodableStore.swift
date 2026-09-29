import Foundation
import OSLog

private let accountScopedStoreLogger = Logger(
    subsystem: "BIT101-dev.BIT101-iOS",
    category: "AccountScopedStore"
)

/// AccountScopedCodableStore 使用稳定前缀和账号后缀生成账号隔离的 Codable 快照存储键。
struct AccountScopedCodableStore<Value: Codable> {
    private let keyPrefix: String
    private let defaults: UserDefaults
    private let session: () -> AppStorageSession

    init(
        keyPrefix: String,
        defaults: UserDefaults = AppFileDirectories.defaults,
        session: @escaping () -> AppStorageSession = { AppFileDirectories.currentSession }
    ) {
        self.keyPrefix = keyPrefix
        self.defaults = defaults
        self.session = session
    }

    func load() -> Value? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            accountScopedStoreLogger.error(
                "Failed to decode account-scoped value keyPrefix=\(keyPrefix, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    func save(_ value: Value) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: storageKey)
        } catch {
            accountScopedStoreLogger.error(
                "Failed to encode account-scoped value keyPrefix=\(keyPrefix, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    func remove() {
        defaults.removeObject(forKey: storageKey)
    }

    var storageKey: String {
        session().key(keyPrefix)
    }
}

/// AccountScopedFileCodableStore 保存需要持久保留的账号快照。
struct AccountScopedFileCodableStore<Value: Codable> {
    private let filename: String
    private let files: any AppFileService
    private let session: () -> AppStorageSession

    init(
        filename: String,
        files: any AppFileService = AppFileDirectories.files,
        session: @escaping () -> AppStorageSession = { AppFileDirectories.currentSession }
    ) {
        self.filename = filename
        self.files = files
        self.session = session
    }

    var fileURL: URL {
        AppFileDirectories.accountSupportFileURL(
            accountDirectoryName: session().accountDirectoryName,
            named: filename
        )
    }

    var hasStoredFile: Bool {
        files.fileExists(at: fileURL)
    }

    func load() -> Value? {
        let sourceURL = fileURL
        guard files.fileExists(at: sourceURL) else { return nil }
        try? files.setPrivateFileProtection(at: sourceURL)
        guard let data = try? files.readData(at: sourceURL) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            accountScopedStoreLogger.error(
                "Failed to decode account-scoped file filename=\(filename, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    @discardableResult
    func save(_ value: Value) -> Bool {
        let targetURL = fileURL
        if files.fileExists(at: targetURL) {
            do {
                let existingData = try files.readData(at: targetURL)
                _ = try JSONDecoder().decode(Value.self, from: existingData)
            } catch {
                accountScopedStoreLogger.error(
                    "Account-scoped file write skipped after existing snapshot validation failed filename=\(filename, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                return false
            }
        }

        do {
            try files.createDirectory(at: targetURL.deletingLastPathComponent())
            let data = try JSONEncoder().encode(value)
            try files.writeData(
                data,
                to: targetURL,
                options: AppFileSystem.protectedDataWritingOptions
            )
            return true
        } catch {
            accountScopedStoreLogger.error(
                "Failed to write account-scoped file filename=\(filename, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    func remove() {
        let targetURL = fileURL
        guard files.fileExists(at: targetURL) else { return }
        do {
            try files.removeItem(at: targetURL)
        } catch {
            accountScopedStoreLogger.error(
                "Failed to remove account-scoped file filename=\(filename, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }
}
