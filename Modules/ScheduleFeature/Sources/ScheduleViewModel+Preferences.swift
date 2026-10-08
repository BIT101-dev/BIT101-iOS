import SchedulePorts
import ScheduleDomain
import StorageCore
//
//  ScheduleViewModel+Preferences.swift
//  BIT101-iOS
//

import Foundation

extension ScheduleViewModel {
    public var settingsSnapshot: ScheduleSettingsSnapshot { ScheduleSettingsSnapshot(courses: courseState, preferences: presentationPreferences, sync: syncState) }

    public func exportScheduleCode() throws -> String {
        try ScheduleShareCodeCodec.encodeLatest(cache: persistenceSnapshot)
    }

    public func importScheduleCode(_ text: String) throws {
        try importSharedSchedule(ScheduleShareCodeCodec.decode(text, using: persistenceSnapshot))
    }

    public func importCurrentTermToSystemCalendar() async throws -> Int {
        try await platformActions.importSystemCalendar(courses: courseSnapshot, term: persistenceSnapshot.currentTerm)
    }

    func importSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> Int {
        try await platformActions.importSystemCalendarEntries(content, term: term)
    }

    func deleteSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> ScheduleSystemCalendarMutationResult {
        try await platformActions.deleteSystemCalendarEntries(content, term: term)
    }

    func deleteSystemCalendarEntries(markerIDs: Set<String>, term: String) async throws -> ScheduleSystemCalendarMutationResult {
        try await platformActions.deleteSystemCalendarEntries(markerIDs: markerIDs, term: term)
    }

    public func deleteImportedSystemCalendarEvents() async throws -> ScheduleSystemCalendarMutationResult {
        try await platformActions.deleteImportedSystemCalendarEvents()
    }

    /// 把周次快速重置到当前周。
    func resetToCurrentWeek() {
        selectedWeek = resolvedAutomaticWeek()
    }

    /// 按当前账号和学期保存首周周一；传入 nil 时恢复最近同步的学校日期。
    public func setSemesterStartDate(_ date: Date?) {
        let term = courseState.currentTerm
        guard isCacheWritable, !term.isEmpty else { return }
        if let date {
            let firstDayString = ScheduleDateCodec.formatDate(ScheduleDateCodec.monday(containing: date))
            courseState.manualFirstDayStringsByTerm[term] = firstDayString
        } else {
            guard courseState.termSchedulesByTerm[term] != nil else { return }
            courseState.manualFirstDayStringsByTerm.removeValue(forKey: term)
        }
        selectedWeek = resolvedAutomaticWeek()
        persist(source: .localWithoutCloudPush)
    }

