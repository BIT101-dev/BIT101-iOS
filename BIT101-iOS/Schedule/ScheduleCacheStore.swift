//
//  ScheduleCacheStore.swift
//  BIT101-iOS
//
import Combine
import CommunityTransport
import Foundation
import ScheduleDomain
import SchedulePersistence
import ScheduleSync
import StorageCore

/// 日程模块本地缓存仓库。
///
/// 统一负责 `ScheduleCache` 的磁盘读写和变更通知发送。
enum ScheduleCacheStore {
    private static let changeSubject = PassthroughSubject<AppStorageSession, Never>()
    static var changes: AnyPublisher<AppStorageSession, Never> {
        changeSubject.eraseToAnyPublisher()
    }
    private nonisolated static let writeQueue = SchedulePersistenceStore(
        files: AppFileDirectories.files,
        storageRoot: AppFileDirectories.appSupportURL(named: "BIT101-iOS"),
        userStateMatches: ScheduleCloudSyncState.matches
    )
    private static let operations = SchedulePersistenceCoordinator()

    /// 当前账号对应的缓存文件路径。
    ///
    /// 路径按当前学号区分账号缓存。
    private static var fileURL: URL {
        cacheFileURL(for: AppFileDirectories.currentSession.accountStorageIdentifier)
    }

    static func loadResultAsync() async -> ScheduleCacheLoadResult {
        await loadResultAsync(for: AppFileDirectories.currentSession)
    }

    /// 按调用方捕获的账号读取缓存。
    static func loadResultAsync(for session: AppStorageSession) async -> ScheduleCacheLoadResult {
        await writeQueue.load(for: session)
    }

    static func readFailureAsync() async -> String? {
        await writeQueue.readFailure(for: AppFileDirectories.currentSession)
    }

    /// 在独立任务中读取并解码缓存文件。
    static func loadAsync() async -> ScheduleCache {
        await loadResultAsync().cacheIfReadable ?? ScheduleCache()
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
        if source == .local || source == .localWithoutCloudPush || source == .recovery
            || source == .rebuild
        {
            cacheToSave.updatedAt = ScheduleCacheTimestamp.next(
                after: max(cache.updatedAt, cache.cloudSyncBaselineAt),
                now: Date()
            )
            if cacheToSave.iCloudSyncEnabled && source != .rebuild {
                cacheToSave.hasUnpushedCloudChanges = true
            }
        }
        let session = AppFileDirectories.currentSession
        let accountIdentifier = session.accountStorageIdentifier
        guard
            expectedAccountIdentifier == nil
                || expectedAccountIdentifier == session.accountDirectoryName
        else {
            return false
        }
        let legacyIdentifier = legacyAccountIdentifier()
        let identity = AppAccountSession.storage.communityCredentials.identity
        let didWrite = await operations.perform(
            isCurrent: {
                AppFileDirectories.currentSession == session
                    && AppAccountSession.storage.communityCredentials.identity == identity
                    && isCurrent()
            },
            operation: {
                await writeQueue.write(
                    cacheToSave,
                    accountIdentifier: accountIdentifier,
                    legacyAccountIdentifier: legacyIdentifier,
                    source: source,
                    expectedUpdatedAt: source == .recovery ? cache.updatedAt : expectedUpdatedAt
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
        let didClear = await operations.perform(
            isCurrent: { true },
            operation: {
                await writeQueue.clear(urls: urls)
            })
        if didClear, AppFileDirectories.currentSession == session,
            AppAccountSession.storage.communityCredentials.identity == identity
        {
            postCacheDidChange()
        }
        return didClear
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
