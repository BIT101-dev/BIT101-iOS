import Foundation

/// AppDateText 统一解析社区时间文案并生成相对时间。
///
/// 课程评论、话廊帖子和消息接口曾返回过同一组日期格式；业务页面提供空值回退文案，
/// AppDateText 统一维护日期格式化器和解析顺序。
enum AppDateText {
    private static let formatters: [DateFormatter] = [
        makeInputFormatter("yyyy-MM-dd HH:mm:ss"),
        makeInputFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ"),
        makeInputFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
    ]

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let relativeFormatter = RelativeDateTimeFormatter()
    private static let dayFormatter = makeOutputFormatter("yyyy-MM-dd")
    private static let timestampFormatter = makeOutputFormatter("yyyy-MM-dd HH:mm")

    static func date(from raw: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return iso8601Formatter.date(from: raw)
    }

    static func relativeText(from raw: String, fallback: String) -> String {
        guard let date = date(from: raw) else { return fallback }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func dayText(from raw: String) -> String {
        formattedText(from: raw, using: dayFormatter)
    }

    static func timestampText(from raw: String) -> String {
        formattedText(from: raw, using: timestampFormatter)
    }

    private static func formattedText(from raw: String, using formatter: DateFormatter) -> String {
        guard let date = date(from: raw) else { return raw }
        return formatter.string(from: date)
    }

    private static func makeInputFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = format
        return formatter
    }

    private static func makeOutputFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter
    }
}
