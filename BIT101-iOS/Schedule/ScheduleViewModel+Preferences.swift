//
//  ScheduleViewModel+Preferences.swift
//  BIT101-iOS
//

import Foundation

extension ScheduleViewModel {
    /// 把周次快速重置到当前周。
    func resetToCurrentWeek() {
        selectedWeek = resolvedAutomaticWeek()
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
    func renamePrimarySchedule(to title: String) throws {
        let trimmed = try validatedScheduleTitle(title)
        cache.primaryScheduleTitle = trimmed
        persist()
    }

    /// 重命名一份导入的分享课表。
    func renameSharedSchedule(id: String, to title: String) throws {
        let trimmed = try validatedScheduleTitle(title)
        guard let index = cache.sharedSchedules.firstIndex(where: { $0.id == id }) else { return }
        cache.sharedSchedules[index].title = trimmed
        persist()
    }

    /// 删除一份导入的分享课表。
    func deleteSharedSchedule(id: String) {
        cache.sharedSchedules.removeAll { $0.id == id }
        selectedCourseScheduleIndex = min(selectedCourseScheduleIndex, max(courseSchedules.count - 1, 0))
        persist()
    }

    /// 设置周六课程显示。
    func setShowSaturday(_ value: Bool) {
        cache.showSaturday = value
        persist()
    }

    /// 设置周日课程显示。
    func setShowSunday(_ value: Bool) {
        cache.showSunday = value
        persist()
    }

    /// 设置课表网格中的考试块显示。
    func setShowExamInfo(_ value: Bool) {
        cache.showExamInfo = value
        persist()
    }

    /// 设置课程在周视图中的排布方式。
    func setScheduleDisplayMode(_ mode: ScheduleDisplayMode) {
        guard cache.scheduleDisplayMode != mode else { return }
        cache.scheduleDisplayMode = mode
        persist()
    }

    /// 设置课程卡片显示内容。
    func setScheduleCardContentMode(_ mode: ScheduleCardContentMode) {
        guard cache.scheduleCardContentMode != mode else { return }
        cache.scheduleCardContentMode = mode
        persist()
    }

    func setICloudSyncEnabled(_ value: Bool) {
        guard cache.iCloudSyncEnabled != value else { return }
        cache.iCloudSyncEnabled = value

        persist(source: .localWithoutCloudPush)

        #if canImport(CloudKit)
        if value {
            let localCache = cache
            Task {
                await ScheduleCloudSyncManager.shared.reconcileAfterEnabling(localCache: localCache)
            }
        }
        #endif
    }

    /// 设置课程提醒 Live Activity 启用状态。
    func setShowCourseLiveActivityReminder(_ value: Bool) {
        cache.showCourseLiveActivityReminder = value
        persist()

        if value {
            Task {
                _ = await ScheduleLiveActivityManager.shared.requestNotificationAuthorizationIfNeeded()
                await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(trigger: "reminder_toggle_enabled")
            }
        }
    }

    /// 设置灵动岛/锁屏提醒的提前显示阈值。
    func setCourseLiveActivityLeadMinutes(_ value: Int) {
        cache.courseLiveActivityLeadMinutes = min(max(value, 1), 60)
        persist()
    }

    /// 从多行文本解析并替换整份时间表。
    ///
    /// 每行格式固定为 `开始时间,结束时间`；这里会同时校验顺序和重叠。
    func setTimeTable(from text: String) throws {
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

        cache.timeTable = timeTable
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
