import Foundation

/// AppDateText 统一解析社区时间文案并生成相对时间。
///
/// 课程评论、话廊帖子和消息接口共用以下日期格式；业务页面提供空值回退文案，
/// AppDateText 统一维护日期格式和解析顺序。
enum AppDateText {
    private static let inputFormats = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ssZ",
    ]

    static func date(from raw: String) -> Date? {
        for format in inputFormats {
            let formatter = makeInputFormatter(format)
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func relativeText(from raw: String, fallback: String) -> String {
        guard let date = date(from: raw) else { return fallback }
        return makeRelativeFormatter().localizedString(for: date, relativeTo: Date())
    }

    static func dayText(from raw: String) -> String {
        formattedText(from: raw, using: makeOutputFormatter("yyyy-MM-dd"))
    }

    static func timestampText(from raw: String) -> String {
        formattedText(from: raw, using: makeOutputFormatter("yyyy-MM-dd HH:mm"))
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
        formatter.isLenient = false
        return formatter
    }

    private static func makeOutputFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    private static func makeRelativeFormatter() -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }
}
