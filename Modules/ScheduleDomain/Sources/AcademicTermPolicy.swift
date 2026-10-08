import Foundation
import ScheduleContracts

/// 校正上半学期中由小学期产生的周次整体偏移。
///
/// 教务接口的 `SKZC` 有时沿用完整校历计数，`YPSJDD` 按小学期重新从第 1 周标注。
/// 代码仅在证据确认偏移为 3 周时全局减 3 周，其他情况保留原数据。
public nonisolated enum SmallTermWeekNormalizer {
    /// 结果包含两种状态：`0` 表示不变，`3` 表示全局减 3 周。
    public static let correctionOffset = 3

    public nonisolated struct Result: Sendable {
        public let firstDayString: String
        public let courses: [CourseRecord]
        public let offset: Int
    }

    public static func normalize(
        term: String,
        firstDayString: String,
        courses: [CourseRecord],
        rawWeeksByCourse: [[Int]]? = nil
    ) -> Result {
        let unchanged = Result(firstDayString: firstDayString, courses: courses, offset: 0)
        guard term.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-1"),
              !courses.isEmpty
        else { return unchanged }

        struct CourseGroup {
            var rawWeeks = Set<Int>()
            var describedWeeks = Set<Int>()
        }

        let sourceRawWeeks = rawWeeksByCourse?.count == courses.count ? rawWeeksByCourse : nil
        var groups: [String: CourseGroup] = [:]
        for (index, course) in courses.enumerated() {
            let described = weeksDescribed(in: course.description)
            guard !described.isEmpty else { continue }
            let key = "\(course.number)|\(course.name)|\(course.description)"
            var group = groups[key, default: CourseGroup()]
            group.rawWeeks.formUnion(sourceRawWeeks?[index] ?? course.weeks)
            group.describedWeeks.formUnion(described)
            groups[key] = group
        }
        guard !groups.isEmpty else { return unchanged }

        var offsets = Set<Int>()
        var evidenceCount = 0
        for group in groups.values {
            let raw = group.rawWeeks.sorted()
            let described = group.describedWeeks.sorted()
            // 个别短课返回一周，或使用 -2/-1 这类开学前周次；这类组从全学期叠加候选中排除
            // 偏移判定，其他证据组继续参与校正。
            guard raw.count == described.count, raw.count >= 2,
                  described.allSatisfy({ $0 > 0 })
            else { continue }
            let differences = Set(zip(raw, described).map(-))
            guard differences.count == 1, let difference = differences.first else { continue }
            offsets.insert(difference)
            evidenceCount += 1
        }

        guard offsets == Set([correctionOffset]), evidenceCount >= 2 else { return unchanged }

        let shiftedFirstDay = parseDate(firstDayString)
            .flatMap { calendar.date(byAdding: .day, value: correctionOffset * 7, to: $0) }

        return Result(
            firstDayString: shiftedFirstDay.map(formatDate) ?? firstDayString,
            courses: sourceRawWeeks == nil
                ? courses.map { shiftingWeeks(of: $0, by: -correctionOffset) }
                : courses,
            offset: correctionOffset
        )
    }

    private static var calendar: Calendar {
        ScheduleSharedDateCodec.calendar
    }

    private static func parseDate(_ string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: parts[0],
            month: parts[1],
            day: parts[2]
        ))
    }

    private static func formatDate(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    public static func weeksDescribed(in text: String) -> Set<Int> {
        let pattern = #"(-?\d{1,2})\s*(?:[-－—~～至]\s*(-?\d{1,2}))?\s*周"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var result = Set<Int>()
        for match in expression.matches(in: text, range: range) {
            guard let lowerRange = Range(match.range(at: 1), in: text),
                  let lower = Int(text[lowerRange])
            else { continue }
            if match.range(at: 2).location != NSNotFound,
               let upperRange = Range(match.range(at: 2), in: text),
               let upper = Int(text[upperRange]),
               upper >= lower
            {
                result.formUnion(lower ... upper)
            } else {
                result.insert(lower)
            }
        }
        return result
    }

    private static func shiftingWeeks(of course: CourseRecord, by delta: Int) -> CourseRecord {
        course.replacingWeeks(course.weeks.map { $0 < 1 ? $0 : $0 + delta })
    }
}

