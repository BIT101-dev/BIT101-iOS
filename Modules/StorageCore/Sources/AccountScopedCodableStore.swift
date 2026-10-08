import Foundation
import OSLog

private let accountScopedStoreLogger = Logger(
    subsystem: "BIT101-dev.BIT101-iOS",
    category: "AccountScopedStore"
)

public enum AccountScopedValueRead<Value> {
    case missing
    case value(Value)
    case unreadable

    public var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }
}

/// AccountScopedCodableStore 使用稳定前缀和账号后缀生成账号隔离的 Codable 快照存储键。
public struct AccountScopedCodableStore<Value: Codable> {
    private let keyPrefix: String
    private let defaults: UserDefaults
    private let session: () -> AppStorageSession
    private let guestIdentifier: String

    public init(
        keyPrefix: String,
        defaults: UserDefaults,
        sessionProvider: @escaping () -> AppStorageSession,
        guestIdentifier: String = "guest"
    ) {
        self.keyPrefix = keyPrefix
        self.defaults = defaults
        self.session = sessionProvider
        self.guestIdentifier = guestIdentifier
    }

    public func load() -> Value? { read().value }

    public func read() -> AccountScopedValueRead<Value> {
        let key = storageKey
        if let stored = defaults.object(forKey: key) {
            guard let data = stored as? Data, let value = decode(data) else { return .unreadable }
            return .value(value)
        }

        let legacyKey = session().legacyKey(keyPrefix, guestIdentifier: guestIdentifier)
        guard legacyKey != key, let stored = defaults.object(forKey: legacyKey) else { return .missing }
        guard let data = stored as? Data, let value = decode(data) else { return .unreadable }

        defaults.set(data, forKey: key)
        defaults.removeObject(forKey: legacyKey)
        return .value(value)
    }

    private func decode(_ data: Data) -> Value? {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            accountScopedStoreLogger.error(
                "Failed to decode account-scoped value keyPrefix=\(keyPrefix, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    @discardableResult
    public func save(_ value: Value) -> Bool {
        if case .unreadable = read() { return false }
        do {
            let data = try JSONEncoder().encode(value)
            let key = storageKey
            defaults.set(data, forKey: key)
            let legacyKey = session().legacyKey(keyPrefix, guestIdentifier: guestIdentifier)
            if legacyKey != key, let data = defaults.data(forKey: legacyKey), decode(data) != nil {
                defaults.removeObject(forKey: legacyKey)
            }
            return true
        } catch {
            accountScopedStoreLogger.error(
                "Failed to encode account-scoped value keyPrefix=\(keyPrefix, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    public func remove() {
        let key = storageKey
        defaults.removeObject(forKey: key)
        let legacyKey = session().legacyKey(keyPrefix, guestIdentifier: guestIdentifier)
        if legacyKey != key { defaults.removeObject(forKey: legacyKey) }
    }

    public var storageKey: String {
        session().key(keyPrefix, guestIdentifier: guestIdentifier)
    }
}

/// AccountScopedFileCodableStore 保存需要持久保留的账号快照。
public struct AccountScopedFileCodableStore<Value: Codable> {
    private let directory: URL
    private let filename: String
    private let files: any AppFileService
    private let session: () -> AppStorageSession

    public init(
        filename: String,
        files: any AppFileService,
        session: @escaping () -> AppStorageSession,
        directory: URL
    ) {
        self.directory = directory
        self.filename = filename
        self.files = files
        self.session = session
    }

    public var fileURL: URL {
        directory
            .appending(path: "BIT101-iOS", directoryHint: .isDirectory)
            .appending(path: session().accountStorageIdentifier, directoryHint: .isDirectory)
            .appending(path: filename)
    }

    public var hasStoredFile: Bool {
        files.fileExists(at: fileURL)
    }

    public func load() -> Value? {
        let sourceURL = fileURL
        guard files.fileExists(at: sourceURL) else {
            let oldURL = legacyFileURL
            guard oldURL != sourceURL, files.fileExists(at: oldURL) else { return nil }
            try? files.setPrivateFileProtection(at: oldURL)
            guard let data = try? files.readData(at: oldURL),
                  let value = try? JSONDecoder().decode(Value.self, from: data)
            else { return nil }
            _ = save(value)
            return value
        }
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
    public func save(_ value: Value) -> Bool {
        let targetURL = fileURL
        let existingURL = files.fileExists(at: targetURL) ? targetURL : legacyFileURL
        if files.fileExists(at: existingURL) {
            do {
                let existingData = try files.readData(at: existingURL)
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
            removeLegacyFileIfValid()
            return true
        } catch {
            accountScopedStoreLogger.error(
                "Failed to write account-scoped file filename=\(filename, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    public func remove() {
        let targetURL = fileURL
        if files.fileExists(at: targetURL) {
            do {
                try files.removeItem(at: targetURL)
            } catch {
                accountScopedStoreLogger.error(
                    "Failed to remove account-scoped file filename=\(filename, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
        }
        let oldURL = legacyFileURL
        if oldURL != targetURL, files.fileExists(at: oldURL) { try? files.removeItem(at: oldURL) }
    }

    private var legacyFileURL: URL {
        directory
            .appending(path: "BIT101-iOS", directoryHint: .isDirectory)
            .appending(path: session().legacyAccountDirectoryNameForMigration, directoryHint: .isDirectory)
            .appending(path: filename)
    }

    private func removeLegacyFileIfValid() {
        let oldURL = legacyFileURL
        guard oldURL != fileURL, files.fileExists(at: oldURL),
              let data = try? files.readData(at: oldURL),
              (try? JSONDecoder().decode(Value.self, from: data)) != nil
        else { return }
        try? files.removeItem(at: oldURL)
    }
}
