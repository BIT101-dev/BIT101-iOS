//
//  ScheduleICSParser.swift
//  BIT101-iOS
//

import Foundation

/// 乐学 iCalendar 文本的纯解析器。
enum ScheduleICSParser {
    static func parse(_ ics: String) throws -> [DDLEventRecord] {
        let lines = unfoldLines(in: ics)
        let uppercasedLines = lines.map { $0.uppercased() }
        guard uppercasedLines.contains("BEGIN:VCALENDAR"), uppercasedLines.contains("END:VCALENDAR") else {
            throw ScheduleServiceError.invalidCalendarData
        }

        var currentEvent: [String: Property]?
        var eventsByID: [String: DDLEventRecord] = [:]

        for line in lines {
            let controlLine = line.uppercased()
            if controlLine == "BEGIN:VEVENT" {
                currentEvent = [:]
                continue
            }

            if controlLine == "END:VEVENT" {
                if let currentEvent, let event = makeEvent(from: currentEvent) {
                    eventsByID[event.id] = event
                }
                currentEvent = nil
                continue
            }

            guard currentEvent != nil,
                  let separator = line.firstIndex(of: ":")
            else { continue }

            let keyPart = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            let keyParts = keyPart.split(separator: ";", omittingEmptySubsequences: false)
            guard let name = keyParts.first, !name.isEmpty else { continue }

            var parameters: [String: String] = [:]
            for parameter in keyParts.dropFirst() {
                let parameterParts = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parameterParts.count == 2 else { continue }
                parameters[String(parameterParts[0]).uppercased()] = String(parameterParts[1])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }

            currentEvent?[String(name).uppercased()] = Property(
                value: decodeValue(value),
                parameters: parameters
            )
        }

        return eventsByID.values.sorted { lhs, rhs in
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            return lhs.id < rhs.id
        }
    }

    static func parseDate(_ value: String) -> Date? {
        parseDate(value, timeZone: nil)
    }

    static func decodeValue(_ value: String) -> String {
        var decoded = ""
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "\\", index + 1 < characters.count else {
                decoded.append(character)
                index += 1
                continue
            }

            index += 1
            switch characters[index] {
            case "n", "N": decoded.append("\n")
            case ",": decoded.append(",")
            case ";": decoded.append(";")
            case "\\": decoded.append("\\")
            default:
                decoded.append("\\")
                decoded.append(characters[index])
            }
            index += 1
        }
        return decoded
    }

    private struct Property {
        let value: String
        let parameters: [String: String]
    }

    private static func unfoldLines(in ics: String) -> [String] {
        let normalized = ics
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines: [String] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.index(before: lines.endIndex)].append(String(line.dropFirst()))
            } else {
                lines.append(line)
            }
        }
        return lines
    }

    private static func makeEvent(from properties: [String: Property]) -> DDLEventRecord? {
        guard
            let uid = properties["UID"]?.value.trimmingCharacters(in: .whitespacesAndNewlines),
            !uid.isEmpty,
            let summary = properties["SUMMARY"]?.value,
            let start = properties["DTSTART"]
        else { return nil }

        let timeZone = start.parameters["TZID"].flatMap { TimeZone(identifier: $0) }
        guard let dueAt = parseDate(start.value, timeZone: timeZone) else { return nil }

        let description = (properties["DESCRIPTION"]?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let course = (properties["CATEGORIES"]?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DDLEventRecord(
            id: uid,
            group: "lexue",
            title: summary,
            text: [course, description].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            dueAt: dueAt,
            done: false
        )
    }

    private static func parseDate(_ value: String, timeZone: TimeZone?) -> Date? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("Z") {
            return parse(value, timeZone: .gmt, format: "yyyyMMdd'T'HHmmss'Z'")
        }

        let resolvedTimeZone = timeZone ?? TimeZone(identifier: "Asia/Shanghai") ?? .current
        return parse(value, timeZone: resolvedTimeZone, format: "yyyyMMdd'T'HHmmss")
            ?? parse(value, timeZone: resolvedTimeZone, format: "yyyyMMdd")
    }

    private static func parse(_ value: String, timeZone: TimeZone, format: String) -> Date? {
        let formatter = formatter(timeZone: timeZone, format: format)
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            return nil
        }
        return date
    }

    private static func formatter(timeZone: TimeZone, format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}
