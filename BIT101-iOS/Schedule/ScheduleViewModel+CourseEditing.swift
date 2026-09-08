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

    /// 把已有课程转成编辑草稿。
    ///
    /// - Parameter editsOccurrenceOnly: 为 `true` 时，草稿周次固定成当前这一周，
    ///   用于“调这节课”把一门重复课拆成一次性调整后的单次课程。
    func courseDraft(for record: CourseRecord, week: Int, editsOccurrenceOnly: Bool) -> CourseDraft {
        CourseDraft(
            title: record.name,
            teacher: record.teacher,
            classroom: record.classroom,
            weekday: record.weekday,
            startSection: record.startSection,
            endSection: record.endSection,
            weeksText: editsOccurrenceOnly ? "\(week)" : ScheduleCourseEditor.formatWeeks(record.weeks)
        )
    }

    /// 新增一条本地课程。
    ///
    /// 本地缓存保存课程修改，用于补录临时课程或手动修正。
    func addCourse(_ draft: CourseDraft) throws {
        cache.courses = try ScheduleCourseEditor.adding(
            draft,
            to: cache.courses,
            term: cache.currentTerm
        )
        persist()
    }

    /// 更新整门课程。
    func updateCourse(id: String, draft: CourseDraft) throws {
        cache.courses = try ScheduleCourseEditor.updating(
            id: id,
            with: draft,
            in: cache.courses
        )
        persist()
    }

    /// 调整当前周这一节课。
    ///
    /// 从原课程中移出当前周，生成一条仅覆盖当前周的新课程记录；
    /// 其它周保留原来的排课信息。
    func updateCourseOccurrence(id: String, week: Int, draft: CourseDraft) throws {
        cache.courses = try ScheduleCourseEditor.updatingOccurrence(
            id: id,
            week: week,
            with: draft,
            in: cache.courses
        )
        persist()
    }

    /// 删除课程在当前周的显示。
    ///
    /// 课程覆盖范围为空时移除整门课。
    func deleteCourseOccurrence(id: String, week: Int) {
        cache.courses = ScheduleCourseEditor.deletingOccurrence(
            id: id,
            week: week,
            from: cache.courses
        )
        persist()
    }

    /// 删除整门课程。
    func deleteCourse(id: String) {
        cache.courses = ScheduleCourseEditor.deleting(id: id, from: cache.courses)
        persist()
    }

    /// 将指定日期设置为放假：清空这一天的课程，保留考试和自定义日程。
    func clearCourses(week: Int, weekday: Int) {
        cache.courses = ScheduleCourseEditor.removingOccurrences(
            from: cache.courses,
            week: week,
            weekday: weekday
        )
        persist()
    }

    /// 将某一天的课程调至目标日期。
    ///
    /// 调课语义：
    /// - 清空原日期的课程。
    /// - 覆盖目标日期已有的课程。
    /// - 移动课程，保留考试和自定义日程。
    func transferCourses(fromWeek: Int, fromWeekday: Int, to targetDate: Date) throws {
        let target = try courseDayContext(for: targetDate)
        cache.courses = ScheduleCourseEditor.transferring(
            courses: cache.courses,
            fromWeek: fromWeek,
            fromWeekday: fromWeekday,
            toWeek: target.week,
            toWeekday: target.weekday
        )
        persist()
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
        selectedWeek = resolvedAutomaticWeek()
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

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: firstDay)
        let target = calendar.startOfDay(for: date)
        let dayOffset = calendar.dateComponents([.day], from: start, to: target).day ?? 0
        let week = ScheduleWeekCodec.weekNumber(forDayOffset: dayOffset)
        let weekOffset = ScheduleWeekCodec.weekOffset(forWeekNumber: week)
        let weekdayOffset = dayOffset - weekOffset * 7
        return (week: week, weekday: weekdayOffset + 1)
    }

}
