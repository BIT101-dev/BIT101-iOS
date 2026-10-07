import Foundation
import StorageCore

@MainActor
protocol AppExternalDisplayCoordinating {
    func activate()
    func resetAccountPresentation()
    func refresh(trigger: String, syncWidgetSnapshot: Bool, session: AppStorageSession) async
}

/// 生产平台适配集中维护 Watch、Widget 和提醒生命周期。
struct AppExternalDisplayCoordinator: AppExternalDisplayCoordinating {
    func activate() { WatchScheduleSyncManager.shared.activateIfNeeded() }
    func resetAccountPresentation() { AppErrorPresenter.shared.reset() }

    func refresh(trigger: String, syncWidgetSnapshot: Bool, session: AppStorageSession) async {
        guard !Task.isCancelled, session == AppFileDirectories.currentSession else { return }
        if syncWidgetSnapshot { await ScheduleWidgetExporter.syncFromCurrentCache() }
        guard !Task.isCancelled, session == AppFileDirectories.currentSession else { return }
        let cookie = AppAccountSession.storage.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            ScheduleReminderBackgroundRefresh.schedule(earliestBeginDate: nil)
            await ScheduleLiveActivityManager.shared.endAllActivities()
            return
        }
        let date = await ScheduleLiveActivityManager.shared.preferredBackgroundRefreshBeginDate()
        guard !Task.isCancelled, session == AppFileDirectories.currentSession else { return }
        ScheduleReminderBackgroundRefresh.schedule(earliestBeginDate: date)
        await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(trigger: trigger)
    }
}
