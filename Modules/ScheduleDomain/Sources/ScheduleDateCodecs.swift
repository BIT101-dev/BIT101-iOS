import ScheduleContracts
import Foundation

public enum ScheduleDateCodec {
    /// 采用固定公历计算周数，独立于系统日历设置。
    public static let calendar = ScheduleSharedDateCodec.calendar

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "HH:mm"
        formatter.isLenient = false
        return formatter
    }()

    private static let relativeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    public static func parseDate(_ string: String) -> Date? {
        ScheduleSharedDateCodec.parseDate(string)
    }

    /// 解析 `HH:mm` 文本为一个只关心时分的 `Date`。
    public static func parseTime(_ string: String) -> Date? {
        guard let date = timeFormatter.date(from: string), timeFormatter.string(from: date) == string else {
            return nil
        }
        return date
    }

    /// 格式化时分文本。
    public static func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// 格式化 `yyyy-MM-dd` 文本。
    public static func formatDate(_ date: Date) -> String {
        ScheduleSharedDateCodec.formatDate(date)
    }

    /// 返回给定日期所在自然周的周一，用于保证课表首周基准始终从周一开始。
    public static func monday(containing date: Date) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysAfterMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysAfterMonday, to: startOfDay) ?? startOfDay
    }

    /// 格式化 `M月d日` 短日期。
    public static func formatShortDate(_ date: Date) -> String {
        ScheduleSharedDateCodec.formatShortDate(date)
    }

    /// 格式化精确到分钟的完整日期时间。
    public static func formatDateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    /// 格式化列表里常用的相对简写日期时间。
    public static func formatRelativeDateTime(_ date: Date) -> String {
        relativeFormatter.string(from: date)
    }

    /// 直接把 `HH:mm` 文本转成分钟数。
    public static func minutesOfDay(from string: String) -> Int {
        TimeSlot.parseMinutes(string)
    }

    /// 把系统 weekday 映射成项目内部使用的“周一=1 ... 周日=7”。
    public static func weekdayIndex(from date: Date) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return ((weekday + 5) % 7) + 1
    }

    /// 读取某个 `Date` 在一天中的分钟偏移。
    public static func minutesOfDay(from date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

/// 课表周次与首周偏移的双向转换。
///
/// 产品周次从第 1 周开始编号，第一周之前依次使用第 -1 周、第 -2 周。
public nonisolated enum ScheduleWeekCodec {
    public static func formatWeeks(_ weeks: [Int]) -> String {
        let weeks = Array(Set(weeks.filter { $0 != 0 })).sorted()
        guard !weeks.isEmpty else { return "" }

        let negativeWeeks = weeks.filter { $0 < 0 }.map(String.init)
        let positiveWeeks = weeks.filter { $0 > 0 }
        var ranges: [String] = []
        guard let firstPositiveWeek = positiveWeeks.first else {
            return negativeWeeks.joined(separator: ",")
        }

        var lower = firstPositiveWeek
        var upper = firstPositiveWeek
        for week in positiveWeeks.dropFirst() {
            if week == upper + 1 {
                upper = week
            } else {
                ranges.append(lower == upper ? "\(lower)" : "\(lower)-\(upper)")
                lower = week
                upper = week
            }
        }
        ranges.append(lower == upper ? "\(lower)" : "\(lower)-\(upper)")
        return (negativeWeeks + ranges).joined(separator: ",")
    }

    public static func weekNumber(forDayOffset dayOffset: Int) -> Int {
        let quotient = dayOffset / 7
        let remainder = dayOffset % 7
        let weekOffset = remainder < 0 ? quotient - 1 : quotient
        return weekOffset >= 0 ? weekOffset + 1 : weekOffset
    }

    public static func weekOffset(forWeekNumber week: Int) -> Int {
        week > 0 ? week - 1 : week
    }

}
