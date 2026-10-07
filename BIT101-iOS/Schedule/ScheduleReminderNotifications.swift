import Foundation

nonisolated enum ScheduleReminderNotificationAuthorizationState {
    case allowed
    case notDetermined
    case denied
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import UserNotifications
import ScheduleDomain
import ScheduleContracts
import OSLog

/// 系统通知适配器维护授权、课前通知排期和清理。
@MainActor
final class ScheduleReminderNotifications {
    private let notificationCenter: UNUserNotificationCenter
    private let logger = Logger(subsystem: "BIT101", category: "ScheduleReminderNotifications")
    private static let notificationIdentifierPrefix = "BIT101.ScheduleReminder"

    init(center: UNUserNotificationCenter) { notificationCenter = center }

    func authorizationState() async -> ScheduleReminderNotificationAuthorizationState {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    /// 按与 Live Activity 相同的规则预排本地通知。
    ///
    /// 本地通知作为 fallback：app 后台未被唤醒或 Activity 未按时出现时，用户仍能在同一提醒窗口收到通知。
    func synchronize(
        for occurrences: [CourseReminderOccurrence],
        leadMinutes: Int,
        session: ScheduleReminderSession,
        isCurrent: @MainActor () -> Bool
    ) async {
        let studentID = session.studentID
        guard !Task.isCancelled, isCurrent() else { return }
        let settings = await notificationCenter.notificationSettings()
        guard !Task.isCancelled, isCurrent() else { return }
        let allowedStatuses: Set<UNAuthorizationStatus> = [.authorized, .provisional, .ephemeral]
        guard allowedStatuses.contains(settings.authorizationStatus) else {
            logger.debug("notifications not authorized; clearing fallback reminders")
            await clear()
            return
        }

        await clear()

        guard !Task.isCancelled, isCurrent() else { return }

        let now = Date()
        let scheduledItems = occurrences
            .compactMap { occurrence -> (CourseReminderOccurrence, Date)? in
                let displayStart = ScheduleReminderPlanner.effectiveDisplayWindowStart(
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
            guard !Task.isCancelled, isCurrent() else { return }

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
                    "schedule fallback notification failed title=\(occurrence.title, privacy: .private) trigger=\(triggerDate.description, privacy: .private) error=\(error.localizedDescription, privacy: .public)"
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
            ScheduleReminderPlanner.timeRangeText(start: occurrence.startDate, end: occurrence.endDate),
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

    /// 删除已排期和已送达的课前提醒 fallback 通知。
    func clear() async {
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

    private static func notificationIdentifier(studentID: String, index: Int) -> String {
        "\(notificationIdentifierPrefix).\(studentID.isEmpty ? "__default__" : studentID).\(index)"
    }

    /// 首次开启提醒时申请本地通知权限。
    ///
    /// 本地通知作为 Activity 未启动时的兜底。授权由用户决定；授权后，app 未被唤醒时
    /// 仍能按同一规则发送课前通知。
    func requestAuthorizationIfNeeded() async -> Bool {
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
}
#endif
