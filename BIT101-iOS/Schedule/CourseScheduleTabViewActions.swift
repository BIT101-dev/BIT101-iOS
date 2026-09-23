import SwiftUI

extension CourseScheduleTabView {
    /// 收起课表分栏当前打开的抽屉和设置页。
    ///
    /// 这里保留当前分栏实例，直接走各个 sheet 的正常关闭路径；系统复用原生下滑关闭动画，
    /// 关闭过程保持连续。
    func dismissPresentedSheets() {
        selectedEntry = nil
        settingsRoute = nil
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

    var cardDisplayAccessibilityLabel: String {
        switch viewModel.cache.scheduleCardContentMode {
        case .nameAndLocation:
            return "显示课程名称和地点"
        case .name:
            return "显示课程名称"
        case .location:
            return "显示课程地点"
        }
    }

    func preferredCourseWeek(from weeks: [Int]) -> Int {
        weeks.contains(viewModel.selectedWeek)
            ? viewModel.selectedWeek
            : (weeks.first ?? viewModel.selectedWeek)
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

    func exportScheduleCode() {
        guard !activeSchedule.courses.isEmpty else {
            viewModel.notice = ScheduleNotice.userInput(title: "无法分享课表", message: "你尚未获取课表。")
            return
        }

        do {
            exportedSchedule = ScheduleCodePresentation(
                code: try ScheduleShareCodeCodec.encodeLatest(courses: activeSchedule.courses)
            )
        } catch {
            viewModel.notice = ScheduleNotice(title: "导出失败", message: error.localizedDescription)
        }
    }

    func importScheduleCode(_ text: String) throws {
        let payload = try ScheduleShareCodeCodec.decode(text, using: viewModel.cache)
        try viewModel.importSharedSchedule(payload)
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
        isResolvingCourseShare = true
        Task { @MainActor in
            defer { isResolvingCourseShare = false }
            guard viewModel.accountGeneration == generation else { return }
            do {
                let resolution: ScheduleAcademicCourseResolution?
                if let prefetchedResolution {
                    resolution = prefetchedResolution
                } else {
                    resolution = try await ScheduleAcademicCourseResolver().resolve(course)
                }
                guard let resolution else {
                    courseShareAlert = AppAlert.userInput(
                        title: "没有找到此课程",
                        message: "“\(course.name)”暂未收录在学业课程中。"
                    )
                    return
                }
                var pathComponentAllowed = CharacterSet.alphanumerics
                pathComponentAllowed.insert(charactersIn: "-._~")
                let courseID = String(resolution.selectedCourse.id)
                guard let encodedCourseID = courseID.addingPercentEncoding(
                          withAllowedCharacters: pathComponentAllowed
                      ),
                      let url = URL(string: "https://open.aihelpme.dev/course/\(encodedCourseID)") else {
                    courseShareAlert = AppAlert.userInput(title: "分享失败", message: "课程分享链接无效。")
                    return
                }
                courseSharePresentation = CourseSharePresentation(
                    url: url,
                    subject: resolution.selectedCourse.name
                )
            } catch {
                courseShareAlert = AppAlert(title: "查找课程失败", message: error.localizedDescription)
            }
        }
    }

    @MainActor
    func prepareCourseShare(from entry: ScheduleCalendarEntry) {
        guard let sourceID = entry.resolvedSourceIDs.first,
              let course = activeSchedule.courses.first(where: { $0.id == sourceID })
        else { return }
        guard prefetchedCourseID != sourceID else { return }

        prefetchedCourseID = sourceID
        prefetchedCourseResolution = nil
        let generation = viewModel.accountGeneration
        Task { @MainActor in
            do {
                let resolution = try await ScheduleAcademicCourseResolver().resolve(course)
                guard viewModel.accountGeneration == generation,
                      prefetchedCourseID == sourceID
                else { return }
                if let resolution {
                    prefetchedCourseResolution = resolution
                } else {
                    prefetchedCourseID = nil
                }
            } catch {
                guard viewModel.accountGeneration == generation,
                      prefetchedCourseID == sourceID
                else { return }
                prefetchedCourseID = nil
                prefetchedCourseResolution = nil
            }
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
                guard viewModel.cache.scheduleDisplayMode == .weekly else { return }
                guard calendarAxisMode == .quantized else { return }

                if vertical < 0 {
                    viewModel.cycleCourseSchedule(step: 1)
                } else {
                    viewModel.cycleCourseSchedule(step: -1)
                }
            }
    }

}
