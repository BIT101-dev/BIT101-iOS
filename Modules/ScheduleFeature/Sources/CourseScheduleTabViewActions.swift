import SchedulePorts
#if os(iOS)
import DesignSystemKit
import ScheduleDomain
import TransportCore
import SwiftUI

extension CourseScheduleTabView {
    func cancelPendingActions() {
        calendarMutationTask?.cancel()
        courseShareTask?.cancel()
        scheduleExportTask?.cancel()
        prefetchedCourseID = nil
        prefetchedCourseResolution = nil
        courseShareGeneration &+= 1
        isResolvingCourseShare = false
    }

    func dismissPresentedSheets() {
        cancelPendingActions()
        courseShareAlert = nil
        selectedEntry = nil
        isShowingEditSchedule = false
        isShowingCourseEditor = false
        isShowingScheduleImport = false
        exportedSchedule = nil
        courseSharePresentation = nil
        prefetchedCourseID = nil
        prefetchedCourseResolution = nil
        editingCustomScheduleID = nil
        selectedDayAdjustmentContext = nil
    }

    var weekPickerWeeks: [Int] {
        let courseWeeks = activeSchedule.courses.flatMap(\.weeks)
        let lowerBound = min(-12, min(viewModel.selectedWeek, courseWeeks.min() ?? -12))
        let upperBound = max(20, max(viewModel.selectedWeek, courseWeeks.max() ?? 20))
        return Array(lowerBound ... upperBound).filter { $0 != 0 }
    }

    func presentSaveError(_ error: Error) {
        viewModel.notice = ScheduleNotice.userInput(title: "保存失败", message: error.localizedDescription)
    }

    func calendarMutationAlert(_ result: ScheduleSystemCalendarMutationResult) -> AppAlert {
        switch result {
        case let .changed(count):
            return AppAlert.informational(
                title: "已移除系统日历事件",
                message: "已移除 \(count) 个日历事件。"
            )
        case .noOp:
            return AppAlert.informational(
                title: "无需移除",
                message: "系统日历中没有匹配的 BIT101 事件。"
            )
        }
    }

    func calendarCourseContent(courseID: String, week: Int? = nil) -> ScheduleSystemCalendarContent? {
        guard let course = activeSchedule.courses.first(where: { $0.id == courseID }),
              let firstDay = activeSchedule.firstDay else { return nil }
        let courses: [CourseRecord]
        if week != nil {
            courses = [course]
        } else {
            courses = activeSchedule.courses.filter {
                scheduleCourseIdentity($0) == scheduleCourseIdentity(course)
            }
        }
        return .courses(courses, firstDay: firstDay, timeTable: activeSchedule.timeTable, week: week)
    }

