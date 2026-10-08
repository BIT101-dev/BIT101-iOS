import ScheduleActivityContracts
import StorageCore
import Foundation
import ScheduleDomain
import ScheduleContracts
//
//  ScheduleLiveActivityManager.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-28.
//

nonisolated struct ScheduleReminderSession: Equatable, Sendable {
    let studentID: String
    let storage: AppStorageSession
    let generation: Int
    let signedIn: Bool
}

@MainActor
struct ScheduleReminderContext {
    let currentSession: () -> ScheduleReminderSession
    let loadCache: (AppStorageSession) async -> ScheduleCache

    func loadCurrentCache() async -> (session: ScheduleReminderSession, cache: ScheduleCache)? {
        let session = currentSession()
        let cache = await loadCache(session.storage)
        guard currentSession() == session, !Task.isCancelled else { return nil }
        return (session, cache)
    }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)

// ActivityKit update/end execute concurrently; handles stay inside concurrent
// operations while MainActor serializes the manager's operation order.
import ActivityKit
import os
import UserNotifications

private nonisolated struct ExistingActivitySnapshot: Sendable {
    let id: String
    let contentState: CourseReminderActivityAttributes.ContentState
}

private nonisolated enum ExistingActivitySyncResult: Sendable {
    case needsRequest
    case unchanged
    case updated
    case cancelled
}

private nonisolated struct ExistingActivitySyncReport: Sendable {
    let result: ExistingActivitySyncResult
    let activeSnapshot: ExistingActivitySnapshot?
    let endedActivityIDs: [String]
    let activityCount: Int
}

private nonisolated struct ActivityEndingReport: Sendable {
    let endedActivityIDs: [String]
    let activityCount: Int
}

@MainActor
final class ScheduleLiveActivityManager {

    typealias NotificationAuthorizationState = ScheduleReminderNotificationAuthorizationState

    private let logger = Logger(subsystem: "BIT101", category: "ScheduleLiveActivity")
    private let context: ScheduleReminderContext
    private let notifications: ScheduleReminderNotifications
    private var refreshRequestGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var scheduledRefreshTask: Task<Void, Never>?
    private var scheduledEndTask: Task<Void, Never>?
    private var activityOperationTask: Task<Void, Never>?
    private var activityOperationID: UUID?

    init(context: ScheduleReminderContext, notificationCenter: UNUserNotificationCenter) {
        self.context = context
        self.notifications = ScheduleReminderNotifications(center: notificationCenter)
    }

    /// 刷新当前课表提醒。
    ///
    /// 这条链路只做三件事：
    /// 1. 读取当前账号的课表缓存与提醒设置
    /// 2. 计算“此刻是否应该存在一个课前提醒”
    /// 3. 把计算结果同步给 ActivityKit
    ///
    /// 展示样式由 widget extension 负责。
    func refreshFromCurrentCache(trigger: String = "unspecified") async {
        guard !Task.isCancelled else { return }
        refreshRequestGeneration &+= 1
        let requestGeneration = refreshRequestGeneration
        refreshTask?.cancel()
        if let previousTask = refreshTask {
            await previousTask.value
        }
        guard !Task.isCancelled, requestGeneration == refreshRequestGeneration else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefreshFromCurrentCache(trigger: trigger)
        }
        refreshTask = task
        await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private func performRefreshFromCurrentCache(trigger: String) async {
        logger.debug("refreshFromCurrentCache trigger=\(trigger, privacy: .public)")

        // 课表提醒依赖有效 fake-cookie 会话；账号凭据与课表缓存按各自持久化策略管理。
        let session = context.currentSession()
        guard session.signedIn else {
            logger.debug("fake-cookie missing; treating session as signed out and ending all activities")
            await clearFallbackNotifications()
            guard !Task.isCancelled else { return }
            await endAllActivities(invalidateRefresh: false)
            return
        }

        guard let loaded = await context.loadCurrentCache(), loaded.session == session else { return }
        let cache = loaded.cache
        guard cache.showCourseLiveActivityReminder else {
            logger.debug("course live activity reminder disabled in settings; ending all activities")
            await clearFallbackNotifications()
            await endAllActivities(invalidateRefresh: false)
            return
        }

        let leadMinutes = cache.courseLiveActivityLeadMinutes
        let occurrences = ScheduleReminderPlanner.resolveOccurrences(from: cache)
        await notifications.synchronize(
            for: occurrences,
            leadMinutes: leadMinutes,
            session: session,
            isCurrent: { self.isCurrentSession(session) }
        )

        guard !Task.isCancelled else { return }
        guard isCurrentSession(session) else {
            await clearFallbackNotifications()
            await endAllActivities(invalidateRefresh: false)
            return
        }

        guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.debug("live activity unavailable or disabled by system; keeping fallback notifications only")
            await endAllActivities(invalidateRefresh: false)
            return
        }