    private func validatedScheduleTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw scheduleValidationError("课表名称不能为空。")
        }
        guard trimmed.count <= scheduleNameCharacterLimit else {
            throw scheduleValidationError("课表名称最多 8 个字符。")
        }
        return trimmed
    }

    /// 在“我的课表”和导入课表之间循环切换。
    ///
    /// 采用 loop 语义：向上或向下滑动到边界后回卷。
    func cycleCourseSchedule(step: Int) {
        let variants = courseSchedules
        guard variants.count > 1 else { return }

        let count = variants.count
        let nextIndex = (selectedCourseScheduleIndex + step).modulo(count)
        selectedCourseScheduleIndex = nextIndex
        let targetSchedule = variants[nextIndex]
        let targetHasSelectedWeek = targetSchedule.courses.contains { $0.weeks.contains(selectedWeek) }
        if !targetHasSelectedWeek {
            selectedWeek = resolvedAutomaticWeek(for: targetSchedule.firstDay)
        }
    }

    /// 重命名当前账号自己的课表。
    public func renamePrimarySchedule(to title: String) throws {
        try repository.requireWritable()
        let trimmed = try validatedScheduleTitle(title)
        courseState.primaryScheduleTitle = trimmed
        persist()
    }

    /// 重命名一份导入的分享课表。
    public func renameSharedSchedule(id: String, to title: String) throws {
        try repository.requireWritable()
        let trimmed = try validatedScheduleTitle(title)
        guard let index = courseState.sharedSchedules.firstIndex(where: { $0.id == id }) else { return }
        courseState.sharedSchedules[index].title = trimmed
        persist()
    }

    /// 删除一份导入的分享课表。
    public func deleteSharedSchedule(id: String) {
        courseState.sharedSchedules.removeAll { $0.id == id }
        selectedCourseScheduleIndex = min(selectedCourseScheduleIndex, max(courseSchedules.count - 1, 0))
        persist()
    }

    /// 设置周六课程显示。
    public func setShowSaturday(_ value: Bool) {
        presentationPreferences.showSaturday = value
        persist()
    }

    /// 设置周日课程显示。
    public func setShowSunday(_ value: Bool) {
        presentationPreferences.showSunday = value
        persist()
    }

    /// 设置课表网格中的考试块显示。
    public func setShowExamInfo(_ value: Bool) {
        presentationPreferences.showExamInfo = value
        persist()
    }

    /// 设置课程在周视图中的排布方式。
    public func setScheduleDisplayMode(_ mode: ScheduleDisplayMode) {
        guard presentationPreferences.scheduleDisplayMode != mode else { return }
        presentationPreferences.scheduleDisplayMode = mode
        persist()
    }

    /// 设置课程卡片显示内容。
    public func setScheduleCardContentMode(_ mode: ScheduleCardContentMode) {
        guard presentationPreferences.scheduleCardContentMode != mode else { return }
        presentationPreferences.scheduleCardContentMode = mode
        persist()
    }

    public func setICloudSyncEnabled(_ value: Bool) {
        guard syncState.iCloudSyncEnabled != value else { return }
        cloudSyncEnableTask?.cancel()
        syncState.iCloudSyncEnabled = value

        if value {
            let session = repository.accountSession
            let generation = repository.accountGeneration
            cloudSyncEnableTask = Task { [repository, platformActions] in
                guard await repository.persistAndWait(source: .localWithoutCloudPush),
                      repository.accountGeneration == generation,
                      repository.accountSession == session,
                      repository.syncState.iCloudSyncEnabled, !Task.isCancelled else { return }
                await platformActions.enableCloudSync(session: session)
            }
        } else {
            persist(source: .localWithoutCloudPush)
        }
    }

    /// 设置课程提醒 Live Activity 启用状态。
    public func setShowCourseLiveActivityReminder(_ value: Bool) {
        presentationPreferences.showCourseLiveActivityReminder = value
        persist()

        if value {
            let session = repository.accountSession
            Task { [platformActions] in
                await platformActions.enableCourseReminder(session: session)
            }
        }
    }

    /// 设置灵动岛/锁屏提醒的提前显示阈值。
    public func setCourseLiveActivityLeadMinutes(_ value: Int) {
        presentationPreferences.courseLiveActivityLeadMinutes = value
        persist()
    }

    /// 从多行文本解析并替换整份时间表。
    ///
    /// 每行格式固定为 `开始时间,结束时间`；这里会同时校验顺序和重叠。
    public func setTimeTable(from text: String) throws {
        try repository.requireWritable()
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var timeTable: [TimeSlot] = []
        for (index, line) in lines.enumerated() {
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                throw scheduleValidationError("时间表格式错误。")
            }

            let start = parts[0]
            let end = parts[1]
            guard let startMinutes = validTimeTableMinutes(start),
                  let endMinutes = validTimeTableMinutes(end)
            else {
                throw scheduleValidationError("时间表格式错误。")
            }
            guard endMinutes > startMinutes else {
                throw scheduleValidationError("时间表格式错误。")
            }
            if let last = timeTable.last, startMinutes <= last.endMinutes {
                throw scheduleValidationError("时间表格式错误。")
            }

            timeTable.append(TimeSlot(id: index + 1, start: start, end: end))
        }

        guard !timeTable.isEmpty else {
            throw scheduleValidationError("时间表格式错误。")
        }

        courseState.timeTable = timeTable
        persist()
    }

    private func validTimeTableMinutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0 ... 23).contains(hour),
              (0 ... 59).contains(minute)
        else {
            return nil
        }
        return hour * 60 + minute
    }

}
