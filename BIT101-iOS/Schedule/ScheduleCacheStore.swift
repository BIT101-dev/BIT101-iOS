//
//  ScheduleCacheStore.swift
//  BIT101-iOS
//
import Foundation
import OSLog

nonisolated enum ScheduleCacheTimestamp {
    static func next(after previous: Date, now: Date) -> Date {
        max(now, previous.addingTimeInterval(0.001))
    }

    static func restored(recordDate: Date, payloadDate: Date, serverDate: Date? = nil) -> Date? {
        guard abs(recordDate.timeIntervalSince(payloadDate)) <= 1.1 else { return nil }
        return max(recordDate, serverDate ?? recordDate)
    }

    static func afterCloudSave(_ serverDate: Date, currentDate: Date) -> Date {
        max(serverDate, currentDate)
    }
}

/// 日程模块本地缓存仓库。
///
/// 统一负责 `ScheduleCache` 的磁盘读写和变更通知发送。
enum ScheduleCacheStore {
    nonisolated enum LoadResult: Sendable {
        case loaded(ScheduleCache)
        case missing
        case unreadable

        var isUnreadable: Bool {
            if case .unreadable = self { return true }
            return false
        }

        var allowsWrite: Bool { !isUnreadable }

        var cacheIfReadable: ScheduleCache? {
            switch self {
            case .loaded(let cache): return cache
            case .missing: return ScheduleCache()
            case .unreadable: return nil
            }
        }
    }

    nonisolated enum SaveSource: Sendable {
        case local
        case localWithoutCloudPush
        case cloud
    }

