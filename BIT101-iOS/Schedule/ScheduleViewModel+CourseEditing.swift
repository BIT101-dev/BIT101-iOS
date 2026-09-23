//
//  ScheduleViewModel+CourseEditing.swift
//  BIT101-iOS
//

import Foundation

extension ScheduleViewModel {
    /// 生成新增课程用的默认草稿。
    ///
    /// 周次默认留空，让用户填写实际的周次范围。
    /// 节次则给一个最常见的双节课起点。
    func courseDraft(for _: Int) -> CourseDraft {
        CourseDraft(
            weekday: 1,
            startSection: 1,
            endSection: min(2, max(cache.timeTable.count, 1)),
            weeksText: ""
        )
    }

    /// 把同一门课的多项时间安排合并为编辑草稿。
    func courseArrangementDrafts(forCourseID id: String) -> [CourseArrangementDraft] {
        guard let anchor = cache.courses.first(where: { $0.id == id }) else {
            return []
        }
        let relatedCourses = cache.courses.filter {
            scheduleCourseIdentity($0) == scheduleCourseIdentity(anchor)
        }
        var groups: [[CourseRecord]] = []
        for course in relatedCourses {
            if let index = groups.firstIndex(where: {
                scheduleCourseArrangementIdentity($0[0]) == scheduleCourseArrangementIdentity(course)
            }) {
                groups[index].append(course)
            } else {
                groups.append([course])
            }
        }

        return groups
            .sorted {
                let lhs = $0[0]
                let rhs = $1[0]
                if lhs.weekday != rhs.weekday { return lhs.weekday < rhs.weekday }
                if lhs.startSection != rhs.startSection { return lhs.startSection < rhs.startSection }
                return lhs.endSection < rhs.endSection
            }
            .map { group in
                let first = group[0]
                let classroom = classroomParts(for: first.classroom)
                let original = CourseDraft(
                    title: first.name,
                    teacher: first.teacher,
                    classroom: first.classroom,
                    buildingName: classroom.buildingName,
                    roomNumber: classroom.roomNumber,
                    weekday: first.weekday,
                    startSection: first.startSection,
                    endSection: first.endSection,
                    weeksText: ScheduleCourseEditor.formatWeeks(group.flatMap(\.weeks)),
                    selectedSections: Array(first.startSection ... first.endSection)
                )
                return CourseArrangementDraft(id: first.id, original: original)
            }
    }

    /// 生成单次课节编辑草稿，原始周次固定展示当前课节。
    func courseArrangementDraft(for record: CourseRecord, week: Int) -> CourseArrangementDraft {
        let classroom = classroomParts(for: record.classroom)
        let original = CourseDraft(
            title: record.name,
            teacher: record.teacher,
            classroom: record.classroom,
            buildingName: classroom.buildingName,
            roomNumber: classroom.roomNumber,
            weekday: record.weekday,
            startSection: record.startSection,
            endSection: record.endSection,
            weeksText: "\(week)",
            selectedSections: Array(record.startSection ... record.endSection)
        )
        return CourseArrangementDraft(id: record.id, original: original)
    }

    /// 新增一条本地课程。
    ///
    /// 本地缓存保存课程修改，用于补录临时课程或手动修正。
    func addCourse(_ draft: CourseDraft) throws {
        let previousCourses = cache.courses
        let updatedCourses = try ScheduleCourseEditor.adding(
            draft,
            to: cache.courses,
            term: cache.currentTerm
        )
        replaceCurrentCourses(updatedCourses, previousCourses: previousCourses)
        persist()
    }

    /// 一次保存一门课的全部时间安排。
    func updateCourseArrangements(_ arrangements: [CourseArrangementDraft]) throws {
        guard !arrangements.isEmpty else { return }
        let previousCourses = cache.courses
        let anchor = previousCourses.first(where: { $0.id == arrangements[0].id })
        var updatedCourses = cache.courses
        for arrangement in arrangements {
            updatedCourses = try ScheduleCourseEditor.updatingArrangement(
                id: arrangement.id,
                with: arrangement.draft,
                in: updatedCourses
            )
        }
        if let anchor {
            try validateCourseConflicts(
                updatedCourses,
                for: anchor,
                previousCourses: previousCourses
            )
        }
        replaceCurrentCourses(updatedCourses, previousCourses: previousCourses)
        persist()
    }

    /// 调整当前周这一节课。
    ///
    /// 从课程周次中拆出当前周，生成独立课程记录，并保留其余周次安排。
    func updateCourseOccurrence(id: String, week: Int, draft: CourseDraft) throws {
        try updateCourseOccurrences(id: id, weeks: [week], draft: draft)
    }

