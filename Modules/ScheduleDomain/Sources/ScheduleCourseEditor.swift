//
//  ScheduleCourseEditor.swift
//  BIT101-iOS
//

import Foundation

/// 课程编辑草稿校验、周次编解码和课程记录变换。
///
/// 新增、整课编辑和单次调课共享同一套规则，
/// 边界输入可以独立于 `ScheduleViewModel` 测试。
public nonisolated enum ScheduleCourseEditor {
    public struct CourseRuleReconciliation {
        public let courses: [CourseRecord]
        public let validRules: [ScheduleCourseRule]
        public let invalidRules: [ScheduleCourseRule]
    }

    public static func reconcile(
        rules: [ScheduleCourseRule],
        with incomingCourses: [CourseRecord]
    ) -> CourseRuleReconciliation {
        var projectedCourses = incomingCourses
        var validRules: [ScheduleCourseRule] = []
        var invalidRules: [ScheduleCourseRule] = []

        for rule in rules {
            let matchingCourses = incomingCourses.filter {
                scheduleCourseSourceIdentity($0) == rule.sourceIdentity
            }
            let sourceMatches = rule.isLocalAddition
                || scheduleCourseSourceRecordsEqual(matchingCourses, rule.sourceCourses)
            guard sourceMatches else {
                invalidRules.append(rule)
                continue
            }

            validRules.append(rule)
            if !rule.isLocalAddition {
                projectedCourses.removeAll {
                    scheduleCourseSourceIdentity($0) == rule.sourceIdentity
                }
            }
            projectedCourses.append(contentsOf: rule.replacementCourses)
        }

        return CourseRuleReconciliation(
            courses: projectedCourses,
            validRules: validRules,
            invalidRules: invalidRules
        )
    }

    public static func updatingRules(
        existing rules: [ScheduleCourseRule],
        baselineCourses: [CourseRecord],
        previousCourses: [CourseRecord],
        currentCourses: [CourseRecord]
    ) -> [ScheduleCourseRule] {
        var updatedRules = rules
        let previousIDs = Set(previousCourses.map(\.id))
        let previousSourceIdentities = Set(previousCourses.map(scheduleCourseSourceIdentity))

        for sourceIdentity in previousSourceIdentities {
            let previous = previousCourses.filter {
                scheduleCourseSourceIdentity($0) == sourceIdentity
            }
            let previousIDsForSource = Set(previous.map(\.id))
            let sourceNumbers = Set(previous.map(\.number).filter { !$0.isEmpty })
            let current = currentCourses.filter { course in
                previousIDsForSource.contains(course.id)
                    || scheduleCourseSourceIdentity(course) == sourceIdentity
                    || (!sourceNumbers.isEmpty && sourceNumbers.contains(course.number))
            }
            guard !scheduleCourseDisplayRecordsEqual(previous, current) else { continue }

            let changedIDs = Set(previous.map(\.id) + current.map(\.id))
            let existingIndex = updatedRules.lastIndex { rule in
                rule.sourceIdentity == sourceIdentity
                    || !changedIDs.isDisjoint(with: rule.replacementCourses.map(\.id))
            }
            let existingRule = existingIndex.map { updatedRules[$0] }
            let ruleIdentity = existingRule?.sourceIdentity ?? sourceIdentity
            let sourceCourses = existingRule?.sourceCourses
                ?? baselineCourses.filter {
                    scheduleCourseSourceIdentity($0) == sourceIdentity
                }
            let ruleID = existingRule?.id ?? UUID().uuidString

            updatedRules.removeAll { $0.sourceIdentity == ruleIdentity }
            updatedRules.append(
                ScheduleCourseRule(
                    id: ruleID,
                    sourceIdentity: ruleIdentity,
                    sourceCourses: sourceCourses,
                    replacementCourses: current
                )
            )
        }

        for course in currentCourses where !previousIDs.contains(course.id) {
            let sourceIdentity = scheduleCourseSourceIdentity(course)
            let relatedToPreviousCourse = previousSourceIdentities.contains(sourceIdentity)
                || (!course.number.isEmpty && previousCourses.contains { $0.number == course.number })
            guard !relatedToPreviousCourse else { continue }
            let existingRule = updatedRules.last {
                $0.replacementCourses.contains { $0.id == course.id }
            }
            guard existingRule == nil else { continue }

            updatedRules.append(
                ScheduleCourseRule(
                    sourceIdentity: "local:\(course.id)",
                    sourceCourses: [],
                    replacementCourses: [course]
                )
            )
        }

        return updatedRules
    }

    /// 把编辑结果应用到显示缓存，同时保留学校课程快照供成绩和后续同步使用。
    public static func updateCacheForManualCourseChange(
        in cache: inout ScheduleCache,
        previousCourses: [CourseRecord],
        currentCourses: [CourseRecord]
    ) {
        cache.courses = currentCourses
        guard !cache.currentTerm.isEmpty else { return }

        let term = cache.currentTerm
        let baselineCourses = cache.schoolCoursesByTerm[term]
            ?? cache.termSchedulesByTerm[term]?.courses
            ?? previousCourses
        cache.schoolCoursesByTerm[term] = baselineCourses
        cache.cachedCoursesByTerm[term] = baselineCourses
        cache.manualCourseRulesByTerm[term] = updatingRules(
            existing: cache.manualCourseRulesByTerm[term] ?? [],
            baselineCourses: baselineCourses,
            previousCourses: previousCourses,
            currentCourses: currentCourses
        )
        guard let snapshot = cache.termSchedulesByTerm[term] else { return }
        cache.termSchedulesByTerm[term] = TermScheduleSnapshot(
            term: snapshot.term,
            firstDayString: snapshot.firstDayString,
            courses: baselineCourses,
            exams: snapshot.exams,
            updatedAt: snapshot.updatedAt
        )
    }

    public struct ResolvedDraft: Equatable {
        public let title: String
        public let teacher: String
        public let classroom: String
        public let weeks: [Int]
        public let weekday: Int
        public let startSection: Int
        public let endSection: Int
    }

    public static func parseWeeks(_ text: String) throws -> [Int] {
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


    public static func resolve(_ draft: CourseDraft, fixedWeeks: [Int]? = nil) throws -> ResolvedDraft {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw validationError("课程名称不能为空。") }
        guard (1 ... 7).contains(draft.weekday) else { throw validationError("星期设置不合法。") }

        let sectionIDs: [Int]
        if draft.selectedSections.isEmpty {
            guard draft.startSection > 0, draft.endSection >= draft.startSection else {
                throw validationError("至少选择一节课。")
            }
            sectionIDs = Array(draft.startSection ... draft.endSection)
        } else {
            sectionIDs = Array(Set(draft.selectedSections)).sorted()
        }
        guard !sectionIDs.isEmpty, sectionIDs.allSatisfy({ $0 > 0 }) else {
            throw validationError("至少选择一节课。")
        }
        guard let firstSection = sectionIDs.first,
              let lastSection = sectionIDs.last,
              sectionIDs == Array(firstSection ... lastSection) else {
            throw validationError("节次必须连续。")
        }

        let weeks: [Int]
        if let fixedWeeks {
            guard !fixedWeeks.isEmpty, fixedWeeks.allSatisfy({ $0 != 0 }) else {
                throw invalidWeeksError
            }
            weeks = Array(Set(fixedWeeks)).sorted()
        } else {
            weeks = try parseWeeks(draft.weeksText)
        }

        return ResolvedDraft(
            title: title,
            teacher: draft.teacher.trimmingCharacters(in: .whitespacesAndNewlines),
            classroom: resolvedClassroom(from: draft),
            weeks: weeks,
            weekday: draft.weekday,
            startSection: firstSection,
            endSection: lastSection
        )
    }

    public static func conflictDescription(
        candidates: [CourseRecord],
        against otherCourses: [CourseRecord]
    ) -> String? {
        if let conflict = firstConflict(in: candidates, against: candidates) {
            return conflictMessage(for: conflict)
        }
        if let conflict = firstConflict(in: candidates, against: otherCourses) {
            return conflictMessage(for: conflict)
        }
        return nil
    }

    public static func adding(
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

    public static func updatingArrangement(
        id: String,
        with draft: CourseDraft,
        in courses: [CourseRecord]
    ) throws -> [CourseRecord] {
        guard let anchor = courses.first(where: { $0.id == id }) else { return courses }
        let resolved = try resolve(draft)
        let identity = scheduleCourseArrangementIdentity(anchor)
        var updated = courses.filter { scheduleCourseArrangementIdentity($0) != identity }
        updated.append(applying(resolved, to: anchor))
        return updated
    }

    public static func updatingOccurrence(
        id: String,
        week: Int,
        with draft: CourseDraft,
        in courses: [CourseRecord],
        adjustedID: String = UUID().uuidString
    ) throws -> [CourseRecord] {
        try updatingOccurrence(
            id: id,
            weeks: [week],
            with: draft,
            in: courses,
            adjustedID: adjustedID
        )
    }

    public static func updatingOccurrence(
        id: String,
        weeks: [Int],
        with draft: CourseDraft,
        in courses: [CourseRecord],
        adjustedID: String = UUID().uuidString
    ) throws -> [CourseRecord] {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return courses }
        var courses = courses
        let original = courses[index]
        let selectedWeeks = Array(Set(weeks)).sorted()
        guard !selectedWeeks.isEmpty,
              selectedWeeks.allSatisfy({ original.weeks.contains($0) }) else {
            return courses
        }
        let resolved = try resolve(draft, fixedWeeks: selectedWeeks)
        let remainingWeeks = original.weeks.filter { !selectedWeeks.contains($0) }
        let adjustedCourse = applying(resolved, to: original, id: remainingWeeks.isEmpty ? original.id : adjustedID)

        if remainingWeeks.isEmpty {
            courses[index] = adjustedCourse
        } else {
            courses[index] = copying(original, weeks: remainingWeeks)
            courses.append(adjustedCourse)
        }
        return courses
    }

    public static func deletingOccurrence(
        id: String,
        week: Int,
        from courses: [CourseRecord]
    ) -> [CourseRecord] {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return courses }
        var courses = courses
        let original = courses[index]
        guard original.weeks.contains(week) else { return courses }
        let remainingWeeks = original.weeks.filter { $0 != week }
        if remainingWeeks.isEmpty {
            courses.remove(at: index)
        } else {
            courses[index] = copying(original, weeks: remainingWeeks)
        }
        return courses
    }

    public static func deleting(id: String, from courses: [CourseRecord]) -> [CourseRecord] {
        guard let anchor = courses.first(where: { $0.id == id }) else { return courses }
        let identity = scheduleCourseIdentity(anchor)
        return courses.filter { scheduleCourseIdentity($0) != identity }
    }

    public static func removingOccurrences(
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

    public static func transferring(
        courses: [CourseRecord],
        fromWeek: Int,
        fromWeekday: Int,
        toWeek: Int,
        toWeekday: Int,
        makeID: () -> String = { UUID().uuidString }
    ) -> [CourseRecord] {
        guard fromWeek != toWeek || fromWeekday != toWeekday else { return courses }
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

    private static func resolvedClassroom(from draft: CourseDraft) -> String {
        let building = draft.buildingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let room = draft.roomNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !building.isEmpty else {
            return room.isEmpty
                ? draft.classroom.trimmingCharacters(in: .whitespacesAndNewlines)
                : room
        }
        return [building, room].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func firstConflict(
        in candidates: [CourseRecord],
        against otherCourses: [CourseRecord]
    ) -> (CourseRecord, CourseRecord)? {
        for candidate in candidates {
            for other in otherCourses where candidate.id != other.id {
                guard candidate.weekday == other.weekday else { continue }
                guard !Set(candidate.weeks).isDisjoint(with: other.weeks) else { continue }
                guard candidate.startSection <= other.endSection,
                      other.startSection <= candidate.endSection else { continue }
                return (candidate, other)
            }
        }
        return nil
    }

    private static func conflictMessage(for conflict: (CourseRecord, CourseRecord)) -> String {
        let (candidate, other) = conflict
        let weeks = ScheduleWeekCodec.formatWeeks(Array(Set(candidate.weeks).intersection(other.weeks)))
        return "\(candidate.name)与\(other.name)在第\(weeks)周周\(weekdayText(candidate.weekday))第\(max(candidate.startSection, other.startSection))-\(min(candidate.endSection, other.endSection))节发生冲突。"
    }

    private static func weekdayText(_ weekday: Int) -> String {
        let titles = ["", "一", "二", "三", "四", "五", "六", "日"]
        return titles.indices.contains(weekday) ? titles[weekday] : "?"
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