    fileprivate nonisolated static func makeEncoder() -> JSONEncoder {
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

    fileprivate nonisolated static let logger = Logger(subsystem: "BIT101", category: "ScheduleCache")
    private static let writeQueue = ScheduleCacheWriteQueue()
    private static var diskOperationTask: Task<Bool, Never>?
    private static var diskOperationID: UUID?
    private static var exportOperationTask: Task<Void, Never>?
    private static var exportOperationID: UUID?

    /// 当前账号对应的缓存文件路径。
    ///
    /// 路径按当前学号区分账号缓存。
    private static var fileURL: URL {
        cacheFileURL(for: AppFileDirectories.currentSession.accountDirectoryName)
    }

    /// 读取当前账号的缓存快照。
    static func load() -> ScheduleCache {
        loadResult(
            accountIdentifier: AppFileDirectories.currentSession.accountDirectoryName,
            legacyAccountIdentifier: legacyAccountIdentifier()
        ).cacheIfReadable ?? ScheduleCache()
    }

    static func loadResultAsync() async -> LoadResult {
        let accountIdentifier = AppFileDirectories.currentSession.accountDirectoryName
        let legacyIdentifier = legacyAccountIdentifier()
        return await Task.detached(priority: .utility) {
            Self.loadResult(
                accountIdentifier: accountIdentifier,
                legacyAccountIdentifier: legacyIdentifier
            )
        }.value
    }

    /// 将缓存文件读取与解码移到独立任务，避免页面恢复阶段阻塞 MainActor。
    static func loadAsync() async -> ScheduleCache {
        await loadResultAsync().cacheIfReadable ?? ScheduleCache()
    }

    /// 写回缓存，并导出小组件快照、发送全局变更通知。
    static func save(_ cache: ScheduleCache, source: SaveSource = .local) {
        Task { await saveAndWait(cache, source: source) }
    }

    @discardableResult
    static func saveAndWait(
        _ cache: ScheduleCache,
        source: SaveSource = .local,
        expectedAccountIdentifier: String? = nil,
        expectedUpdatedAt: Date? = nil
    ) async -> Bool {
        var cacheToSave = cache
        if source == .cloud {
            cacheToSave.hasUnpushedCloudChanges = false
        } else {
            cacheToSave.updatedAt = ScheduleCacheTimestamp.next(
                after: max(cache.updatedAt, cache.cloudSyncBaselineAt),
                now: Date()
            )
            if cacheToSave.iCloudSyncEnabled {
                cacheToSave.hasUnpushedCloudChanges = true
            }
        }
        let accountIdentifier = AppFileDirectories.currentSession.accountDirectoryName
        guard expectedAccountIdentifier == nil || expectedAccountIdentifier == accountIdentifier else {
            return false
        }
        let legacyIdentifier = legacyAccountIdentifier()
        let operationID = UUID()
        let previousTask = diskOperationTask
        let writeTask = Task<Bool, Never> {
            _ = await previousTask?.value
            let didWrite = await writeQueue.write(
                cacheToSave,
                accountIdentifier: accountIdentifier,
                legacyAccountIdentifier: legacyIdentifier,
                expectedUpdatedAt: expectedUpdatedAt
            )
            if diskOperationID == operationID {
                diskOperationTask = nil
                diskOperationID = nil
            }
            return didWrite
        }
        diskOperationTask = writeTask
        diskOperationID = operationID
        let exportID = UUID()
        let previousExportTask = exportOperationTask
        let exportTask = Task<Void, Never> {
            await previousExportTask?.value
            if await writeTask.value {
                await finishSave(cacheToSave, accountIdentifier: accountIdentifier, source: source)
            }
            if exportOperationID == exportID {
                exportOperationTask = nil
                exportOperationID = nil
            }
        }
        exportOperationTask = exportTask
        exportOperationID = exportID
        await exportTask.value
        return await writeTask.value
    }

    /// 清空当前账号的日程缓存。
    ///
    /// 清空操作定位当前账号目录，并保留其它账号目录。
    static func clear() async {
        let urls = cacheURLs()
        let operationID = UUID()
        let previousTask = diskOperationTask
        let clearTask = Task<Bool, Never> {
            _ = await previousTask?.value
            let didClear = await writeQueue.clear(urls: urls)
            if diskOperationID == operationID {
                diskOperationTask = nil
                diskOperationID = nil
            }
            return didClear
        }
        diskOperationTask = clearTask
        diskOperationID = operationID
        let exportID = UUID()
        let previousExportTask = exportOperationTask
        let clearExportTask = Task<Void, Never> {
            await previousExportTask?.value
            if await clearTask.value {
                await ScheduleWidgetExporter.syncFromCurrentCache()
                postCacheDidChange()
            }
            if exportOperationID == exportID {
                exportOperationTask = nil
                exportOperationID = nil
            }
        }
        exportOperationTask = clearExportTask
        exportOperationID = exportID
        _ = await clearTask.value
        await clearExportTask.value
    }

    private static func finishSave(
        _ cache: ScheduleCache,
        accountIdentifier: String,
        source: SaveSource
    ) async {
        guard AppFileDirectories.currentSession.accountDirectoryName == accountIdentifier else { return }
#if BIT101_UI_TESTING
        if AppFileDirectories.isRunningUITest {
            postCacheDidChange()
            return
        }
#endif
        await ScheduleWidgetExporter.syncAsync(cache: cache)
        postCacheDidChange()

        #if canImport(CloudKit)
        if source == .local, cache.iCloudSyncEnabled {
            Task {
                await ScheduleCloudSyncManager.shared.pushLatestLocalCacheIfNeeded()
            }
        }
        #endif
    }

    fileprivate nonisolated static func loadResult(
        accountIdentifier: String,
        legacyAccountIdentifier: String
    ) -> LoadResult {
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

    fileprivate nonisolated static func readCacheFile(at url: URL) -> LoadResult {
        guard AppFileDirectories.files.fileExists(at: url) else { return .missing }
        do {
            try? AppFileDirectories.files.setPrivateFileProtection(at: url)
            let data = try AppFileDirectories.files.readData(at: url)
            let result = decodeCache(data)
            if result.isUnreadable {
                logger.error("课表缓存解码失败，保留原文件：\(url.lastPathComponent, privacy: .public)")
            }
            return result
        } catch {
            logger.error("课表缓存读取失败，保留原文件：\(String(describing: error), privacy: .public)")
            return .unreadable
        }
    }

    nonisolated static func decodeCache(_ data: Data) -> LoadResult {
        guard let cache = try? makeDecoder().decode(ScheduleCache.self, from: data) else {
            return .unreadable
        }
        return .loaded(cache)
    }

    private static func cacheURLs() -> [URL] {
        let current = fileURL
        let legacy = cacheFileURL(for: legacyAccountIdentifier())
        return current == legacy ? [current] : [current, legacy]
    }

    fileprivate nonisolated static func cacheFileURL(for accountIdentifier: String) -> URL {
        AppFileDirectories.accountSupportFileURL(
            accountDirectoryName: accountIdentifier,
            named: "schedule-cache.json"
        )
    }

    private static func legacyAccountIdentifier() -> String {
        AppFileDirectories.currentSession.legacyAccountDirectoryNameForMigration
    }

    /// 在主线程广播“课表缓存已变化”。
    ///
    /// 保存与清空缓存后都要发送这条通知，两个入口共用这一实现。
    fileprivate static func postCacheDidChange() {
        let accountIdentifier = AppFileDirectories.currentSession.accountDirectoryName
        Task { @MainActor in
            guard AppFileDirectories.currentSession.accountDirectoryName == accountIdentifier else { return }
            NotificationCenter.default.post(name: .scheduleCacheDidChange, object: accountIdentifier)
        }
    }
}

/// 串行处理缓存文件写入，保持快速连续编辑的保存顺序，并把编码和磁盘操作移出 MainActor。
private actor ScheduleCacheWriteQueue {
    func write(
        _ cache: ScheduleCache,
        accountIdentifier: String,
        legacyAccountIdentifier: String,
        expectedUpdatedAt: Date?
    ) -> Bool {
        let url = ScheduleCacheStore.cacheFileURL(for: accountIdentifier)
        let directory = url.deletingLastPathComponent()
        let currentResult = ScheduleCacheStore.readCacheFile(at: url)
        guard currentResult.allowsWrite else {
            ScheduleCacheStore.logger.error("保留无法读取的课表缓存，跳过保存")
            return false
        }
        var storedUpdatedAt = Date.distantPast
        if case .loaded(let currentCache) = currentResult {
            storedUpdatedAt = currentCache.updatedAt
        }
        if case .missing = currentResult,
           legacyAccountIdentifier != accountIdentifier
        {
            let legacyURL = ScheduleCacheStore.cacheFileURL(for: legacyAccountIdentifier)
            let legacyResult = ScheduleCacheStore.readCacheFile(at: legacyURL)
            guard legacyResult.allowsWrite else {
                ScheduleCacheStore.logger.error("保留无法读取的旧版课表缓存，跳过保存")
                return false
            }
            if case .loaded(let legacyCache) = legacyResult {
                storedUpdatedAt = legacyCache.updatedAt
            }
        }
        if let expectedUpdatedAt, expectedUpdatedAt != storedUpdatedAt {
            ScheduleCacheStore.logger.debug("缓存写入跳过，磁盘版本已变化")
            return false
        }

        do {
            try AppFileDirectories.files.createDirectory(at: directory)
            let data = try ScheduleCacheStore.makeEncoder().encode(cache)
            try AppFileDirectories.files.writeData(
                data,
                to: url,
                options: AppFileSystem.protectedDataWritingOptions
            )
        } catch {
            ScheduleCacheStore.logger.error("保存课表缓存失败：\(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    func clear(urls: [URL]) -> Bool {
        do {
            for url in urls where AppFileDirectories.files.fileExists(at: url) {
                try AppFileDirectories.files.removeItem(at: url)
            }

            for directory in Set(urls.map({ $0.deletingLastPathComponent() })) {
                if AppFileDirectories.files.fileExists(at: directory),
                   (try? AppFileDirectories.files.contentsOfDirectory(at: directory, options: []).isEmpty) == true {
                    try AppFileDirectories.files.removeItem(at: directory)
                }
            }
        } catch {
            ScheduleCacheStore.logger.error("清理课表缓存失败：\(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }
}