    /// 调整当前选中的多周课节，保留原安排中的其它周次。
    func updateCourseOccurrences(id: String, weeks: [Int], draft: CourseDraft) throws {
        let previousCourses = cache.courses
        let anchor = previousCourses.first(where: { $0.id == id })
        let updatedCourses = try ScheduleCourseEditor.updatingOccurrence(
            id: id,
            weeks: weeks,
            with: draft,
            in: cache.courses
        )
        if let anchor {
            try validateCourseConflicts(
                updatedCourses,
                for: anchor,
                previousCourses: previousCourses
            )
        }
        replaceCurrentCourses(updatedCourses, previousCourses: previousCourses)
        persist()
    }

    /// 删除课程在当前周的显示。
    ///
    /// 课程覆盖范围为空时移除整门课。
    func deleteCourseOccurrence(id: String, week: Int) {
        let previousCourses = cache.courses
        let updatedCourses = ScheduleCourseEditor.deletingOccurrence(
            id: id,
            week: week,
            from: cache.courses
        )
        replaceCurrentCourses(updatedCourses, previousCourses: previousCourses)
        persist()
    }

    /// 删除整门课程。
    func deleteCourse(id: String) {
        let previousCourses = cache.courses
        replaceCurrentCourses(
            ScheduleCourseEditor.deleting(id: id, from: previousCourses),
            previousCourses: previousCourses
        )
        persist()
    }

    /// 将指定日期设置为放假：清空这一天的课程，保留考试和自定义日程。
    func clearCourses(week: Int, weekday: Int) {
        let previousCourses = cache.courses
        let updatedCourses = ScheduleCourseEditor.removingOccurrences(
            from: cache.courses,
            week: week,
            weekday: weekday
        )
        replaceCurrentCourses(updatedCourses, previousCourses: previousCourses)
        persist()
    }

    /// 将某一天的课程调至目标日期。
    ///
    /// 调课语义：
    /// - 清空原日期的课程。
    /// - 覆盖目标日期已有的课程。
    /// - 移动课程，保留考试和自定义日程。
    func transferCourses(fromWeek: Int, fromWeekday: Int, to targetDate: Date) throws {
        let previousCourses = cache.courses
        let target = try courseDayContext(for: targetDate)
        let updatedCourses = ScheduleCourseEditor.transferring(
            courses: cache.courses,
            fromWeek: fromWeek,
            fromWeekday: fromWeekday,
            toWeek: target.week,
            toWeekday: target.weekday
        )
        replaceCurrentCourses(updatedCourses, previousCourses: previousCourses)
        persist()
    }

    private func replaceCurrentCourses(
        _ courses: [CourseRecord],
        previousCourses: [CourseRecord]
    ) {
        cache.courses = courses
        guard !cache.currentTerm.isEmpty else { return }

        let baselineCourses = cache.schoolCoursesByTerm[cache.currentTerm]
            ?? cache.termSchedulesByTerm[cache.currentTerm]?.courses
            ?? previousCourses
        cache.schoolCoursesByTerm[cache.currentTerm] = baselineCourses
        cache.manualCourseRulesByTerm[cache.currentTerm] = ScheduleCourseEditor.updatingRules(
            existing: cache.manualCourseRulesByTerm[cache.currentTerm] ?? [],
            baselineCourses: baselineCourses,
            previousCourses: previousCourses,
            currentCourses: courses
        )
        cache.cachedCoursesByTerm[cache.currentTerm] = courses
        guard let snapshot = cache.termSchedulesByTerm[cache.currentTerm] else { return }
        cache.termSchedulesByTerm[cache.currentTerm] = TermScheduleSnapshot(
            term: snapshot.term,
            firstDayString: snapshot.firstDayString,
            courses: baselineCourses,
            exams: snapshot.exams,
            updatedAt: snapshot.updatedAt
        )
    }

    private func validateCourseConflicts(
        _ courses: [CourseRecord],
        for anchor: CourseRecord,
        previousCourses: [CourseRecord]
    ) throws {
        let originalCourseIDs = Set(
            previousCourses
                .filter { scheduleCourseIdentity($0) == scheduleCourseIdentity(anchor) }
                .map(\.id)
        )
        let candidates = courses.filter { course in
            if !anchor.number.isEmpty {
                return course.number == anchor.number
            }
            return originalCourseIDs.contains(course.id)
                || course.name == anchor.name
        }
        let candidateIDs = Set(candidates.map(\.id))
        let others = courses.filter { !candidateIDs.contains($0.id) }
        if let message = ScheduleCourseEditor.conflictDescription(
            candidates: candidates,
            against: others
        ) {
            throw scheduleValidationError(message)
        }
    }

