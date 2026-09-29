import ClientCore
import Foundation

/// 应用层连接持久化、组件导出与云同步。
struct AppScheduleCacheEffects: ScheduleCacheEffects {
    func didSave(_ cache: ScheduleCache, session: AppStorageSession, source: ScheduleCacheStore.SaveSource) async {
        await ScheduleWidgetExporter.syncAsync(cache: cache, session: session)
#if canImport(CloudKit)
        if source == .local, cache.iCloudSyncEnabled {
            Task {
                guard AppFileDirectories.currentSession == session else { return }
                await ScheduleCloudSyncManager.shared.pushLatestLocalCacheIfNeeded()
            }
        }
#endif
    }

    func didClear() async {
        await ScheduleWidgetExporter.syncFromCurrentCache()
    }
}