        logger.debug("resolved occurrences count=\(occurrences.count, privacy: .public) leadMinutes=\(leadMinutes, privacy: .public)")

        // 在“进入提醒窗口但尚未开始”的课前阶段选择一条提醒对象。
        let now = Date()
        let currentOccurrence = occurrences.first { occ in
            let displayWindowStart = ScheduleReminderPlanner.effectiveDisplayWindowStart(for: occ, among: occurrences, leadMinutes: leadMinutes)
            return now >= displayWindowStart && now < occ.startDate
        }

        if let currentOccurrence {
            logger.debug(
                "selected occurrence kind=\(currentOccurrence.kindText, privacy: .public) title=\(currentOccurrence.title, privacy: .private) start=\(Self.debugDateFormatter.string(from: currentOccurrence.startDate), privacy: .private) end=\(Self.debugDateFormatter.string(from: currentOccurrence.endDate), privacy: .private)"
            )
        } else {
            logger.debug("selected occurrence is nil for current time=\(Self.debugDateFormatter.string(from: now), privacy: .public)")
        }

        // 先安排下一次自动唤醒和提醒结束任务，再同步当前状态。
        // app 持续处于后台时，任务会在“进入提醒窗口”和“提醒该结束了”两个边界点重新计算。
        scheduleNextRefresh(for: occurrences, leadMinutes: leadMinutes)
        scheduleEndForDisplayedOccurrence(currentOccurrence)