    private func classroomParts(for classroom: String) -> (buildingName: String, roomNumber: String) {
        let trimmed = classroom.trimmingCharacters(in: .whitespacesAndNewlines)
        let buildings = (buildings + cache.cachedClassroomBuildingsByCampusCode.values.flatMap { $0 })
            .reduce(into: [String]()) { names, building in
                guard !names.contains(building.name) else { return }
                names.append(building.name)
            }
            .sorted { $0.count > $1.count }
        guard let building = buildings.first(where: { trimmed.hasPrefix($0) }) else {
            return ("", trimmed)
        }
        let room = String(trimmed.dropFirst(building.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (building, room)
    }

    /// 导入一份分享的课表载荷。
    ///
    /// 导入后的课表会作为一份“只读分身”追加到当前账号本地缓存中，
    /// 保留我自己的课表、DDL、自定义日程和显示设置。
    func importSharedSchedule(_ payload: ScheduleExportPayload) throws {
        guard !payload.timeTable.isEmpty else {
            throw scheduleValidationError("分享的课表缺少时间表。")
        }

        let titleBase = payload.currentTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String((titleBase.isEmpty ? "分享课表" : "\(titleBase)课表").prefix(scheduleNameCharacterLimit))
        cache.sharedSchedules.append(
            SharedScheduleRecord(
                title: title,
                payload: payload
            )
        )
        persist()
        selectedCourseScheduleIndex = courseSchedules.count - 1
        selectedWeek = resolvedAutomaticWeek(for: ScheduleDateCodec.parseDate(payload.firstDayString))
    }

    /// 把已有自定义日程转成编辑草稿；记录为空时生成一份默认草稿。
    func customScheduleDraft(for record: CustomScheduleRecord?) -> CustomScheduleDraft {
        guard let record else {
            let now = Date()
            let end = Calendar.current.date(byAdding: .minute, value: 60, to: now) ?? now
            return CustomScheduleDraft(date: now, beginTime: now, endTime: end)
        }

        return CustomScheduleDraft(
            title: record.title,
            subtitle: record.subtitle,
            description: record.description,
            date: ScheduleDateCodec.parseDate(record.dateString) ?? Date(),
            beginTime: ScheduleDateCodec.parseTime(record.beginTime) ?? Date(),
            endTime: ScheduleDateCodec.parseTime(record.endTime) ?? Date()
        )
    }

    /// 新增一条自定义日程。
    func addCustomSchedule(_ draft: CustomScheduleDraft) throws {
        try validateCustomScheduleTimeRange(draft)

        cache.customSchedules.append(
            CustomScheduleRecord(
                id: UUID().uuidString,
                title: draft.title,
                subtitle: draft.subtitle,
                description: draft.description,
                dateString: ScheduleDateCodec.formatDate(draft.date),
                beginTime: ScheduleDateCodec.formatTime(draft.beginTime),
                endTime: ScheduleDateCodec.formatTime(draft.endTime)
            )
        )
        persist()
    }

    /// 更新指定自定义日程。
    func updateCustomSchedule(id: String, draft: CustomScheduleDraft) throws {
        try validateCustomScheduleTimeRange(draft)

        guard let index = cache.customSchedules.firstIndex(where: { $0.id == id }) else { return }
        cache.customSchedules[index].title = draft.title
        cache.customSchedules[index].subtitle = draft.subtitle
        cache.customSchedules[index].description = draft.description
        cache.customSchedules[index].dateString = ScheduleDateCodec.formatDate(draft.date)
        cache.customSchedules[index].beginTime = ScheduleDateCodec.formatTime(draft.beginTime)
        cache.customSchedules[index].endTime = ScheduleDateCodec.formatTime(draft.endTime)
        persist()
    }

    /// 删除指定自定义日程。
    func deleteCustomSchedule(id: String) {
        cache.customSchedules.removeAll { $0.id == id }
        persist()
    }

    private func validateCustomScheduleTimeRange(_ draft: CustomScheduleDraft) throws {
        let beginMinutes = ScheduleDateCodec.minutesOfDay(from: draft.beginTime)
        let endMinutes = ScheduleDateCodec.minutesOfDay(from: draft.endTime)
        guard endMinutes > beginMinutes else {
            throw scheduleValidationError("结束时间必须晚于开始时间。")
        }
    }

    /// 计算日期相对当前课表首周的周次和周几。
    private func courseDayContext(for date: Date) throws -> (week: Int, weekday: Int) {
        guard let firstDay = cache.firstDay else {
            throw scheduleValidationError("当前课表缺少首周日期，无法调课。")
        }

        let calendar = ScheduleDateCodec.calendar
        let start = calendar.startOfDay(for: firstDay)
        let target = calendar.startOfDay(for: date)
        let dayOffset = calendar.dateComponents([.day], from: start, to: target).day ?? 0
        let week = ScheduleWeekCodec.weekNumber(forDayOffset: dayOffset)
        let weekOffset = ScheduleWeekCodec.weekOffset(forWeekNumber: week)
        let weekdayOffset = dayOffset - weekOffset * 7
        return (week: week, weekday: weekdayOffset + 1)
    }

}
