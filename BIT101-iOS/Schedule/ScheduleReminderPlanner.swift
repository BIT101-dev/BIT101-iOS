import Foundation
import ScheduleDomain
import ScheduleContracts

nonisolated struct CourseReminderOccurrence: Equatable, Sendable {
    let kindText: String
    let title: String
    let classroom: String
    let teacher: String
    let startDate: Date
    let endDate: Date
}

/// 提醒候选、展示窗口和刷新边界使用同一组纯规则。
nonisolated enum ScheduleReminderPlanner {
    /// 把课表缓存解析成仍然有效的提醒候选。
    ///
    /// 这里同时覆盖：
    /// - 常规课程
    /// - 自定义日程
    ///
    /// 结果保留结束时间晚于当前时间的实例。
    static func resolveOccurrences(from cache: ScheduleCache, now: Date = Date()) -> [CourseReminderOccurrence] {
        let slotMap = Dictionary(
            cache.timeTable.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var results: [CourseReminderOccurrence] = []
        var seenOccurrenceKeys = Set<String>()

        // 处理常规课程
        if let firstDay = cache.firstDay {
            for course in cache.courses {
                for week in Set(course.weeks).sorted() {
                    guard seenOccurrenceKeys.insert("course-\(course.id)-w\(week)").inserted else { continue }
                    guard week > 0,
                          (1...7).contains(course.weekday),
                          let startSlot = slotMap[course.startSection],
                          let endSlot = slotMap[course.endSection],
                          let start = ScheduleSharedDateCodec.combine(firstDay: firstDay, week: week, weekday: course.weekday, time: startSlot.start),
                          let end = ScheduleSharedDateCodec.combine(firstDay: firstDay, week: week, weekday: course.weekday, time: endSlot.end),
                          end > start,
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
            guard seenOccurrenceKeys.insert("custom-\(schedule.id)").inserted else { continue }
            guard let date = ScheduleSharedDateCodec.parseDate(schedule.dateString),
                  let start = ScheduleSharedDateCodec.combine(date: date, time: schedule.beginTime),
                  let end = ScheduleSharedDateCodec.combine(date: date, time: schedule.endTime),
                  end > start,
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
    static func effectiveDisplayWindowStart(
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

    /// 计算下一条刷新边界。
    ///
    /// 调度关注两个时刻：
    /// 1. 某条提醒进入可展示窗口
    /// 2. 某条提醒正式开始，现有提醒应结束
    ///
    /// 本地 Task.sleep 调度和 BGAppRefresh 建议时间共用这套计算。
    static func nextFutureRefreshPoint(
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

    static func timeRangeText(start: Date, end: Date) -> String {
        "\(ScheduleSharedDateCodec.formatTime(start))-\(ScheduleSharedDateCodec.formatTime(end))"
    }
}
