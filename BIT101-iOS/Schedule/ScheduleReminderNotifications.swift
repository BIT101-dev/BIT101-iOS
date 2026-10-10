import Foundation
import ScheduleDomain

@MainActor
enum ScheduleReminderNotificationDate {
    static func components(for date: Date) -> DateComponents {
        let trigger = Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.up))
        return ScheduleDateCodec.calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: trigger)
    }

    static func futureDisplayDate(for occurrence: CourseReminderOccurrence, among occurrences: [CourseReminderOccurrence],
        leadMinutes: Int, now: Date) -> Date? {
        let start = ScheduleReminderPlanner.effectiveDisplayWindowStart(for: occurrence, among: occurrences, leadMinutes: leadMinutes)
        return start > now && start < occurrence.startDate ? start : nil
    }
}

nonisolated enum ScheduleReminderNotificationAuthorizationState {
    case allowed
    case notDetermined
    case denied
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import UserNotifications
import ScheduleContracts
import OSLog

@MainActor
protocol ScheduleReminderNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus
    func pendingRequests() async -> [UNNotificationRequest]
    func deliveredIdentifiers() async -> [String]
    func add(_ request: UNNotificationRequest) async throws
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
    func requestAuthorization() async throws -> Bool
}

@MainActor
private struct SystemScheduleReminderNotificationCenter: ScheduleReminderNotificationCenter {
    let center: UNUserNotificationCenter
    func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func pendingRequests() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func deliveredIdentifiers() async -> [String] { await center.deliveredNotifications().map(\.request.identifier) }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
}

private struct ScheduleReminderNotificationReplacementError: LocalizedError {
    let original: Error
    let restorationFailures: Int
    var errorDescription: String? {
        "提醒更新失败：\(original.localizedDescription)；\(restorationFailures) 条原提醒恢复失败。"
    }
}

/// 系统通知适配器维护授权、课前通知排期和清理。
@MainActor
final class ScheduleReminderNotifications {
    private let notificationCenter: any ScheduleReminderNotificationCenter
    private let logger = Logger(subsystem: "BIT101", category: "ScheduleReminderNotifications")
    private static let notificationIdentifierPrefix = "BIT101.ScheduleReminder"

    init(center: UNUserNotificationCenter) { notificationCenter = SystemScheduleReminderNotificationCenter(center: center) }
    init(center: any ScheduleReminderNotificationCenter) { notificationCenter = center }

    func authorizationState() async -> ScheduleReminderNotificationAuthorizationState {
        let authorization = await notificationCenter.authorizationStatus()
        switch authorization {
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
    ) async throws -> Int {
        func checkCurrent() throws {
            guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
        }
        try checkCurrent()
        let authorization = await notificationCenter.authorizationStatus()
        try checkCurrent()
        let previous = await notificationCenter.pendingRequests().filter { $0.identifier.hasPrefix(Self.notificationIdentifierPrefix) }
        let delivered = await notificationCenter.deliveredIdentifiers().filter { $0.hasPrefix(Self.notificationIdentifierPrefix) }
        try checkCurrent()
        guard [.authorized, .provisional, .ephemeral].contains(authorization) else {
            notificationCenter.removePending(previous.map(\.identifier))
            notificationCenter.removeDelivered(delivered)
            return 0
        }
        let now = Date()
        let scheduledItems = zip(occurrences, ScheduleReminderPlanner.displayWindowStarts(for: occurrences, leadMinutes: leadMinutes))
            .compactMap { occurrence, displayStart -> (CourseReminderOccurrence, Date)? in
                guard displayStart > now, displayStart < occurrence.startDate else { return nil }
                return (occurrence, displayStart)
            }
            .sorted { $0.1 < $1.1 }
        let requests = scheduledItems.prefix(64).enumerated().map { index, item in
            UNNotificationRequest(
                identifier: Self.notificationIdentifier(studentID: session.studentID, index: index),
                content: fallbackNotificationContent(for: item.0),
                trigger: UNCalendarNotificationTrigger(dateMatching: ScheduleReminderNotificationDate.components(for: item.1), repeats: false))
        }
        var attempted = Set<String>()
        do {
            for request in requests {
                try checkCurrent()
                attempted.insert(request.identifier)
                try await notificationCenter.add(request)
            }
            try checkCurrent()
        } catch {
            let retainedIDs = Set(previous.map(\.identifier))
            notificationCenter.removePending(Array(isCurrent() ? attempted.subtracting(retainedIDs) : attempted))
            var restorationFailures = 0
            if isCurrent() {
                for request in previous where attempted.contains(request.identifier) {
                    guard isCurrent() else { break }
                    do { try await notificationCenter.add(request) }
                    catch { restorationFailures += 1 }
                }
            }
            if !isCurrent() { notificationCenter.removePending(Array(attempted)) }
            if restorationFailures > 0 {
                throw ScheduleReminderNotificationReplacementError(original: error, restorationFailures: restorationFailures)
            }
            throw error
        }
        notificationCenter.removePending(previous.map(\.identifier).filter { !attempted.contains($0) })
        notificationCenter.removeDelivered(delivered)
        logger.debug("scheduled fallback notifications count=\(requests.count, privacy: .public)")
        return requests.count
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

    /// 删除已排期和已送达的课前提醒 fallback 通知。
    func clear() async {
        let pending = await notificationCenter.pendingRequests().map(\.identifier).filter { $0.hasPrefix(Self.notificationIdentifierPrefix) }
        notificationCenter.removePending(pending)
        let delivered = await notificationCenter.deliveredIdentifiers().filter { $0.hasPrefix(Self.notificationIdentifierPrefix) }
        notificationCenter.removeDelivered(delivered)
    }

    private static func notificationIdentifier(studentID: String, index: Int) -> String {
        "\(notificationIdentifierPrefix).\(studentID.isEmpty ? "__default__" : studentID).\(index)"
    }

    /// 首次开启提醒时申请本地通知权限。
    ///
    /// 本地通知作为 Activity 未启动时的兜底。授权由用户决定；授权后，app 未被唤醒时
    /// 仍能按同一规则发送课前通知。
    func requestAuthorizationIfNeeded() async -> Bool {
        let authorization = await notificationCenter.authorizationStatus()

        switch authorization {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await notificationCenter.requestAuthorization()
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
