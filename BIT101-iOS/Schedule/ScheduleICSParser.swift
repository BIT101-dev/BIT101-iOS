//
//  ScheduleICSParser.swift
//  BIT101-iOS
//

import Foundation

/// 乐学 iCalendar 文本的纯解析器。
enum ScheduleICSParser {
    static func parse(_ ics: String) throws -> [DDLEventRecord] {
        let unfolded = ics
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")

        var events: [DDLEventRecord] = []
        for block in unfolded.components(separatedBy: "BEGIN:VEVENT").dropFirst() {
            guard let content = block.components(separatedBy: "END:VEVENT").first else { continue }

            var values: [String: String] = [:]
            for line in content.split(separator: "\n") {
                guard let separator = line.firstIndex(of: ":") else { continue }
                let keyPart = String(line[..<separator])
                let value = String(line[line.index(after: separator)...])
                let key = keyPart.split(separator: ";").first.map(String.init) ?? keyPart
                values[key] = decodeValue(value)
            }

            guard
                let uid = values["UID"],
                let summary = values["SUMMARY"],
                let rawDate = values["DTSTART"],
                let dueAt = parseDate(rawDate)
            else { continue }

            let description = (values["DESCRIPTION"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let course = (values["CATEGORIES"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            events.append(DDLEventRecord(
                id: uid,
                group: "lexue",
                title: summary,
                text: [course, description].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                dueAt: dueAt,
                done: false
            ))
        }

        guard !events.isEmpty else { throw ScheduleServiceError.invalidCalendarData }
        return events.sorted { $0.dueAt < $1.dueAt }
    }

    static func parseDate(_ value: String) -> Date? {
        if value.hasSuffix("Z") { return utcDateTimeFormatter.date(from: value) }
        return localDateTimeFormatter.date(from: value) ?? dateOnlyFormatter.date(from: value)
    }

    static func decodeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\\,"#, with: ",", options: .regularExpression)
            .replacingOccurrences(of: #"\\;"#, with: ";", options: .regularExpression)
            .replacingOccurrences(of: #"\\\\"#, with: "\\", options: .regularExpression)
    }

    private static let utcDateTimeFormatter = formatter(timeZone: .gmt, format: "yyyyMMdd'T'HHmmss'Z'")
    private static let localDateTimeFormatter = formatter(
        timeZone: TimeZone(secondsFromGMT: 8 * 3600)!,
        format: "yyyyMMdd'T'HHmmss"
    )
    private static let dateOnlyFormatter = formatter(
        timeZone: TimeZone(secondsFromGMT: 8 * 3600)!,
        format: "yyyyMMdd"
    )

    private static func formatter(timeZone: TimeZone, format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
