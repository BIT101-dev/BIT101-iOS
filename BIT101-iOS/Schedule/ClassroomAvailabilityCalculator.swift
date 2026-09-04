//
//  ClassroomAvailabilityCalculator.swift
//  BIT101-iOS
//

import Foundation

/// 把学校接口的教室占用数据转换为可展示状态的纯计算器。
enum ClassroomAvailabilityCalculator {
    static func availabilities(
        records: [ClassroomRecord],
        timeTable: [TimeSlot],
        selectedSections: [Int],
        nowMinutes: Int
    ) -> [ClassroomAvailability] {
        let selected = normalizedSections(selectedSections, in: timeTable)
        let currentFreeOnly = selected.isEmpty
        let selectedSet = Set(selected)

        return records
            .map { availability(for: $0, timeTable: timeTable, nowMinutes: nowMinutes) }
            .filter { item in
                currentFreeOnly ? item.isFreeNow : !selectedSet.isDisjoint(with: item.freeSections)
            }
            .sorted { lhs, rhs in
                if currentFreeOnly, lhs.isFreeNow != rhs.isFreeNow { return lhs.isFreeNow }
                return classroomNameAscending(lhs, rhs)
            }
    }

    static func availability(
        for record: ClassroomRecord,
        timeTable: [TimeSlot],
        nowMinutes: Int
    ) -> ClassroomAvailability {
        let busy = Set(record.busyTimeCodes)
        let freeSections = timeTable.map(\.id).filter { !busy.contains($0) }
        let nextBusyStart = timeTable
            .filter { busy.contains($0.id) && $0.startMinutes >= nowMinutes }
            .map(\.startMinutes)
            .min()
        let currentBusySlot = timeTable.first {
            busy.contains($0.id) && $0.startMinutes <= nowMinutes && nowMinutes < $0.endMinutes
        }

        let isFreeNow: Bool
        let statusText: String
        let detailText: String
        if currentBusySlot == nil, let nextBusyStart {
            isFreeNow = true
            statusText = "还会空闲 \(durationText(minutes: nextBusyStart - nowMinutes))"
            detailText = "直到 \(TimeSlot.formatMinutes(nextBusyStart))"
        } else if currentBusySlot == nil {
            isFreeNow = true
            statusText = "空闲到明天"
            detailText = ""
        } else if let nextFree = nextFreeStart(for: record, in: timeTable, after: nowMinutes) {
            isFreeNow = false
            statusText = "\(durationText(minutes: nextFree - nowMinutes)) 后空闲"
            detailText = TimeSlot.formatMinutes(nextFree)
        } else {
            isFreeNow = false
            statusText = "使用中"
            detailText = ""
        }

        return ClassroomAvailability(
            id: record.id,
            name: record.name,
            prettyFreeTimes: sectionsText(freeSections),
            statusText: statusText,
            detailText: detailText,
            isFreeNow: isFreeNow,
            freeSections: freeSections
        )
    }

    static func normalizedSections(_ values: [Int], in timeTable: [TimeSlot]) -> [Int] {
        let valid = Set(timeTable.map(\.id))
        return Array(Set(values.filter(valid.contains))).sorted()
    }

    static func sectionsText(_ sections: [Int]) -> String {
        let sections = Array(Set(sections)).sorted()
        guard !sections.isEmpty else { return "无" }

        var groups: [[Int]] = []
        for section in sections {
            if var last = groups.last, last.last == section - 1 {
                last.append(section)
                groups[groups.count - 1] = last
            } else {
                groups.append([section])
            }
        }
        return groups.map { group in
            guard let first = group.first, let last = group.last else { return "" }
            return group.count == 1 ? "\(first)" : "\(first)~\(last)"
        }.joined(separator: ", ")
    }

    static func matchedSectionsText(
        freeSections: [Int],
        selectedSections: [Int],
        timeTable: [TimeSlot]
    ) -> String {
        let selected = normalizedSections(selectedSections, in: timeTable)
        guard !selected.isEmpty else { return "" }
        return sectionsText(freeSections.filter(Set(selected).contains))
    }

    static func sectionBlock(at minutes: Int, in timeTable: [TimeSlot]) -> [Int] {
        let activeID = timeTable.first {
            $0.startMinutes <= minutes && minutes < $0.endMinutes
        }?.id ?? timeTable.first(where: { $0.startMinutes > minutes })?.id

        switch activeID {
        case 1, 2: return [1, 2]
        case 3, 4, 5: return [3, 4, 5]
        case 6, 7: return [6, 7]
        case 8, 9, 10: return [8, 9, 10]
        case 11, 12, 13: return [11, 12, 13]
        case let id?: return [id]
        case nil: return []
        }
    }

    static func normalizedBuildingName(_ value: String) -> String {
        let scalars = value
            .uppercased()
            .replacingOccurrences(of: "理教楼", with: "理教")
            .replacingOccurrences(of: "文萃楼", with: "文萃")
            .replacingOccurrences(of: "教学楼", with: "")
            .replacingOccurrences(of: "楼", with: "")
            .unicodeScalars
            .filter {
                !CharacterSet.whitespacesAndNewlines.contains($0) &&
                    !CharacterSet.punctuationCharacters.contains($0) &&
                    !CharacterSet.symbols.contains($0)
            }
        return String(String.UnicodeScalarView(scalars))
    }

    static func buildingCandidates(from classroom: String) -> [String] {
        let normalized = normalizedBuildingName(classroom)
        guard !normalized.isEmpty else { return [] }
        guard let digit = normalized.firstIndex(where: \.isNumber) else { return [normalized] }
        let prefix = String(normalized[..<digit])
        return prefix.isEmpty ? [normalized] : [normalized, prefix]
    }

    private static func nextFreeStart(
        for record: ClassroomRecord,
        in timeTable: [TimeSlot],
        after minutes: Int
    ) -> Int? {
        let busy = Set(record.busyTimeCodes)
        for slot in timeTable where slot.endMinutes > minutes && !busy.contains(slot.id) {
            return max(minutes, slot.startMinutes)
        }
        return nil
    }

    private static func durationText(minutes: Int) -> String {
        let totalMinutes = max(minutes, 0)
        if totalMinutes == 0 { return "< 1 分钟" }
        if totalMinutes < 60 { return "\(totalMinutes) 分钟" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分钟"
    }
}