    func importCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) {
        let generation = viewModel.accountGeneration
        calendarMutationTask?.cancel()
        calendarMutationTask = Task {
            guard !Task.isCancelled, viewModel.accountGeneration == generation else { return }
            do {
                let count = try await viewModel.importSystemCalendarEntries(content, term: term)
                guard !Task.isCancelled, viewModel.accountGeneration == generation else { return }
                courseShareAlert = AppAlert.informational(
                    title: "已导入系统日历",
                    message: "已导入 \(count) 个日历事件。"
                )
            } catch {
                guard !Task.isCancelled, viewModel.accountGeneration == generation else { return }
                courseShareAlert = AppAlert(title: "导入日历失败", error: error)
            }
        }
    }

    func deleteCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) {
        let generation = viewModel.accountGeneration
        calendarMutationTask?.cancel()
        calendarMutationTask = Task {
            guard !Task.isCancelled, viewModel.accountGeneration == generation else { return }
            do {
                let result = try await viewModel.deleteSystemCalendarEntries(content, term: term)
                guard !Task.isCancelled, viewModel.accountGeneration == generation else { return }
                courseShareAlert = calendarMutationAlert(result)
            } catch {
                guard !Task.isCancelled, viewModel.accountGeneration == generation else { return }
                courseShareAlert = AppAlert(title: "移除日历失败", error: error)
            }
        }
    }

    func deleteCalendarEntries(markerIDs: Set<String>, term: String) {
        let generation = viewModel.accountGeneration
        calendarMutationTask?.cancel()
        calendarMutationTask = Task {
            guard !Task.isCancelled, viewModel.accountGeneration == generation else { return }
            do {
                let result = try await viewModel.deleteSystemCalendarEntries(markerIDs: markerIDs, term: term)
                guard !Task.isCancelled, viewModel.accountGeneration == generation else { return }
                courseShareAlert = calendarMutationAlert(result)
            } catch {
                guard !Task.isCancelled, viewModel.accountGeneration == generation else { return }
                courseShareAlert = AppAlert(title: "移除日历失败", error: error)
            }
        }
    }

    func exportScheduleCode() {
        guard scheduleExportTask == nil else { return }
        guard !activeSchedule.courses.isEmpty else {
            viewModel.notice = ScheduleNotice.userInput(title: "无法分享课表", message: "你尚未获取课表。")
            return
        }

        let courses = activeSchedule.courses
        scheduleExportTask = Task { @MainActor in
            defer { scheduleExportTask = nil }
            do {
                let code = try await viewModel.exportScheduleCode(courses: courses)
                exportedSchedule = ScheduleCodePresentation(code: code)
            } catch where TaskCancellation.matches(error) {
                return
            } catch {
                viewModel.notice = ScheduleNotice(title: "导出失败", error: error)
            }
        }
    }

    func importScheduleCode(_ text: String) async throws {
        try await viewModel.importScheduleCode(text)
        viewModel.notice = ScheduleNotice.informational(title: "导入成功", message: "分享的课表已导入。考试、DDL 与自定义日程不会随导入覆盖。")
    }

    @MainActor
    func shareCourse(from entry: ScheduleCalendarEntry) {
        guard !isResolvingCourseShare else { return }
        guard let sourceID = entry.resolvedSourceIDs.first,
              let course = activeSchedule.courses.first(where: { $0.id == sourceID })
        else {
            courseShareAlert = AppAlert.userInput(title: "没有找到此课程", message: "课表中的课程记录已不存在。")
            return
        }

        let prefetchedResolution = prefetchedCourseID == sourceID ? prefetchedCourseResolution : nil
        let generation = viewModel.accountGeneration
        courseShareGeneration &+= 1
        let operation = courseShareGeneration
        isResolvingCourseShare = true
        courseShareTask = Task { @MainActor in
            defer { if viewModel.accountGeneration == generation, courseShareGeneration == operation { isResolvingCourseShare = false } }
            guard viewModel.accountGeneration == generation else { return }
            do {
                let resolution: ScheduleCourseShare?
                if let prefetchedResolution {
                    resolution = prefetchedResolution
                } else {
                    resolution = try await destinations.resolveCourseShare(course)
                }
                guard !Task.isCancelled, viewModel.accountGeneration == generation else { return }
                guard let resolution else {
                    courseShareAlert = AppAlert.userInput(
                        title: "没有找到此课程",
                        message: "“\(course.name)”暂未收录在学业课程中。"
                    )
                    return
                }
                courseSharePresentation = CourseSharePresentation(url: resolution.url, subject: resolution.subject)
            } catch {
                guard !Task.isCancelled, viewModel.accountGeneration == generation else { return }
                courseShareAlert = AppAlert(title: "查找课程失败", error: error)
            }
        }
    }

    @MainActor
    func prepareCourseShare(from entry: ScheduleCalendarEntry) {
        guard let sourceID = entry.resolvedSourceIDs.first,
              activeSchedule.courses.contains(where: { $0.id == sourceID })
        else { return }
        guard prefetchedCourseID != sourceID else { return }

        prefetchedCourseID = sourceID
        prefetchedCourseResolution = nil
    }

    @MainActor
    func resolvePreparedCourseShare() async {
        guard let sourceID = prefetchedCourseID,
              let course = activeSchedule.courses.first(where: { $0.id == sourceID }) else { return }
        let generation = viewModel.accountGeneration
        do {
            let resolution = try await destinations.resolveCourseShare(course)
            guard !Task.isCancelled, viewModel.accountGeneration == generation,
                  prefetchedCourseID == sourceID else { return }
            if let resolution {
                prefetchedCourseResolution = resolution
            } else {
                prefetchedCourseID = nil
            }
        } catch {
            guard !Task.isCancelled, viewModel.accountGeneration == generation,
                  prefetchedCourseID == sourceID else { return }
            prefetchedCourseID = nil
            prefetchedCourseResolution = nil
        }
    }

    /// 课表之间的上下滑循环切换。
    ///
    /// 手势在“课表”分区内处理上下滑循环切换，与上方一级分栏的左右滑切换保持独立。
    var scheduleSwitchGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height

                guard abs(vertical) > abs(horizontal), abs(vertical) >= 56 else { return }
                guard viewModel.presentationPreferences.scheduleDisplayMode == .weekly else { return }
                guard calendarAxisMode == .quantized else { return }

                if vertical < 0 {
                    viewModel.cycleCourseSchedule(step: 1)
                } else {
                    viewModel.cycleCourseSchedule(step: -1)
                }
            }
    }

}

#endif
