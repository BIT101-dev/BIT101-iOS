//
//  ScheduleLiveActivityManager.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-28.
//

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)

import ActivityKit
import Foundation
import os
import UserNotifications

/// 提醒计算使用的课表实例。
private struct CourseReminderOccurrence {
    let kindText: String
    let title: String
    let classroom: String
    let teacher: String
    let startDate: Date
    let endDate: Date
}

@MainActor
final class ScheduleLiveActivityManager {
    static let shared = ScheduleLiveActivityManager()

    enum NotificationAuthorizationState {
        case allowed
        case notDetermined
        case denied
    }

    private let logger = Logger(subsystem: "BIT101", category: "ScheduleLiveActivity")
    private let notificationCenter = UNUserNotificationCenter.current()
    private var scheduledRefreshTask: Task<Void, Never>?
    private var scheduledEndTask: Task<Void, Never>?

    private init() {}

    /// 刷新当前课表提醒。
    ///
    /// 这条链路只做三件事：
    /// 1. 读取当前账号的课表缓存与提醒设置
    /// 2. 计算“此刻是否应该存在一个课前提醒”
    /// 3. 把计算结果同步给 ActivityKit
    ///
    /// 展示样式由 widget extension 负责。
    func refreshFromCurrentCache(trigger: String = "unspecified") async {
        logger.debug("refreshFromCurrentCache trigger=\(trigger, privacy: .public)")

        // 退出登录或远端登录态失效后，fake-cookie 会被清掉；账号密码和课表缓存可能继续保留。
        // 课程提醒服务当前已登录账号，会话有效性是前置条件。
        guard !LoginStorage.shared.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.debug("fake-cookie missing; treating session as signed out and ending all activities")
            await clearFallbackNotifications()
            await endAllActivities()
            return
        }

        let cache = ScheduleCacheStore.load()
        guard cache.showCourseLiveActivityReminder else {
            logger.debug("course live activity reminder disabled in settings; ending all activities")
            await clearFallbackNotifications()
            await endAllActivities()
            return
        }

        let leadMinutes = cache.courseLiveActivityLeadMinutes
        let occurrences = resolveOccurrences(from: cache)
        await syncFallbackNotifications(
            for: occurrences,
            leadMinutes: leadMinutes,
            studentID: LoginStorage.shared.currentStudentID
        )

        guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.debug("live activity unavailable or disabled by system; keeping fallback notifications only")
            await endAllActivities()
            return
        }

        logger.debug("resolved occurrences count=\(occurrences.count, privacy: .public) leadMinutes=\(leadMinutes, privacy: .public)")

        // 在“进入提醒窗口但尚未开始”的课前阶段选择一条提醒对象。
        let now = Date()
        let currentOccurrence = occurrences.first { occ in
            let displayWindowStart = effectiveDisplayWindowStart(for: occ, among: occurrences, leadMinutes: leadMinutes)
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

        await syncActivity(with: currentOccurrence)
    }

    /// 首次开启提醒时申请本地通知权限。
    ///
    /// 本地通知作为 Activity 未启动时的兜底。授权由用户决定；授权后，app 未被唤醒时
    /// 仍能按同一规则发送课前通知。
    func requestNotificationAuthorizationIfNeeded() async -> Bool {
        let settings = await notificationCenter.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            } catch {
                logger.error("request notification authorization failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        @unknown default:
            return false
        }
    }

    /// 返回课前提醒 fallback 通知的权限状态。
    ///
    /// 灵动岛提醒开启时检查通知权限；关闭时返回 `allowed`。
    func notificationAuthorizationStateForReminderFallback() async -> NotificationAuthorizationState {
        let cache = ScheduleCacheStore.load()
        guard cache.showCourseLiveActivityReminder else {
            return .allowed
        }

        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .allowed
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// 将当前计算出的提醒对象同步到 ActivityKit。
    ///
    /// 规则：
    /// - 提醒对象为空：结束现有 activity
    /// - 提醒对象存在且内容未变：保留现有 activity
    /// - 提醒对象存在且内容变化：更新现有 activity
    /// - activity 不存在：创建新的 activity
    ///
    /// activity 同时记录 `studentID`，用于切号后避免复用上一账号的提醒。
    private func syncActivity(with occurrence: CourseReminderOccurrence?) async {
        let studentID = LoginStorage.shared.currentStudentID
        let activities = Activity<CourseReminderActivityAttributes>.activities
        let activeActivity = activities.first
        logger.debug("syncActivity activeCount=\(activities.count, privacy: .public) currentStudentID=\(studentID, privacy: .private(mask: .hash))")

        // 当前没有提醒对象时结束现有活动。
        guard let occ = occurrence else {
            if let activity = activeActivity {
                logger.debug("ending activity id=\(activity.id, privacy: .public) because occurrence is nil")
                await activity.end(nil, dismissalPolicy: .immediate)
            } else {
                logger.debug("no occurrence and no active activity; nothing to end")
            }
            return
        }

        let newState = CourseReminderActivityAttributes.ContentState(
            kindText: occ.kindText,
            title: occ.title,
            classroom: occ.classroom,
            teacher: occ.teacher,
            timeRangeText: Self.timeRangeText(start: occ.startDate, end: occ.endDate),
            countdownTargetDate: occ.startDate
        )

        let content = ActivityContent(state: newState, staleDate: occ.startDate)
        let attributes = CourseReminderActivityAttributes(studentID: studentID)

        if let activity = activeActivity {
            logger.debug(
                "active activity id=\(activity.id, privacy: .public) state=\(Self.describe(activity.content.state), privacy: .private) next=\(Self.describe(newState), privacy: .private)"
            )
            // 账号变化时结束旧 activity 并创建新 activity。
            if activity.attributes.studentID != studentID {
                logger.debug("student changed old=\(activity.attributes.studentID, privacy: .private(mask: .hash)) new=\(studentID, privacy: .private(mask: .hash)); ending and requesting new activity")
                await activity.end(nil, dismissalPolicy: .immediate)
                await requestActivity(attributes: attributes, content: content, reason: "student_changed")
                return
            }

            // 内容未变化时跳过更新，避免 UI 闪烁。
            if activity.content.state == newState {
                logger.debug("skipping update because content state is unchanged")
                return
            }

            // 内容变化时使用 update，保留当前灵动岛状态。
            logger.debug("updating activity id=\(activity.id, privacy: .public)")
            await activity.update(content)
        } else {
            // 当前没有 activity 时创建新的 activity。
            await requestActivity(attributes: attributes, content: content, reason: "no_active_activity")
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
        guard let nextDate = nextFutureRefreshPoint(for: occurrences, leadMinutes: leadMinutes, now: now) else {
            logger.debug("scheduleNextRefresh: no future refresh point")
            return
        }

        logger.debug("scheduleNextRefresh nextDate=\(Self.debugDateFormatter.string(from: nextDate), privacy: .public)")

        scheduledRefreshTask = Task {
            try? await Task.sleep(for: .seconds(nextDate.timeIntervalSince(now)))
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
        let expectedStudentID = LoginStorage.shared.currentStudentID

        scheduledEndTask = Task {
            try? await Task.sleep(for: .seconds(expectedTarget.timeIntervalSince(now)))
            guard !Task.isCancelled else { return }
            await endActivityIfStillMatching(expectedTarget: expectedTarget, expectedStudentID: expectedStudentID)
        }
    }

    /// 仅当当前 activity 仍然对应同一条提醒时，才在到点时结束它。
    private func endActivityIfStillMatching(expectedTarget: Date, expectedStudentID: String) async {
        guard #available(iOS 16.2, *) else { return }
        guard let activity = Activity<CourseReminderActivityAttributes>.activities.first else { return }
        guard activity.attributes.studentID == expectedStudentID else { return }
        guard activity.content.state.countdownTargetDate == expectedTarget else { return }

        logger.debug("ending activity id=\(activity.id, privacy: .public) because countdown target reached")
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    /// 清理所有活动。
    func endAllActivities() async {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        scheduledEndTask?.cancel()
        scheduledEndTask = nil
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<CourseReminderActivityAttributes>.activities {
            logger.debug("endAllActivities ending id=\(activity.id, privacy: .public)")
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// 根据下一次提醒边界，给 BGAppRefreshTask 提供一个建议的最早启动时间。
    ///
    /// 该值表示系统可开始安排后台时间的最早时刻，实际启动时间由系统后台调度策略决定。
    /// 申请时间比真实边界提前 5 分钟。
    func preferredBackgroundRefreshBeginDate() -> Date? {
        let fakeCookie = LoginStorage.shared.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fakeCookie.isEmpty else { return nil }

        let cache = ScheduleCacheStore.load()
        guard cache.showCourseLiveActivityReminder else { return nil }

        let leadMinutes = cache.courseLiveActivityLeadMinutes
        let occurrences = resolveOccurrences(from: cache)
        let now = Date()
        guard let nextPoint = nextFutureRefreshPoint(for: occurrences, leadMinutes: leadMinutes, now: now) else { return nil }
        let desiredBeginDate = nextPoint.addingTimeInterval(-5 * 60)
        return max(now.addingTimeInterval(60), desiredBeginDate)
    }

    /// 删除已排期和已送达的课前提醒 fallback 通知。
    func clearFallbackNotifications() async {
        let prefix = Self.notificationIdentifierPrefix
        let pendingIdentifiers = await pendingFallbackNotificationIdentifiers(prefix: prefix)
        if !pendingIdentifiers.isEmpty {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        }

        let deliveredIdentifiers = await deliveredFallbackNotificationIdentifiers(prefix: prefix)
        if !deliveredIdentifiers.isEmpty {
            notificationCenter.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        }
    }

    // MARK: - 数据解析逻辑

    /// 把课表缓存解析成仍然有效的提醒候选。
    ///
    /// 这里同时覆盖：
    /// - 常规课程
    /// - 自定义日程
    ///
    /// 结果保留结束时间晚于当前时间的实例。
    private func resolveOccurrences(from cache: ScheduleCache) -> [CourseReminderOccurrence] {
        let now = Date()
        let slotMap = Dictionary(uniqueKeysWithValues: cache.timeTable.map { ($0.id, $0) })

        var results: [CourseReminderOccurrence] = []

        // 处理常规课程
        if let firstDay = cache.firstDay {
            for course in cache.courses {
                for week in course.weeks {
                    guard let startSlot = slotMap[course.startSection],
                          let endSlot = slotMap[course.endSection],
                          let start = ScheduleSharedDateCodec.combine(firstDay: firstDay, week: week, weekday: course.weekday, time: startSlot.start),
                          let end = ScheduleSharedDateCodec.combine(firstDay: firstDay, week: week, weekday: course.weekday, time: endSlot.end),
                          end > now else { continue }

                    results.append(CourseReminderOccurrence(
                        kindText: "上课",
                        title: ScheduleDisplayNormalizer.normalizeCourseTitle(course.name),
                        classroom: ScheduleDisplayNormalizer.normalizeClassroom(course.classroom),
                        teacher: course.teacher,
                        startDate: start,
                        endDate: end
                    ))
                }
            }
        }

        // 处理自定义日程
        for schedule in cache.customSchedules {
            guard let date = ScheduleDateCodec.parseDate(schedule.dateString),
                  let start = ScheduleSharedDateCodec.combine(date: date, time: schedule.beginTime),
                  let end = ScheduleSharedDateCodec.combine(date: date, time: schedule.endTime),
                  end > now else { continue }

            results.append(CourseReminderOccurrence(
                kindText: "日程",
                title: schedule.title,
                classroom: schedule.subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
                teacher: "",
                startDate: start,
                endDate: end
            ))
        }

        return results.sorted { $0.startDate < $1.startDate }
    }

    /// 计算某条提醒的实际显示起点。
    ///
    /// 默认规则是“开课前 `leadMinutes` 分钟开始提醒”。如果上一条课/日程尚未结束，
    /// 下一条已经落入提醒窗口时，起点后移到“上一条结束前 5 分钟”，避免
    /// 用户仍在上一条课程期间收到下一条提醒。
    private func effectiveDisplayWindowStart(
        for occurrence: CourseReminderOccurrence,
        among occurrences: [CourseReminderOccurrence],
        leadMinutes: Int
    ) -> Date {
        let naturalStart = occurrence.startDate.addingTimeInterval(Double(-leadMinutes * 60))
        let reminderLeadOutFromPrevious: TimeInterval = 5 * 60

        guard let previous = occurrences.last(where: { candidate in
            candidate.startDate < occurrence.startDate && candidate.endDate > naturalStart
        }) else {
            return naturalStart
        }

        let adjustedStart = previous.endDate.addingTimeInterval(-reminderLeadOutFromPrevious)
        return max(naturalStart, adjustedStart)
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

    private static func describe(_ state: CourseReminderActivityAttributes.ContentState) -> String {
        "\(state.kindText) | \(state.title) | \(state.classroom) | \(state.timeRangeText) | target=\(debugDateFormatter.string(from: state.countdownTargetDate))"
    }

    private static func timeRangeText(start: Date, end: Date) -> String {
        "\(displayTimeFormatter.string(from: start))-\(displayTimeFormatter.string(from: end))"
    }

    /// 计算下一条刷新边界。
    ///
    /// 调度关注两个时刻：
    /// 1. 某条提醒进入可展示窗口
    /// 2. 某条提醒正式开始，现有提醒应结束
    ///
    /// 本地 Task.sleep 调度和 BGAppRefresh 建议时间共用这套计算。
    private func nextFutureRefreshPoint(
        for occurrences: [CourseReminderOccurrence],
        leadMinutes: Int,
        now: Date
    ) -> Date? {
        let earliestAllowedDate = now.addingTimeInterval(1)
        return occurrences
            .flatMap { occurrence in
                [
                    effectiveDisplayWindowStart(for: occurrence, among: occurrences, leadMinutes: leadMinutes),
                    occurrence.startDate,
                ]
            }
            .filter { $0 > earliestAllowedDate }
            .min()
    }

    /// 按与 Live Activity 相同的规则预排本地通知。
    ///
    /// 本地通知作为 fallback：app 后台未被唤醒或 Activity 未按时出现时，用户仍能在同一提醒窗口收到通知。
    private func syncFallbackNotifications(
        for occurrences: [CourseReminderOccurrence],
        leadMinutes: Int,
        studentID: String
    ) async {
        let settings = await notificationCenter.notificationSettings()
        let allowedStatuses: Set<UNAuthorizationStatus> = [.authorized, .provisional, .ephemeral]
        guard allowedStatuses.contains(settings.authorizationStatus) else {
            logger.debug("notifications not authorized; clearing fallback reminders")
            await clearFallbackNotifications()
            return
        }

        await clearFallbackNotifications()

        let now = Date()
        let scheduledItems = occurrences
            .compactMap { occurrence -> (CourseReminderOccurrence, Date)? in
                let displayStart = effectiveDisplayWindowStart(
                    for: occurrence,
                    among: occurrences,
                    leadMinutes: leadMinutes
                )
                guard displayStart > now.addingTimeInterval(1), displayStart < occurrence.startDate else {
                    return nil
                }
                return (occurrence, displayStart)
            }
            .sorted { $0.1 < $1.1 }

        guard !scheduledItems.isEmpty else {
            logger.debug("no future fallback notifications to schedule")
            return
        }

        for (index, item) in scheduledItems.prefix(64).enumerated() {
            let occurrence = item.0
            let triggerDate = item.1
            let request = UNNotificationRequest(
                identifier: Self.notificationIdentifier(studentID: studentID, index: index),
                content: fallbackNotificationContent(for: occurrence),
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: ScheduleDateCodec.calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second],
                        from: triggerDate
                    ),
                    repeats: false
                )
            )

            do {
                try await notificationCenter.add(request)
            } catch {
                logger.error(
                    "schedule fallback notification failed title=\(occurrence.title, privacy: .private) trigger=\(Self.debugDateFormatter.string(from: triggerDate), privacy: .private) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        logger.debug("scheduled fallback notifications count=\(min(scheduledItems.count, 64), privacy: .public)")
    }

    /// 构造与 Live Activity 同语义的本地通知内容。
    private func fallbackNotificationContent(for occurrence: CourseReminderOccurrence) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = occurrence.kindText == "日程" ? "即将开始日程" : "即将上课"

        let subtitle = occurrence.classroom.trimmingCharacters(in: .whitespacesAndNewlines)
        let teacher = occurrence.teacher.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = [
            occurrence.title,
            Self.timeRangeText(start: occurrence.startDate, end: occurrence.endDate),
            subtitle,
            teacher.isEmpty || teacher == subtitle ? nil : teacher,
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        content.body = summary
        content.sound = .default
        content.threadIdentifier = "BIT101.ScheduleReminder"
        return content
    }

    private func pendingFallbackNotificationIdentifiers(prefix: String) async -> [String] {
        await withCheckedContinuation { continuation in
            notificationCenter.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier).filter { $0.hasPrefix(prefix) })
            }
        }
    }

    private func deliveredFallbackNotificationIdentifiers(prefix: String) async -> [String] {
        await withCheckedContinuation { continuation in
            notificationCenter.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.map(\.request.identifier).filter { $0.hasPrefix(prefix) })
            }
        }
    }

    private static let displayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let notificationIdentifierPrefix = "BIT101.ScheduleReminder"

    private static func notificationIdentifier(studentID: String, index: Int) -> String {
        "\(notificationIdentifierPrefix).\(studentID.isEmpty ? "__default__" : studentID).\(index)"
    }
}

#else

import Foundation

/// Mac Catalyst 不支持 ActivityKit。
///
/// 这条提醒链路服务 iPhone/iPad 的锁屏与灵动岛。Catalyst 版本提供与 iOS 同签名的
/// 空实现，保持项目编译和原生界面预览。
@MainActor
final class ScheduleLiveActivityManager {
    static let shared = ScheduleLiveActivityManager()

    enum NotificationAuthorizationState {
        case allowed
        case notDetermined
        case denied
    }

    private init() {}

    /// Catalyst 下锁屏和灵动岛提醒保持空操作。
    func refreshFromCurrentCache(trigger: String = "unspecified") async {}

    /// Catalyst 版将本地通知权限请求视为已完成。
    func requestNotificationAuthorizationIfNeeded() async -> Bool { true }

    /// Mac 预览固定使用允许状态，避免反复弹出“请开启通知”。
    func notificationAuthorizationStateForReminderFallback() async -> NotificationAuthorizationState { .allowed }

    /// Catalyst 下没有 Activity，保持空操作。
    func endAllActivities() async {}

    /// Catalyst 下保持 BGAppRefreshTask 链路关闭。
    func preferredBackgroundRefreshBeginDate() -> Date? { nil }
}

#endif
