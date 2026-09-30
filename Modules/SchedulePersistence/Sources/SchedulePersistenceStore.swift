import Foundation
import OSLog
import ScheduleDomain
import StorageCore

public nonisolated enum ScheduleCacheTimestamp {
    public static func next(after previous: Date, now: Date) -> Date {
        max(now, previous.addingTimeInterval(0.001))
    }

    public static func restored(recordDate: Date, payloadDate: Date, serverDate: Date? = nil) -> Date? {
        guard abs(recordDate.timeIntervalSince(payloadDate)) <= 1.1 else { return nil }
        return max(recordDate, serverDate ?? recordDate)
    }

    public static func afterCloudSave(_ serverDate: Date, currentDate: Date) -> Date {
        max(serverDate, currentDate)
    }
}

/// 注入式日程磁盘仓库，账号路径与串行写入归单个实例维护。
public actor SchedulePersistenceStore {
    private nonisolated let files: any AppFileService
    private nonisolated let storageRoot: URL
    private let userStateMatches: @Sendable (ScheduleCache, ScheduleCache) throws -> Bool
    private nonisolated static let logger = Logger(subsystem: "BIT101", category: "ScheduleCache")

    public init(files: any AppFileService, storageRoot: URL, userStateMatches: @escaping @Sendable (ScheduleCache, ScheduleCache) throws -> Bool) {
        self.files = files
        self.storageRoot = storageRoot
        self.userStateMatches = userStateMatches
    }

    public func load(for session: AppStorageSession) -> ScheduleCacheLoadResult {
        let result = read(accountIdentifier: session.accountStorageIdentifier, legacyAccountIdentifier: session.legacyAccountDirectoryNameForMigration)
        if case .loaded(let cache) = result {
            migrateLegacyIfNeeded(cache, accountIdentifier: session.accountStorageIdentifier, legacyAccountIdentifier: session.legacyAccountDirectoryNameForMigration)
        }
        return result
    }

    public nonisolated func cacheFileURL(for accountIdentifier: String) -> URL {
        storageRoot.appending(path: accountIdentifier, directoryHint: .isDirectory).appending(path: "schedule-cache.json")
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public nonisolated func read(
        accountIdentifier: String,
        legacyAccountIdentifier: String
    ) -> ScheduleCacheLoadResult {
        let currentURL = cacheFileURL(for: accountIdentifier)
        let currentResult = readCacheFile(at: currentURL)
        switch currentResult {
        case .loaded, .unreadable:
            return currentResult
        case .missing:
            break
        }

        let legacyURL = cacheFileURL(for: legacyAccountIdentifier)
        guard legacyURL != currentURL else { return .missing }
        return readCacheFile(at: legacyURL)
    }

    private nonisolated func readCacheFile(at url: URL) -> ScheduleCacheLoadResult {
        guard files.fileExists(at: url) else { return .missing }
        do {
            try? files.setPrivateFileProtection(at: url)
            let data = try files.readData(at: url)
            let result = Self.decodeCache(data)
            if result.isUnreadable {
                Self.logger.error("课表缓存解码失败，保留原文件：\(url.lastPathComponent, privacy: .public)")
            }
            return result
        } catch {
            Self.logger.error("课表缓存读取失败，保留原文件：\(String(describing: error), privacy: .public)")
            return .unreadable
        }
    }

    public nonisolated static func decodeCache(_ data: Data) -> ScheduleCacheLoadResult {
        guard let cache = try? Self.makeDecoder().decode(ScheduleCache.self, from: data) else {
            return .unreadable
        }
        return .loaded(cache)
    }

    private func migrateLegacyIfNeeded(
        _ cache: ScheduleCache,
        accountIdentifier: String,
        legacyAccountIdentifier: String
    ) {
        guard accountIdentifier != legacyAccountIdentifier else { return }
        let currentURL = cacheFileURL(for: accountIdentifier)
        let legacyURL = cacheFileURL(for: legacyAccountIdentifier)
        guard !files.fileExists(at: currentURL),
              case .loaded = readCacheFile(at: legacyURL)
        else { return }

        do {
            try files.createDirectory(at: currentURL.deletingLastPathComponent())
            let data = try Self.makeEncoder().encode(cache)
            try files.writeData(
                data,
                to: currentURL,
                options: AppFileSystem.protectedDataWritingOptions
            )
            try files.removeItem(at: legacyURL)
            let directory = legacyURL.deletingLastPathComponent()
            if (try? files.contentsOfDirectory(at: directory, options: []).isEmpty) == true {
                try files.removeItem(at: directory)
            }
        } catch {
            Self.logger.error("旧课表缓存迁移失败：\(String(describing: error), privacy: .public)")
        }
    }

    public func write(
        _ cache: ScheduleCache,
        accountIdentifier: String,
        legacyAccountIdentifier: String,
        source: ScheduleCacheSaveSource,
        expectedUpdatedAt: Date?
    ) -> ScheduleCache? {
        let url = cacheFileURL(for: accountIdentifier)
        let directory = url.deletingLastPathComponent()
        let currentResult = readCacheFile(at: url)
        guard currentResult.allowsWrite else {
            Self.logger.error("保留无法读取的课表缓存，跳过保存")
            return nil
        }
        var storedUpdatedAt = Date.distantPast
        var storedCache: ScheduleCache?
        if case .loaded(let currentCache) = currentResult {
            storedUpdatedAt = currentCache.updatedAt
            storedCache = currentCache
        }
        if case .missing = currentResult,
           legacyAccountIdentifier != accountIdentifier
        {
            let legacyURL = cacheFileURL(for: legacyAccountIdentifier)
            let legacyResult = readCacheFile(at: legacyURL)
            guard legacyResult.allowsWrite else {
                Self.logger.error("保留无法读取的旧版课表缓存，跳过保存")
                return nil
            }
            if case .loaded(let legacyCache) = legacyResult {
                storedUpdatedAt = legacyCache.updatedAt
                storedCache = legacyCache
            }
        }
        if let expectedUpdatedAt, expectedUpdatedAt != storedUpdatedAt {
            Self.logger.debug("缓存写入跳过，磁盘版本已变化")
            return nil
        }

        do {
            var cache = cache
            if source == .local || source == .localWithoutCloudPush,
               let storedCache {
                cache.cloudSyncBaselineAt = storedCache.cloudSyncBaselineAt
                cache.cloudSyncBaselineRecordTag = storedCache.cloudSyncBaselineRecordTag
                let userStateChanged = try !userStateMatches(cache, storedCache)
                cache.hasUnpushedCloudChanges = storedCache.hasUnpushedCloudChanges
                    || (cache.iCloudSyncEnabled && userStateChanged)
                cache.updatedAt = ScheduleCacheTimestamp.next(
                    after: max(storedCache.updatedAt, storedCache.cloudSyncBaselineAt),
                    now: cache.updatedAt
                )
            }
            try files.createDirectory(at: directory)
            let data = try Self.makeEncoder().encode(cache)
            try files.writeData(
                data,
                to: url,
                options: AppFileSystem.protectedDataWritingOptions
            )
            removeMigratedCacheIfPossible(
                accountIdentifier: accountIdentifier,
                legacyAccountIdentifier: legacyAccountIdentifier
            )
            return cache
        } catch {
            Self.logger.error("保存课表缓存失败：\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func clear(urls: [URL]) -> Bool {
        do {
            for url in urls where files.fileExists(at: url) {
                try files.removeItem(at: url)
            }

            for directory in Set(urls.map({ $0.deletingLastPathComponent() })) {
                if files.fileExists(at: directory),
                   (try? files.contentsOfDirectory(at: directory, options: []).isEmpty) == true {
                    try files.removeItem(at: directory)
                }
            }
        } catch {
            Self.logger.error("清理课表缓存失败：\(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    private func removeMigratedCacheIfPossible(
        accountIdentifier: String,
        legacyAccountIdentifier: String
    ) {
        guard accountIdentifier != legacyAccountIdentifier else { return }
        let legacyURL = cacheFileURL(for: legacyAccountIdentifier)
        guard case .loaded = readCacheFile(at: legacyURL) else { return }
        do {
            try files.removeItem(at: legacyURL)
            let directory = legacyURL.deletingLastPathComponent()
            if (try? files.contentsOfDirectory(at: directory, options: []).isEmpty) == true {
                try files.removeItem(at: directory)
            }
        } catch {
            Self.logger.error("迁移旧课表缓存清理失败：\(String(describing: error), privacy: .public)")
        }
    }
}