        await syncActivity(with: currentOccurrence, session: session)
    }

    func requestNotificationAuthorizationIfNeeded() async -> Bool {
        await notifications.requestAuthorizationIfNeeded()
    }

    func notificationAuthorizationStateForReminderFallback() async -> NotificationAuthorizationState {
        guard let loaded = await context.loadCurrentCache(), loaded.cache.showCourseLiveActivityReminder else { return .allowed }
        return await notifications.authorizationState()
    }

    func clearFallbackNotifications() async { await notifications.clear() }

    /// 将当前计算出的提醒对象同步到 ActivityKit。
    ///
    /// 规则：
    /// - 提醒对象为空：结束现有 activity
    /// - 提醒对象存在且内容未变：保留现有 activity
    /// - 提醒对象存在且内容变化：更新现有 activity
    /// - activity 不存在：创建新的 activity
    ///
    /// activity 同时记录 `studentID`，用于切号后避免复用上一账号的提醒。
    private func syncActivity(with occurrence: CourseReminderOccurrence?, session: ScheduleReminderSession) async {
        await performSerializedActivityOperation {
            await self.syncActivitySerially(with: occurrence, session: session)
        }
    }

    private func syncActivitySerially(with occurrence: CourseReminderOccurrence?, session: ScheduleReminderSession) async {
        let studentID = session.studentID
        guard !Task.isCancelled, isCurrentSession(session) else { return }

        // 当前没有提醒对象时结束现有活动。
        guard let occ = occurrence else {
            let report = await Self.endActivities { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled && self.isCurrentSession(session)
            }
            for activityID in report.endedActivityIDs {
                logger.debug("ending activity id=\(activityID, privacy: .public) because occurrence is nil")
            }
            if report.activityCount == 0 {
                logger.debug("no occurrence and no active activity; nothing to end")
            }
            return
        }

        let newState = CourseReminderActivityAttributes.ContentState(
            kindText: occ.kindText,
            title: occ.title,
            classroom: occ.classroom,
            teacher: occ.teacher,
            timeRangeText: ScheduleReminderPlanner.timeRangeText(start: occ.startDate, end: occ.endDate),
            countdownTargetDate: occ.startDate
        )

        let result = await Self.synchronizeExistingActivities(
            studentID: studentID,
            contentState: newState,
            staleDate: occ.startDate
        ) { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled && self.isCurrentSession(session)
        }

        logger.debug("syncActivity activeCount=\(result.activityCount, privacy: .public) currentStudentID=\(studentID, privacy: .private(mask: .hash))")
        for activityID in result.endedActivityIDs {
            logger.debug("ending stale activity id=\(activityID, privacy: .public) before syncing current occurrence")
        }
        if let activeSnapshot = result.activeSnapshot {
            logger.debug(
                "active activity id=\(activeSnapshot.id, privacy: .public) state=\(Self.describe(activeSnapshot.contentState), privacy: .private) next=\(Self.describe(newState), privacy: .private)"
            )
        }

        guard !Task.isCancelled, isCurrentSession(session) else { return }
        switch result.result {
        case .needsRequest:
            // 当前没有 activity 时创建新的 activity。
            let content = ActivityContent(state: newState, staleDate: occ.startDate)
            let attributes = CourseReminderActivityAttributes(studentID: studentID)
            await requestActivity(attributes: attributes, content: content, reason: "no_active_activity")
        case .unchanged:
            logger.debug("skipping update because content state is unchanged")
        case .updated:
            logger.debug("activity content updated")
        case .cancelled:
            return
        }
    }

    /// 安排下一次刷新。
    ///
    /// 刷新任务关注两个边界：
    /// - 某条课/日程进入提醒窗口
    /// - 某条课/日程正式开始，提醒结束
    private func scheduleNextRefresh(for occurrences: [CourseReminderOccurrence], leadMinutes: Int) {
        scheduledRefreshTask?.cancel()

        let now = Date()
        guard let nextDate = ScheduleReminderPlanner.nextFutureRefreshPoint(for: occurrences, leadMinutes: leadMinutes, now: now) else {
            logger.debug("scheduleNextRefresh: no future refresh point")
            return
        }

        logger.debug("scheduleNextRefresh nextDate=\(Self.debugDateFormatter.string(from: nextDate), privacy: .public)")

        scheduledRefreshTask = Task {
            try? await Task.sleep(for: .seconds(max(0, nextDate.timeIntervalSinceNow)))
            if !Task.isCancelled {
                await refreshFromCurrentCache(trigger: "scheduled_refresh")
            }
        }
    }

    /// 为当前展示的提醒安排到点结束任务。
    ///
    /// 该任务与常规 refresh 并存，用于在倒计时到点时结束旧提醒。
    private func scheduleEndForDisplayedOccurrence(_ occurrence: CourseReminderOccurrence?) {
        scheduledEndTask?.cancel()
        scheduledEndTask = nil

        guard let occurrence else { return }

        let now = Date()
        guard occurrence.startDate > now.addingTimeInterval(0.5) else { return }

        let expectedTarget = occurrence.startDate
        let expectedSession = context.currentSession()

        scheduledEndTask = Task {
            try? await Task.sleep(for: .seconds(expectedTarget.timeIntervalSince(now)))
            guard !Task.isCancelled else { return }
            await endActivityIfStillMatching(expectedTarget: expectedTarget, expectedSession: expectedSession)
        }
    }

    /// 仅当当前 activity 仍然对应同一条提醒时，才在到点时结束它。
    private func endActivityIfStillMatching(expectedTarget: Date, expectedSession: ScheduleReminderSession) async {
        await performSerializedActivityOperation {
            guard !Task.isCancelled, self.isCurrentSession(expectedSession) else { return }
            guard #available(iOS 16.2, *) else { return }
            let report = await Self.endActivities(
                matchingStudentID: expectedSession.studentID,
                expectedTarget: expectedTarget
            ) { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled && self.isCurrentSession(expectedSession)
            }
            for activityID in report.endedActivityIDs {
                self.logger.debug("ending activity id=\(activityID, privacy: .public) because countdown target reached")
            }
        }
    }

    /// 清理所有活动。
    func endAllActivities() async {
        await endAllActivities(invalidateRefresh: true)
    }

    private func endAllActivities(invalidateRefresh: Bool) async {
        let refreshTaskToCancel = invalidateRefresh ? refreshTask : nil
        if invalidateRefresh {
            refreshRequestGeneration &+= 1
            refreshTask?.cancel()
        }
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        scheduledEndTask?.cancel()
        scheduledEndTask = nil
        if let refreshTaskToCancel {
            await refreshTaskToCancel.value
        }
        if !context.currentSession().signedIn {
            await clearFallbackNotifications()
        }
        await performSerializedActivityOperation {
            guard !Task.isCancelled, #available(iOS 16.2, *) else { return }
            let report = await Self.endActivities { !Task.isCancelled }
            for activityID in report.endedActivityIDs {
                self.logger.debug("endAllActivities ending id=\(activityID, privacy: .public)")
            }
        }
    }

    private func performSerializedActivityOperation(
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let operationID = UUID()
        let previousTask = activityOperationTask
        let task = Task { @MainActor in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        activityOperationTask = task
        activityOperationID = operationID

        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        if activityOperationID == operationID {
            activityOperationTask = nil
            activityOperationID = nil
        }
    }

    /// 根据下一次提醒边界，给 BGAppRefreshTask 提供一个建议的最早启动时间。
    ///
    /// 该值表示系统可开始安排后台时间的最早时刻，实际启动时间由系统后台调度策略决定。
    /// 申请时间比真实边界提前 5 分钟。
    func preferredBackgroundRefreshBeginDate() async -> Date? {
        guard let loaded = await context.loadCurrentCache(), loaded.session.signedIn else { return nil }
        let cache = loaded.cache
        guard cache.showCourseLiveActivityReminder else { return nil }

        let leadMinutes = cache.courseLiveActivityLeadMinutes
        let occurrences = ScheduleReminderPlanner.resolveOccurrences(from: cache)
        let now = Date()
        guard let nextPoint = ScheduleReminderPlanner.nextFutureRefreshPoint(for: occurrences, leadMinutes: leadMinutes, now: now) else { return nil }
        let desiredBeginDate = nextPoint.addingTimeInterval(-5 * 60)
        return max(now.addingTimeInterval(60), desiredBeginDate)
    }

    /// 各分支复用同一套 activity 请求和日志。
    private func requestActivity(
        attributes: CourseReminderActivityAttributes,
        content: ActivityContent<CourseReminderActivityAttributes.ContentState>,
        reason: StaticString
    ) async {
        logger.debug(
            "requesting new activity reason=\(reason, privacy: .public) state=\(Self.describe(content.state), privacy: .private)"
        )
        _ = try? Activity.request(attributes: attributes, content: content)
    }

    @concurrent
    private static func endActivities(
        matchingStudentID: String? = nil,
        expectedTarget: Date? = nil,
        shouldContinue: @MainActor @Sendable () -> Bool
    ) async -> ActivityEndingReport {
        let activities = Activity<CourseReminderActivityAttributes>.activities
        var endedActivityIDs: [String] = []
        for activity in activities {
            guard !Task.isCancelled, await shouldContinue() else {
                return ActivityEndingReport(endedActivityIDs: endedActivityIDs, activityCount: activities.count)
            }
            if let matchingStudentID, activity.attributes.studentID != matchingStudentID {
                continue
            }
            if let expectedTarget, activity.content.state.countdownTargetDate != expectedTarget {
                continue
            }
            endedActivityIDs.append(activity.id)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return ActivityEndingReport(endedActivityIDs: endedActivityIDs, activityCount: activities.count)
    }

    @concurrent
    private static func synchronizeExistingActivities(
        studentID: String,
        contentState: CourseReminderActivityAttributes.ContentState,
        staleDate: Date,
        shouldContinue: @MainActor @Sendable () -> Bool
    ) async -> ExistingActivitySyncReport {
        let activities = Activity<CourseReminderActivityAttributes>.activities
        let activeActivity = activities.first { $0.attributes.studentID == studentID }
        let activeSnapshot = activeActivity.map {
            ExistingActivitySnapshot(id: $0.id, contentState: $0.content.state)
        }
        var endedActivityIDs: [String] = []

        for activity in activities where activity.id != activeSnapshot?.id {
            guard !Task.isCancelled, await shouldContinue() else {
                return ExistingActivitySyncReport(
                    result: .cancelled,
                    activeSnapshot: activeSnapshot,
                    endedActivityIDs: endedActivityIDs,
                    activityCount: activities.count
                )
            }
            endedActivityIDs.append(activity.id)
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        guard !Task.isCancelled, await shouldContinue() else {
            return ExistingActivitySyncReport(
                result: .cancelled,
                activeSnapshot: activeSnapshot,
                endedActivityIDs: endedActivityIDs,
                activityCount: activities.count
            )
        }
        guard let activeActivity else {
            return ExistingActivitySyncReport(
                result: .needsRequest,
                activeSnapshot: nil,
                endedActivityIDs: endedActivityIDs,
                activityCount: activities.count
            )
        }
        guard activeActivity.content.state != contentState else {
            return ExistingActivitySyncReport(
                result: .unchanged,
                activeSnapshot: activeSnapshot,
                endedActivityIDs: endedActivityIDs,
                activityCount: activities.count
            )
        }
        let content = ActivityContent(state: contentState, staleDate: staleDate)
        await activeActivity.update(content)
        return ExistingActivitySyncReport(
            result: .updated,
            activeSnapshot: activeSnapshot,
            endedActivityIDs: endedActivityIDs,
            activityCount: activities.count
        )
    }

    private static func describe(_ state: CourseReminderActivityAttributes.ContentState) -> String {
        "\(state.kindText) | \(state.title) | \(state.classroom) | \(state.timeRangeText) | target=\(debugDateFormatter.string(from: state.countdownTargetDate))"
    }

    private func isCurrentSession(_ session: ScheduleReminderSession) -> Bool {
        context.currentSession() == session && session.signedIn
    }

    private static let debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = ScheduleSharedDateCodec.calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ScheduleSharedDateCodec.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

}

#else

/// iPhone/iPad 通过 ActivityKit 展示提醒；Catalyst 提供同签名的系统适配。
@MainActor
final class ScheduleLiveActivityManager {

    typealias NotificationAuthorizationState = ScheduleReminderNotificationAuthorizationState

    init(context: ScheduleReminderContext) {}

    /// Catalyst 下锁屏和灵动岛提醒保持空操作。
    func refreshFromCurrentCache(trigger: String = "unspecified") async {}

    /// Catalyst 版将本地通知权限请求视为已完成。
    func requestNotificationAuthorizationIfNeeded() async -> Bool { true }

    /// Mac 预览固定使用允许状态，避免反复弹出“请开启通知”。
    func notificationAuthorizationStateForReminderFallback() async -> NotificationAuthorizationState { .allowed }

    /// Catalyst 下没有 Activity，保持空操作。
    func endAllActivities() async {}

    /// Catalyst 下没有本地提醒，保持空操作。
    func clearFallbackNotifications() async {}

    /// Catalyst 下保持 BGAppRefreshTask 链路关闭。
    func preferredBackgroundRefreshBeginDate() async -> Date? { nil }
}

#endif
