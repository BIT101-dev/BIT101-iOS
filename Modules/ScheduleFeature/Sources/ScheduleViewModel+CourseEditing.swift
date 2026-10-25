import ScheduleDomain
import ScheduleContracts
//
//  ScheduleViewModel+CourseEditing.swift
//  BIT101-iOS
//

import Foundation

extension ScheduleViewModel {
    /// 生成新增课程用的默认草稿。
    ///
    /// 周次沿用主课表正在显示的周次。
    /// 节次则给一个最常见的双节课起点。
    func courseDraft(for week: Int) -> CourseDraft {
        CourseDraft(
            weekday: 1,
            startSection: 1,
            endSection: min(2, max(courseState.timeTable.count, 1)),
            weeksText: String(week)
        )
    }

    /// 把同一门课的多项时间安排合并为编辑草稿。
    func courseArrangementDrafts(forCourseID id: String) -> [CourseArrangementDraft] {
        guard let anchor = courseState.courses.first(where: { $0.id == id }) else {
            return []
        }
        let relatedCourses = courseState.courses.filter {
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
                    weeksText: ScheduleWeekCodec.formatWeeks(group.flatMap(\.weeks)),
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
        return CourseArrangementDraft(id: record.id, original: original, availableWeeks: record.weeks)
    }

    /// 新增一条本地课程。
    ///
    /// 本地缓存保存课程修改，用于补录临时课程或手动修正。
    func addCourse(_ draft: CourseDraft) throws {
        try repository.requireWritable()
        let previousCourses = courseState.courses
        let updatedCourses = try ScheduleCourseEditor.adding(
            draft,
            to: courseState.courses,
            term: courseState.currentTerm
        )
        replaceCurrentCourses(updatedCourses, previousCourses: previousCourses)
        persist()
    }

    /// 一次保存一门课的全部时间安排。
    func updateCourseArrangements(_ arrangements: [CourseArrangementDraft]) throws {
        try repository.requireWritable()
        guard !arrangements.isEmpty else { return }
        let previousCourses = courseState.courses
        let anchor = previousCourses.first(where: { $0.id == arrangements[0].id })
        let updatedCourses = try ScheduleCourseEditor.updatingArrangements(
            arrangements.map { (id: $0.id, draft: $0.draft) }, in: previousCourses)
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

    /// 调整当前选中的多周课节，保留原安排中的其它周次。
    func updateCourseOccurrences(id: String, weeks: [Int], draft: CourseDraft) throws {
        try repository.requireWritable()
        let previousCourses = courseState.courses
        let anchor = previousCourses.first(where: { $0.id == id })
        let updatedCourses = try ScheduleCourseEditor.updatingOccurrence(
            id: id,
            weeks: weeks,
            with: draft,
            in: courseState.courses
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
    func deleteCourseOccurrence(id: String, week: Int) throws {
        try repository.requireWritable()
        let previousCourses = courseState.courses
        let updatedCourses = ScheduleCourseEditor.deletingOccurrence(
            id: id,
            week: week,
            from: courseState.courses
        )
        replaceCurrentCourses(updatedCourses, previousCourses: previousCourses)
        persist()
    }

    /// 删除整门课程。
    func deleteCourse(id: String) throws {
        try repository.requireWritable()
        let previousCourses = courseState.courses
        replaceCurrentCourses(
            ScheduleCourseEditor.deleting(id: id, from: previousCourses),
            previousCourses: previousCourses
        )
        persist()
    }

    /// 将指定日期设置为放假：清空这一天的课程，保留考试和自定义日程。
    func clearCourses(week: Int, weekday: Int) throws {
        try repository.requireWritable()
        let previousCourses = courseState.courses
        let updatedCourses = ScheduleCourseEditor.removingOccurrences(
            from: courseState.courses,
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
        try repository.requireWritable()
        let previousCourses = courseState.courses
        let target = try courseDayContext(for: targetDate)
        let updatedCourses = try ScheduleCourseEditor.transferring(
            courses: courseState.courses,
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
        repository.updateCourses(
            previousCourses: previousCourses,
            currentCourses: courses
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

    var courseArrangementBuildings: [BuildingRecord] {
        var names: Set<String> = []
        return courseState.cachedClassroomBuildingsByCampusCode.keys.sorted()
            .flatMap { courseState.cachedClassroomBuildingsByCampusCode[$0] ?? [] }
            .filter { !$0.name.isEmpty && names.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func classroomParts(for classroom: String) -> (buildingName: String, roomNumber: String) {
        let trimmed = classroom.trimmingCharacters(in: .whitespacesAndNewlines)
        let buildings = courseArrangementBuildings.map(\.name)
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
        try repository.requireWritable()
        try payload.validate()

        let titleBase = payload.currentTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String((titleBase.isEmpty ? "分享课表" : "\(titleBase)课表").prefix(scheduleNameCharacterLimit))
        courseState.sharedSchedules.append(
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
            var draft = newCustomScheduleDraft()
            if let firstDay = courseState.firstDay,
               let date = ScheduleDateCodec.calendar.date(byAdding: .day,
                   value: ScheduleWeekCodec.weekOffset(forWeekNumber: selectedWeek) * 7
                       + ScheduleDateCodec.weekdayIndex(from: draft.date) - 1, to: firstDay) {
                draft.date = date
                draft.selectedWeeks = [selectedWeek]
            }
            return draft
        }

        return CustomScheduleDraft(
            title: record.title,
            subtitle: record.subtitle,
            description: record.description,
            date: ScheduleDateCodec.parseDate(record.dateString) ?? Date(),
            beginTime: ScheduleDateCodec.parseTime(record.beginTime) ?? Date(),
            endTime: ScheduleDateCodec.parseTime(record.endTime) ?? Date(),
            selectedWeeks: record.occurrenceDateStrings.compactMap { text in
                guard let date = ScheduleDateCodec.parseDate(text), let context = try? courseDayContext(for: date),
                      ScheduleCourseConstraints.validWeeks.contains(context.week) else { return nil }
                return context.week
            }
        )
    }

    /// 新增一条自定义日程。
    func addCustomSchedule(_ draft: CustomScheduleDraft) throws {
        try repository.requireWritable()
        let title = try validatedCustomScheduleTitle(draft)
        let dates = try customScheduleDates(for: draft)

        courseState.customSchedules.append(
            CustomScheduleRecord(
                id: UUID().uuidString,
                title: title,
                subtitle: draft.subtitle,
                description: draft.description,
                dateString: dates[0],
                beginTime: ScheduleDateCodec.formatTime(draft.beginTime),
                endTime: ScheduleDateCodec.formatTime(draft.endTime),
                additionalDateStrings: dates.count > 1 ? Array(dates.dropFirst()) : nil
            )
        )
        persist()
    }

    /// 更新指定自定义日程。
    func updateCustomSchedule(id: String, draft: CustomScheduleDraft) throws {
        try repository.requireWritable()
        let title = try validatedCustomScheduleTitle(draft)
        let dates = try customScheduleDates(for: draft)

        guard let index = courseState.customSchedules.firstIndex(where: { $0.id == id }) else { return }
        courseState.customSchedules[index].title = title
        courseState.customSchedules[index].subtitle = draft.subtitle
        courseState.customSchedules[index].description = draft.description
        courseState.customSchedules[index].dateString = dates[0]
        courseState.customSchedules[index].additionalDateStrings = dates.count > 1 ? Array(dates.dropFirst()) : nil
        courseState.customSchedules[index].beginTime = ScheduleDateCodec.formatTime(draft.beginTime)
        courseState.customSchedules[index].endTime = ScheduleDateCodec.formatTime(draft.endTime)
        persist()
    }

    /// 删除指定自定义日程。
    func deleteCustomSchedule(id: String) throws {
        try repository.requireWritable()
        courseState.customSchedules.removeAll { $0.id == id }
        persist()
    }

    private func validatedCustomScheduleTitle(_ draft: CustomScheduleDraft) throws -> String {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw scheduleValidationError("请填写日程标题。") }
        for (label, value) in [("日程标题", title), ("地点", draft.subtitle), ("描述", draft.description)] {
            guard value.utf8.count <= ScheduleCourseConstraints.maximumFieldBytes else {
                throw scheduleValidationError("\(label)长度上限为 \(ScheduleCourseConstraints.maximumFieldBytes) UTF-8 字节。")
            }
        }
        let beginMinutes = ScheduleDateCodec.minutesOfDay(from: draft.beginTime)
        let endMinutes = ScheduleDateCodec.minutesOfDay(from: draft.endTime)
        guard endMinutes > beginMinutes else {
            throw scheduleValidationError("结束时间必须晚于开始时间。")
        }
        return title
    }

    private func customScheduleDates(for draft: CustomScheduleDraft) throws -> [String] {
        guard let firstDay = courseState.firstDay else { return [ScheduleDateCodec.formatDate(draft.date)] }
        let context = try courseDayContext(for: draft.date)
        guard ScheduleCourseConstraints.validWeeks.contains(context.week) else {
            return [ScheduleDateCodec.formatDate(draft.date)]
        }
        guard !draft.selectedWeeks.isEmpty,
              draft.selectedWeeks.allSatisfy(ScheduleCourseConstraints.validWeeks.contains) else {
            throw scheduleValidationError("请选择日程周次。")
        }
        return try Array(Set(draft.selectedWeeks)).sorted().map { week in
            guard let date = ScheduleDateCodec.calendar.date(byAdding: .day,
                value: ScheduleWeekCodec.weekOffset(forWeekNumber: week) * 7 + context.weekday - 1, to: firstDay)
            else { throw scheduleValidationError("日程日期需要调整。") }
            return ScheduleDateCodec.formatDate(date)
        }
    }

    /// 计算日期相对当前课表首周的周次和周几。
    private func courseDayContext(for date: Date) throws -> (week: Int, weekday: Int) {
        guard let firstDay = courseState.firstDay else {
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
