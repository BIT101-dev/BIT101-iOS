import CommunityTransport
import ScheduleSync
import SchedulePersistence
import StorageCore
import ScheduleDomain
//
//  ScheduleCacheStore.swift
//  BIT101-iOS
//
import Combine
import Foundation

/// 日程模块本地缓存仓库。
///
/// 统一负责 `ScheduleCache` 的磁盘读写和变更通知发送。
enum ScheduleCacheStore {
    private static let changeSubject = PassthroughSubject<AppStorageSession, Never>()
    static var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
    private nonisolated static let writeQueue = SchedulePersistenceStore(
        files: AppFileDirectories.files,
        storageRoot: AppFileDirectories.applicationSupportDirectoryURL(named: "BIT101-iOS"),
        userStateMatches: ScheduleCloudSyncState.matches
    )
    private static let operations = SchedulePersistenceCoordinator()

    /// 当前账号对应的缓存文件路径。
    ///
    /// 路径按当前学号区分账号缓存。
    private static var fileURL: URL {
        cacheFileURL(for: AppFileDirectories.currentSession.accountStorageIdentifier)
    }

    /// 读取当前账号的缓存快照。
    static func load() -> ScheduleCache {
        loadResult(
            accountIdentifier: AppFileDirectories.currentSession.accountStorageIdentifier,
            legacyAccountIdentifier: legacyAccountIdentifier()
        ).cacheIfReadable ?? ScheduleCache()
    }

    static func loadResultAsync() async -> ScheduleCacheLoadResult {
        await loadResultAsync(for: AppFileDirectories.currentSession)
    }

    /// 读取调用方捕获的账号缓存，避免异步期间账号切换后改读另一账号。
    static func loadResultAsync(for session: AppStorageSession) async -> ScheduleCacheLoadResult {
        await writeQueue.load(for: session)
    }

    /// 将缓存文件读取与解码移到独立任务，避免页面恢复阶段阻塞 MainActor。
    static func loadAsync() async -> ScheduleCache {
        await loadResultAsync().cacheIfReadable ?? ScheduleCache()
    }

    /// 写回账号缓存并广播变更，外部展示由应用生命周期协调。
    static func save(_ cache: ScheduleCache, source: ScheduleCacheSaveSource = .local, session: AppStorageSession = AppFileDirectories.currentSession) {
        let identity = AppAccountSession.storage.communityCredentials.identity
        Task {
            await saveAndWait(cache, source: source, expectedAccountIdentifier: session.accountDirectoryName,
                isCurrent: { AppAccountSession.storage.communityCredentials.identity == identity })
        }
    }

    @discardableResult
    static func saveAndWait(
        _ cache: ScheduleCache,
        source: ScheduleCacheSaveSource = .local,
        expectedAccountIdentifier: String? = nil,
        expectedUpdatedAt: Date? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async -> Bool {
        var cacheToSave = cache
        if source == .local || source == .localWithoutCloudPush {
            cacheToSave.updatedAt = ScheduleCacheTimestamp.next(
                after: max(cache.updatedAt, cache.cloudSyncBaselineAt),
                now: Date()
            )
            if cacheToSave.iCloudSyncEnabled {
                cacheToSave.hasUnpushedCloudChanges = true
            }
        }
        let session = AppFileDirectories.currentSession
        let accountIdentifier = session.accountStorageIdentifier
        guard expectedAccountIdentifier == nil || expectedAccountIdentifier == session.accountDirectoryName else {
            return false
        }
        let legacyIdentifier = legacyAccountIdentifier()
        let identity = AppAccountSession.storage.communityCredentials.identity
        let didWrite = await operations.perform(isCurrent: {
            AppFileDirectories.currentSession == session
                && AppAccountSession.storage.communityCredentials.identity == identity
                && isCurrent()
        }, operation: {
            await writeQueue.write(
                cacheToSave,
                accountIdentifier: accountIdentifier,
                legacyAccountIdentifier: legacyIdentifier,
                source: source,
                expectedUpdatedAt: expectedUpdatedAt
            ) != nil
        })
        guard didWrite else { return false }
        postCacheDidChange()
        return true
    }

    /// 清空当前账号的日程缓存。
    ///
    /// 清空操作定位当前账号目录，并保留其它账号目录。
    @discardableResult
    static func clear() async -> Bool {
        let session = AppFileDirectories.currentSession
        let urls = cacheURLs()
        let identity = AppAccountSession.storage.communityCredentials.identity
        let didClear = await operations.perform(isCurrent: { true }, operation: {
            await writeQueue.clear(urls: urls)
        })
        if didClear, AppFileDirectories.currentSession == session,
           AppAccountSession.storage.communityCredentials.identity == identity {
            postCacheDidChange()
        }
        return didClear
    }

    fileprivate nonisolated static func loadResult(accountIdentifier: String, legacyAccountIdentifier: String) -> ScheduleCacheLoadResult {
        writeQueue.read(accountIdentifier: accountIdentifier, legacyAccountIdentifier: legacyAccountIdentifier)
    }

    nonisolated static func decodeCache(_ data: Data) -> ScheduleCacheLoadResult {
        SchedulePersistenceStore.decodeCache(data)
    }

    private static func cacheURLs() -> [URL] {
        let current = fileURL
        let legacy = cacheFileURL(for: legacyAccountIdentifier())
        return current == legacy ? [current] : [current, legacy]
    }

    fileprivate nonisolated static func cacheFileURL(for accountIdentifier: String) -> URL {
        writeQueue.cacheFileURL(for: accountIdentifier)
    }

    private static func legacyAccountIdentifier() -> String {
        AppFileDirectories.currentSession.legacyAccountDirectoryNameForMigration
    }

    /// 在主线程广播“课表缓存已变化”。
    ///
    /// 保存与清空缓存后都要发送这条通知，两个入口共用这一实现。
    fileprivate static func postCacheDidChange() {
        changeSubject.send(AppFileDirectories.currentSession)
    }
}
