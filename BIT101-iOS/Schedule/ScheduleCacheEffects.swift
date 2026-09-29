import ClientCore
import Foundation

/// 持久化完成后的外部展示与同步接口。
@MainActor
protocol ScheduleCacheEffects {
    func didSave(_ cache: ScheduleCache, session: AppStorageSession, source: ScheduleCacheStore.SaveSource) async
    func didClear() async
}
