import Foundation
import OSLog
import ScheduleDomain
import StorageCore

/// 注入式日程磁盘仓库，账号路径与串行写入归单个实例维护。
public actor SchedulePersistenceStore {
    public nonisolated static let maximumCacheBytes = 16 * 1_024 * 1_024
    private nonisolated let files: any AppFileService
    private nonisolated let storageRoot: URL
    private let userStateMatches: @Sendable (ScheduleCache, ScheduleCache) throws -> Bool
    private nonisolated static let logger = Logger(subsystem: "BIT101", category: "ScheduleCache")
    private var lastReadFailure: (url: URL, summary: String)?

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

    public func readFailure(for session: AppStorageSession) -> String? {
        guard let failure = lastReadFailure,
              [session.accountStorageIdentifier, session.legacyAccountDirectoryNameForMigration]
                .contains(where: { cacheFileURL(for: $0) == failure.url }) else { return nil }
        return failure.summary
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let legacy = try? value.decode(String.self) {
                do { return try Date(legacy, strategy: .iso8601) }
                catch { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Schedule cache date requires ISO 8601.") }
            }
            return Date(timeIntervalSinceReferenceDate: try value.decode(Double.self))
        }
        return decoder
    }

    private func read(
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

    private func readCacheFile(at url: URL) -> ScheduleCacheLoadResult {
        if lastReadFailure?.url == url { lastReadFailure = nil }
        var operation = "protection"
        do {
            try files.setPrivateFileProtection(at: url)
            operation = "read"
            let data = try files.readData(at: url, maximumBytes: Self.maximumCacheBytes)
            let result = Self.decodeCache(data) { summary in
                lastReadFailure = (url, summary)
            }
            if let failure = lastReadFailure, failure.url == url {
                Self.logger.error("课表缓存解码失败，保留原文件：\(failure.summary, privacy: .public)")
            }
            return result
        } catch {
            if AppFileSystem.isMissingFile(error) { return .missing }
            let failure = error as NSError
            let summary = "file.\(operation):\(failure.domain).\(failure.code)"
            lastReadFailure = (url, summary)
            Self.logger.error("课表缓存读取失败，保留原文件：\(summary, privacy: .public)")
            return .unreadable
        }
    }

    public nonisolated static func decodeCache(_ data: Data, onFailure: (String) -> Void = { _ in }) -> ScheduleCacheLoadResult {
        guard data.count <= maximumCacheBytes else {
            onFailure("decode.sizeLimit")
            return .unreadable
        }
        do {
            return .loaded(try Self.makeDecoder().decode(ScheduleCache.self, from: data))
        } catch {
            onFailure(decodingFailureSummary(error))
            return .unreadable
        }
    }

    private nonisolated static func decodingFailureSummary(_ error: Error) -> String {
        let kind: String, path: [any CodingKey]
        switch error {
        case DecodingError.keyNotFound(let key, let context): kind = "missing"; path = context.codingPath + [key]
        case DecodingError.typeMismatch(_, let context): kind = "type"; path = context.codingPath
        case DecodingError.valueNotFound(_, let context): kind = "null"; path = context.codingPath
        case DecodingError.dataCorrupted(let context): kind = "invalid"; path = context.codingPath
        default: return "decode.error"
        }
        let fields: Set<String> = ["schemaVersion", "courseData", "ddlData", "classroomData", "presentation", "syncData", "updatedAt",
            "primaryScheduleTitle", "currentTerm", "manualFirstDayStringsByTerm", "manualCourseRulesByTerm", "customSchedules",
            "timeTable", "sharedSchedules", "schedulesByTerm", "archivedTerms", "firstDayString", "courses", "exams", "term",
            "id", "name", "teacher", "classroom", "description", "weeks", "weekday", "startSection", "endSection", "campus",
            "number", "credit", "hour", "type", "category", "department", "sourceIdentity", "sourceCourses", "replacementCourses",
            "title", "subtitle", "dateString", "additionalDateStrings", "beginTime", "endTime", "importedAt", "sharedAt",
            "lexueCalendarURL", "ddlEvents", "lexueDDLCompletionByID", "lexueDDLRetiredAtByID", "ddlUpdatedAt", "ddlBeforeDay",
            "ddlAfterDay", "group", "text", "dueAt", "done", "start", "end", "iCloudSyncEnabled", "cloudSyncBaselineAt",
            "cloudSyncBaselineRecordTag", "cloudSyncBaselineUserState", "hasUnpushedCloudChanges"]
        let location = path.map { key in key.intValue != nil ? "[]" : fields.contains(key.stringValue) ? key.stringValue : "*" }
        return "decode.\(kind):\(location.isEmpty ? "$" : location.joined(separator: "."))"
    }

    private func migrateLegacyIfNeeded(
        _ cache: ScheduleCache,
        accountIdentifier: String,
        legacyAccountIdentifier: String
    ) {
        guard accountIdentifier != legacyAccountIdentifier else { return }
        let currentURL = cacheFileURL(for: accountIdentifier)
        let legacyURL = cacheFileURL(for: legacyAccountIdentifier)
        guard case .missing = readCacheFile(at: currentURL),
              case .loaded = readCacheFile(at: legacyURL)
        else { return }

        do {
            try files.createDirectory(at: currentURL.deletingLastPathComponent())
            let data = try Self.makeEncoder().encode(cache)
            guard data.count <= Self.maximumCacheBytes else { throw CocoaError(.fileWriteOutOfSpace) }
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
        guard cache.isValidForPersistence else {
            Self.logger.error("日程记录结构无效，保留已有课表缓存")
            return nil
        }
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
            if source == .cloud { cache.hasUnpushedCloudChanges = false }
            if source == .local || source == .localWithoutCloudPush,
               let storedCache {
                guard cache.cloudSyncBaselineAt == storedCache.cloudSyncBaselineAt,
                      cache.cloudSyncBaselineRecordTag == storedCache.cloudSyncBaselineRecordTag,
                      cache.syncData.cloudSyncBaselineUserState == storedCache.syncData.cloudSyncBaselineUserState else {
                    Self.logger.error("云端基线已更新，保留磁盘数据和本机修改")
                    return nil
                }
                cache.cloudSyncBaselineAt = storedCache.cloudSyncBaselineAt
                cache.cloudSyncBaselineRecordTag = storedCache.cloudSyncBaselineRecordTag
                cache.syncData.cloudSyncBaselineUserState = storedCache.syncData.cloudSyncBaselineUserState
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
            guard data.count <= Self.maximumCacheBytes else { throw CocoaError(.fileWriteOutOfSpace) }
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
            for url in urls {
                try files.removeItemIfPresent(at: url)
                if lastReadFailure?.url == url { lastReadFailure = nil }
            }

            for directory in Set(urls.map({ $0.deletingLastPathComponent() })) {
                do {
                    if try files.contentsOfDirectory(at: directory, options: []).isEmpty {
                        try files.removeItemIfPresent(at: directory)
                    }
                } catch {
                    if !AppFileSystem.isMissingFile(error) { throw error }
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

/// 保存与清理共享实例队列，在操作开始和返回时核对所属会话。
@MainActor
public final class SchedulePersistenceCoordinator {
    private var pending: Task<Bool, Never>?
    private var revision = 0

    public init() {}

    @discardableResult
    public func perform(
        isCurrent: @escaping @MainActor () -> Bool,
        operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        let previous = pending
        revision &+= 1
        let request = revision
        let task = Task { @MainActor in
            _ = await previous?.value
            guard !Task.isCancelled, isCurrent() else { return false }
            return await operation()
        }
        pending = task
        let saved = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if revision == request { pending = nil }
        return saved && !Task.isCancelled && isCurrent()
    }
}
