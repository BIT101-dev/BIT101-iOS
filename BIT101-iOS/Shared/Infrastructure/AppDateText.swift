import Foundation

/// 社区时间文案的唯一解析与相对时间实现。
///
/// 课程评论、话廊帖子和消息接口历史上返回过相同的多种日期格式；业务页面只提供
/// 空值回退文案，不再各自维护一份 formatter 和解析顺序。
enum AppDateText {
    private static let formatters: [DateFormatter] = [
        makeFormatter("yyyy-MM-dd HH:mm:ss"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
    ]

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let relativeFormatter = RelativeDateTimeFormatter()

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

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = format
        return formatter
    }
}
