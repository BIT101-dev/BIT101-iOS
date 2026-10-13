//
//  ScheduleICSParser.swift
//  BIT101-iOS
//

import Foundation

/// 乐学 iCalendar 文本的纯解析器。
public nonisolated enum ScheduleICSParser {
    public enum ParseError: Error { case invalidCalendarData }
    public static func parse(_ ics: String) throws -> [DDLEventRecord] {
        try Task.checkCancellation()
        let lines = unfoldLines(in: ics).filter { !$0.isEmpty }
        guard lines.first?.caseInsensitiveCompare("BEGIN:VCALENDAR") == .orderedSame,
              lines.last?.caseInsensitiveCompare("END:VCALENDAR") == .orderedSame
        else {
            throw ParseError.invalidCalendarData
        }

        var currentEvent: [String: Property]?
        var eventsByID: [String: DDLEventRecord] = [:]
        var cancelledIDs = Set<String>()
        var components: [String] = []
        var hasCalendar = false

        for (index, line) in lines.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            let controlLine = line.uppercased()
            if controlLine.hasPrefix("BEGIN:") {
                let name = String(controlLine.dropFirst(6))
                guard name != "VTODO" else { throw ParseError.invalidCalendarData }
                if name == "VCALENDAR" {
                    guard components.isEmpty, !hasCalendar else { throw ParseError.invalidCalendarData }
                    hasCalendar = true
                } else {
                    guard !components.isEmpty else { throw ParseError.invalidCalendarData }
                }
                if name == "VEVENT" {
                    guard components == ["VCALENDAR"], currentEvent == nil else { throw ParseError.invalidCalendarData }
                    currentEvent = [:]
                }
                components.append(name)
                continue
            }

            if controlLine.hasPrefix("END:") {
                let name = String(controlLine.dropFirst(4))
                guard components.last == name else { throw ParseError.invalidCalendarData }
                if name == "VEVENT" {
                    guard let properties = currentEvent else { throw ParseError.invalidCalendarData }
                    if properties["STATUS"]?.value.uppercased() == "CANCELLED" {
                        guard let uid = properties["UID"]?.value.trimmingCharacters(in: .whitespacesAndNewlines),
                              !uid.isEmpty else { throw ParseError.invalidCalendarData }
                        cancelledIDs.insert(uid)
                        eventsByID[uid] = nil
                    } else {
                        guard let event = makeEvent(from: properties) else { throw ParseError.invalidCalendarData }
                        guard eventsByID[event.id] == nil || eventsByID[event.id] == event else { throw ParseError.invalidCalendarData }
                        if !cancelledIDs.contains(event.id) { eventsByID[event.id] = event }
                    }
                    currentEvent = nil
                }
                components.removeLast()
                continue
            }

            guard currentEvent != nil, components.last == "VEVENT" else { continue }
            let (keyParts, value) = try splitProperty(line)
            guard let name = keyParts.first, !name.isEmpty else { throw ParseError.invalidCalendarData }
            let propertyName = name.uppercased()
            if ["UID", "DTSTART", "SUMMARY", "DESCRIPTION", "STATUS"].contains(propertyName), currentEvent?[propertyName] != nil {
                throw ParseError.invalidCalendarData
            }
            guard !["RRULE", "RDATE", "EXDATE", "RECURRENCE-ID"].contains(name.uppercased()) else {
                throw ParseError.invalidCalendarData
            }

            var parameters: [String: String] = [:]
            for parameter in keyParts.dropFirst() {
                let parameterParts = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parameterParts.count == 2 else { throw ParseError.invalidCalendarData }
                let parameterName = parameterParts[0].uppercased()
                guard !parameterName.isEmpty, parameters[parameterName] == nil else { throw ParseError.invalidCalendarData }
                parameters[parameterName] = String(parameterParts[1])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }

            currentEvent?[propertyName] = Property(
                value: decodeValue(value),
                parameters: parameters
            )
        }

        guard components.isEmpty, currentEvent == nil else { throw ParseError.invalidCalendarData }
        return eventsByID.values.sorted { lhs, rhs in
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            return lhs.id < rhs.id
        }
    }

    public static func parseDate(_ value: String) -> Date? {
        parseDate(value, timeZone: nil)
    }

    public static func decodeValue(_ value: String) -> String {
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

    private static func splitProperty(_ line: String) throws -> ([Substring], String) {
        var quoted = false
        var start = line.startIndex
        var header: [Substring] = []
        for index in line.indices {
            switch line[index] {
            case "\"": quoted.toggle()
            case ";" where !quoted:
                header.append(line[start..<index])
                start = line.index(after: index)
            case ":" where !quoted:
                header.append(line[start..<index])
                return (header, String(line[line.index(after: index)...]))
            default: break
            }
        }
        throw ParseError.invalidCalendarData
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

        let timeZone: TimeZone?
        if let rawIdentifier = start.parameters["TZID"] {
            let identifier = rawIdentifier.hasPrefix("\"") && rawIdentifier.hasSuffix("\"")
                ? String(rawIdentifier.dropFirst().dropLast()) : rawIdentifier
            guard let identified = TimeZone(identifier: identifier) else { return nil }
            timeZone = identified
        } else {
            timeZone = nil
        }
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
