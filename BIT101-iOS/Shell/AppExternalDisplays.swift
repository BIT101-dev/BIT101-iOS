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
    let currentSession: () -> AppStorageSession
    let isSignedIn: () -> Bool
    let activateWatch: () -> Void
    let resetPresentation: () -> Void
    let exportWidget: () async -> Void
    let nextReminderRefresh: () async -> Date?
    let scheduleBackgroundRefresh: (Date?) -> Void
    let endActivities: () async -> Void
    let refreshActivities: (String) async -> Void

    func activate() { activateWatch() }
    func resetAccountPresentation() { resetPresentation() }

    func refresh(trigger: String, syncWidgetSnapshot: Bool, session: AppStorageSession) async {
        guard !Task.isCancelled, session == currentSession() else { return }
        if syncWidgetSnapshot { await exportWidget() }
        guard !Task.isCancelled, session == currentSession() else { return }
        guard isSignedIn() else {
            scheduleBackgroundRefresh(nil)
            await endActivities()
            return
        }
        let date = await nextReminderRefresh()
        guard !Task.isCancelled, session == currentSession() else { return }
        scheduleBackgroundRefresh(date)
        await refreshActivities(trigger)
    }
}
