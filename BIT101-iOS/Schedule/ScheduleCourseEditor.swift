//
//  ScheduleCourseEditor.swift
//  BIT101-iOS
//

import Foundation

/// 课程编辑草稿校验、周次编解码和课程记录变换。
///
/// 新增、整课编辑和单次调课共享同一套规则，
/// 边界输入可以独立于 `ScheduleViewModel` 测试。
enum ScheduleCourseEditor {
    struct ResolvedDraft: Equatable {
        let title: String
        let teacher: String
        let classroom: String
        let weeks: [Int]
        let weekday: Int
        let startSection: Int
        let endSection: Int
    }

    static func parseWeeks(_ text: String) throws -> [Int] {
        let segments = text
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !segments.isEmpty else {
            throw validationError("周次不能为空。")
        }

        var weeks = Set<Int>()
        for segment in segments {
            let value = String(segment)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let firstRangeSeparatorIndex: String.Index? = {
                let searchStart = value.first == "-"
                    ? value.index(after: value.startIndex)
                    : value.startIndex
                return value[searchStart...].firstIndex {
                    "-－—~～至".contains($0)
                }
            }()

            if let separatorIndex = firstRangeSeparatorIndex {
                let lowerText = value[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                let upperText = value[value.index(after: separatorIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    let lower = Int(lowerText),
                    let upper = Int(upperText),
                    lower != 0,
                    upper != 0,
                    upper >= lower
                else {
                    throw invalidWeeksError
                }
                weeks.formUnion((lower ... upper).filter { $0 != 0 })
                continue
            }

            guard let week = Int(value), week != 0 else {
                throw invalidWeeksError
            }
            weeks.insert(week)
        }
        return weeks.sorted()
    }

    static func formatWeeks(_ weeks: [Int]) -> String {
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

    static func resolve(_ draft: CourseDraft, fixedWeeks: [Int]? = nil) throws -> ResolvedDraft {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw validationError("课程名称不能为空。") }
        guard (1 ... 7).contains(draft.weekday) else { throw validationError("星期设置不合法。") }
        guard draft.startSection > 0, draft.endSection >= draft.startSection else {
            throw validationError("节次范围不合法。")
        }

        return ResolvedDraft(
            title: title,
            teacher: draft.teacher.trimmingCharacters(in: .whitespacesAndNewlines),
            classroom: draft.classroom.trimmingCharacters(in: .whitespacesAndNewlines),
            weeks: try fixedWeeks ?? parseWeeks(draft.weeksText),
            weekday: draft.weekday,
            startSection: draft.startSection,
            endSection: draft.endSection
        )
    }

    static func adding(
        _ draft: CourseDraft,
        to courses: [CourseRecord],
        term: String,
        id: String = UUID().uuidString
    ) throws -> [CourseRecord] {
        let resolved = try resolve(draft)
        return courses + [CourseRecord(
            id: id,
            term: term,
            name: resolved.title,
            teacher: resolved.teacher,
            classroom: resolved.classroom,
            description: "",
            weeks: resolved.weeks,
            weekday: resolved.weekday,
            startSection: resolved.startSection,
            endSection: resolved.endSection,
            campus: "",
            number: "",
            credit: 0,
            hour: 0,
            type: "",
            category: "",
            department: ""
        )]
    }

    static func updating(
        id: String,
        with draft: CourseDraft,
        in courses: [CourseRecord]
    ) throws -> [CourseRecord] {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return courses }
        let resolved = try resolve(draft)
        var courses = courses
        courses[index] = applying(resolved, to: courses[index])
        return courses
    }

    static func updatingOccurrence(
        id: String,
        week: Int,
        with draft: CourseDraft,
        in courses: [CourseRecord],
        adjustedID: String = UUID().uuidString
    ) throws -> [CourseRecord] {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return courses }
        var courses = courses
        let original = courses[index]
        let resolved = try resolve(draft, fixedWeeks: [week])
        let adjustedCourse = applying(
            resolved,
            to: original,
            id: original.weeks == [week] ? original.id : adjustedID
        )

        if original.weeks == [week] {
            courses[index] = adjustedCourse
        } else {
            courses[index] = copying(original, weeks: original.weeks.filter { $0 != week })
            courses.append(adjustedCourse)
        }
        return courses
    }

    static func deletingOccurrence(
        id: String,
        week: Int,
        from courses: [CourseRecord]
    ) -> [CourseRecord] {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return courses }
        var courses = courses
        let original = courses[index]
        let remainingWeeks = original.weeks.filter { $0 != week }
        if remainingWeeks.isEmpty {
            courses.remove(at: index)
        } else {
            courses[index] = copying(original, weeks: remainingWeeks)
        }
        return courses
    }

    static func deleting(id: String, from courses: [CourseRecord]) -> [CourseRecord] {
        courses.filter { $0.id != id }
    }

    static func removingOccurrences(
        from courses: [CourseRecord],
        week: Int,
        weekday: Int
    ) -> [CourseRecord] {
        courses.compactMap { course in
            guard course.weekday == weekday, course.weeks.contains(week) else { return course }
            let remainingWeeks = course.weeks.filter { $0 != week }
            return remainingWeeks.isEmpty ? nil : copying(course, weeks: remainingWeeks)
        }
    }

    static func transferring(
        courses: [CourseRecord],
        fromWeek: Int,
        fromWeekday: Int,
        toWeek: Int,
        toWeekday: Int,
        makeID: () -> String = { UUID().uuidString }
    ) -> [CourseRecord] {
        let sourceCourses = courses.filter {
            $0.weekday == fromWeekday && $0.weeks.contains(fromWeek)
        }
        var result = removingOccurrences(from: courses, week: fromWeek, weekday: fromWeekday)
        result = removingOccurrences(from: result, week: toWeek, weekday: toWeekday)
        result.append(contentsOf: sourceCourses.map {
            copying($0, id: makeID(), weeks: [toWeek], weekday: toWeekday)
        })
        return result
    }

    private static func applying(
        _ resolved: ResolvedDraft,
        to course: CourseRecord,
        id: String? = nil
    ) -> CourseRecord {
        copying(
            course,
            id: id,
            name: resolved.title,
            teacher: resolved.teacher,
            classroom: resolved.classroom,
            weeks: resolved.weeks,
            weekday: resolved.weekday,
            startSection: resolved.startSection,
            endSection: resolved.endSection
        )
    }

    private static func copying(
        _ course: CourseRecord,
        id: String? = nil,
        name: String? = nil,
        teacher: String? = nil,
        classroom: String? = nil,
        weeks: [Int]? = nil,
        weekday: Int? = nil,
        startSection: Int? = nil,
        endSection: Int? = nil
    ) -> CourseRecord {
        CourseRecord(
            id: id ?? course.id,
            term: course.term,
            name: name ?? course.name,
            teacher: teacher ?? course.teacher,
            classroom: classroom ?? course.classroom,
            description: course.description,
            weeks: weeks ?? course.weeks,
            weekday: weekday ?? course.weekday,
            startSection: startSection ?? course.startSection,
            endSection: endSection ?? course.endSection,
            campus: course.campus,
            number: course.number,
            credit: course.credit,
            hour: course.hour,
            type: course.type,
            category: course.category,
            department: course.department
        )
    }

    private static var invalidWeeksError: NSError {
        validationError("周次格式不正确，请使用如 1-16,18 的写法。")
    }

    private static func validationError(_ message: String) -> NSError {
        NSError(domain: "BIT101.Schedule", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