/// 教务接口把同一门课的多个上课安排合并到 `YPSJDD`，每行的 `SKXQ`、节次和教室对应一项安排。
/// 解析器按行恢复周次，各星期使用对应行的周次。
public nonisolated enum CourseScheduleRowParser {
    private struct Occurrence {
        let weeks: Set<Int>
        let weekday: Int
        let startSection: Int
        let endSection: Int
        let classroom: String
    }

    public static func narrowedCourses(_ courses: [CourseRecord]) -> [CourseRecord] {
        courses.map { course in
            let weeks = narrowedWeeks(for: course)
            return weeks == course.weeks ? course : course.replacingWeeks(weeks)
        }
    }

    private static func narrowedWeeks(for course: CourseRecord) -> [Int] {
        let occurrences = occurrences(in: course.description)
        guard !occurrences.isEmpty else { return course.weeks }

        let sameTime = occurrences.filter {
            $0.weekday == course.weekday
                && $0.startSection == course.startSection
                && $0.endSection == course.endSection
        }
        guard !sameTime.isEmpty else { return course.weeks }

        let exact = sameTime.filter {
            normalizedClassroom($0.classroom) == normalizedClassroom(course.classroom)
        }
        let matched = exact.isEmpty && sameTime.count == 1 ? sameTime : exact
        guard !matched.isEmpty else { return course.weeks }

        let describedWeeks = matched.reduce(into: Set<Int>()) { result, occurrence in
            result.formUnion(occurrence.weeks)
        }
        let currentWeeks = Set(course.weeks)
        guard !describedWeeks.isEmpty else { return course.weeks }
        if describedWeeks.allSatisfy({ $0 < 0 }) {
            return describedWeeks.sorted()
        }
        // 解析器在描述周次属于当前课程周次集合时收窄，坐标系证据不足时保留原值。
        // 小学期整体 -3 由 SmallTermWeekNormalizer 统一处理。
        guard describedWeeks.isSubset(of: currentWeeks) else { return course.weeks }
        return course.weeks.filter { describedWeeks.contains($0) }
    }

    private static func occurrences(in text: String) -> [Occurrence] {
        let pattern = #"((?:-?\d{1,2}\s*(?:[-－—~～至]\s*-?\d{1,2})?\s*周)(?:\s*,\s*(?:-?\d{1,2}\s*(?:[-－—~～至]\s*-?\d{1,2})?\s*周))*)\s*星期([一二三四五六日天])\s*第?(\d{1,2})\s*节?\s*[-－—~～至]\s*第?(\d{1,2})\s*节\s*(.*?)(?=,\s*-?\d{1,2}\s*(?:[-－—~～至]\s*-?\d{1,2})?\s*周|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard
                let weeksRange = Range(match.range(at: 1), in: text),
                let weekdayRange = Range(match.range(at: 2), in: text),
                let startRange = Range(match.range(at: 3), in: text),
                let endRange = Range(match.range(at: 4), in: text),
                let classroomRange = Range(match.range(at: 5), in: text),
                let startSection = Int(text[startRange]),
                let endSection = Int(text[endRange]),
                let weekday = weekday(from: String(text[weekdayRange]))
            else { return nil }

            return Occurrence(
                weeks: SmallTermWeekNormalizer.weeksDescribed(in: String(text[weeksRange])),
                weekday: weekday,
                startSection: startSection,
                endSection: endSection,
                classroom: String(text[classroomRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func weekday(from value: String) -> Int? {
        switch value {
        case "一": return 1
        case "二": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "日", "天": return 7
        default: return nil
        }
    }

    private static func normalizedClassroom(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isWhitespace }
    }
}
