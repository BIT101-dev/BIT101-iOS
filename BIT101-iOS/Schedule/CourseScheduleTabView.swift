//
//  CourseScheduleTabView.swift
//  BIT101-iOS
//

import SwiftUI

struct CourseScheduleTabView: View {
    private struct ScheduleCodePresentation: Identifiable {
        let id = UUID()
        let code: String
    }

    private struct CourseSharePresentation: Identifiable {
        let id = UUID()
        let url: URL
        let subject: String
    }

    @ObservedObject var viewModel: ScheduleViewModel
    let resetSignal: Int
    let onOpenAcademicCourse: (CourseNavigationRequest) -> Void
    let onOpenCourseLocation: (CampusMapLocationRequest) -> Void
    @State private var selectedEntry: ScheduleCalendarEntry?
    @State private var editingCustomScheduleID: String?
    @State private var editingCourseID: String?
    @State private var selectedDayAdjustmentContext: ScheduleDayAdjustmentContext?
    @State private var customScheduleDraft = CustomScheduleDraft()
    @State private var courseDraft = CourseDraft()
    @State private var dayAdjustmentDraft = ScheduleDayAdjustmentDraft()
    @State private var isShowingEditSchedule = false
    @State private var isShowingCourseEditor = false
    @State private var courseEditorMode: CourseEditorMode = .add
    @State private var settingsRoute: SettingsRoute?
    @State private var isShowingSystemCalendarImportConfirmation = false
    @State private var isShowingSystemCalendarDeleteConfirmation = false
    @State private var isUpdatingSystemCalendar = false
    @State private var isShowingScheduleImport = false
    @State private var exportedSchedule: ScheduleCodePresentation?
    @State private var courseSharePresentation: CourseSharePresentation?
    @State private var courseShareAlert: AppAlert?
    @State private var isResolvingCourseShare = false
    @State private var prefetchedCourseID: String?
    @State private var prefetchedCourseResolution: ScheduleAcademicCourseResolution?

    var activeSchedule: ScheduleViewModel.CourseScheduleVariant {
        viewModel.activeCourseSchedule
    }

    private var supportsEditingDisplayedSchedule: Bool {
        activeSchedule.isPrimary
    }

    /// 课表分区主体。
    var body: some View {
        Group {
            // 学校尚未发布未来学期课表时，课程接口通常会正常返回空数组，而不是 404。
            // 只要首周日期有效，就照常展示空课表网格和右下角操作按钮，不能让“无课程”
            // 占位页挡住周次浏览、设置以及手动添加日程的入口。
            if let firstDay = activeSchedule.firstDay {
                GeometryReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                        CourseScheduleCalendarView(
                            entries: scheduleEntries,
                            week: viewModel.selectedWeek,
                            availableWeeks: weekPickerWeeks,
                            displayMode: viewModel.cache.scheduleDisplayMode,
                            firstDay: firstDay,
                            timeTable: activeSchedule.timeTable,
                            currentWeek: resolvedCurrentWeek(firstDay: firstDay),
                            showSaturday: viewModel.cache.showSaturday,
                            showSunday: viewModel.cache.showSunday,
                            showHighlightToday: viewModel.cache.showHighlightToday,
                            showDivider: viewModel.cache.showDivider,
                            showCurrentTime: viewModel.cache.showCurrentTime,
                            showBorder: viewModel.cache.showBorder,
                            onSelect: { entry in
                                selectedEntry = entry
                            },
                            onSelectDay: { date, weekday in
                                guard viewModel.cache.scheduleDisplayMode == .weekly else { return }
                                guard supportsEditingDisplayedSchedule else {
                                    viewModel.notice = ScheduleNotice(
                                        title: "无法调整分享课表",
                                        message: "分享课表是只读副本。调休 / 放假只支持当前账号自己的课表，不会修改导入的分享课表。"
                                    )
                                    return
                                }
                                selectedDayAdjustmentContext = ScheduleDayAdjustmentContext(
                                    date: date,
                                    week: viewModel.selectedWeek,
                                    weekday: weekday
                                )
                                dayAdjustmentDraft = ScheduleDayAdjustmentDraft(
                                    targetDate: Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
                                )
                            },
                            onSelectWeekValue: { week in
                                viewModel.selectedWeek = week
                            },
                            onLongPressCourse: { entry in
                                shareCourse(from: entry)
                            },
                            onPrepareCourseShare: { entry in
                                prepareCourseShare(from: entry)
                            },
                            onShareSchedule: { exportScheduleCode() },
                            onImportSchedule: { isShowingScheduleImport = true }
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 10)

                        AppFloatingActionStack {
                            if viewModel.cache.scheduleDisplayMode == .weekly {
                                CourseScheduleFAB(systemImage: "chevron.up", accessibilityLabel: "上一周") {
                                    viewModel.previousWeek()
                                }

                                CourseScheduleFAB(systemImage: "chevron.down", accessibilityLabel: "下一周") {
                                    viewModel.nextWeek()
                                }
                            }

                            if supportsEditingDisplayedSchedule {
                                Menu {
                                    Button("添加日程") {
                                        editingCustomScheduleID = nil
                                        customScheduleDraft = viewModel.customScheduleDraft(for: nil)
                                        isShowingEditSchedule = true
                                    }

                                    Button("添加课程") {
                                        courseEditorMode = .add
                                        courseDraft = viewModel.courseDraft(for: viewModel.selectedWeek)
                                        isShowingCourseEditor = true
                                    }
                                } label: {
                                    CourseScheduleFABLabel(systemImage: "plus")
                                }
                                .buttonStyle(.plain)
                                .tint(.primary)
                                .accessibilityLabel("添加课表内容")

                                Menu {
                                    Button(role: .destructive) {
                                        isShowingSystemCalendarDeleteConfirmation = true
                                    } label: {
                                        Label("删除已导入的日历事件", systemImage: "calendar.badge.minus")
                                    }

                                    Button {
                                        isShowingSystemCalendarImportConfirmation = true
                                    } label: {
                                        Label("导入到系统日历", systemImage: "calendar.badge.plus")
                                    }
                                } label: {
                                    CourseScheduleFABLabel(systemImage: "calendar")
                                }
                                .buttonStyle(.plain)
                                .tint(.primary)
                                .disabled(isUpdatingSystemCalendar)
                                .accessibilityLabel("系统日历操作")
                            }

                            CourseScheduleFAB(systemImage: "gearshape", accessibilityLabel: "课表设置") {
                                settingsRoute = .calendar
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            } else {
                VStack(spacing: 16) {
                    Text(activeSchedule.isPrimary ? "尚未设置学期起始日期" : "这份分享课表缺少起始日期")
                        .font(.headline)
                    Text(activeSchedule.isPrimary ? "请先同步所选学期，或在课表设置中手动设置起始日期。" : "试试上下滑切换到别的课表，或重新导入一份分享课表。")
                        .foregroundStyle(.secondary)
                    if supportsEditingDisplayedSchedule {
                        Button {
                            Task { await viewModel.syncSelectedTerm() }
                        } label: {
                            HStack {
                                if viewModel.isSyncingCourses {
                                    ProgressView()
                                }
                                Text("重新获取所选学期")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isSyncingCourses)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .simultaneousGesture(scheduleSwitchGesture)
        .sheet(item: $selectedEntry) { entry in
            ScheduleEntryDetailSheet(
                entry: entry,
                academicCourses: entry.resolvedSourceIDs.compactMap { sourceID in
                    activeSchedule.courses.first(where: { $0.id == sourceID })
                },
                currentWeek: viewModel.selectedWeek,
                allowsCourseMutation: supportsEditingDisplayedSchedule,
                isOverviewMode: supportsEditingDisplayedSchedule
                    && viewModel.cache.scheduleDisplayMode == .allWeeks,
                allowsCustomScheduleMutation: supportsEditingDisplayedSchedule,
                onOpenAcademicCourse: { request in
                    selectedEntry = nil
                    onOpenAcademicCourse(request)
                },
                onOpenCourseLocation: { request in
                    selectedEntry = nil
                    onOpenCourseLocation(request)
                },
                onEditCourseOccurrence: { courseID in
                    guard let course = activeSchedule.courses.first(where: { $0.id == courseID }) else { return }
                    let week = course.weeks.contains(viewModel.selectedWeek)
                        ? viewModel.selectedWeek
                        : (course.weeks.first ?? viewModel.selectedWeek)
                    editingCourseID = course.id
                    courseEditorMode = .editOccurrence(week: week)
                    courseDraft = viewModel.courseDraft(for: course, week: week, editsOccurrenceOnly: true)
                    selectedEntry = nil
                    isShowingCourseEditor = true
                },
                onEditCourse: { courseID in
                    guard let course = activeSchedule.courses.first(where: { $0.id == courseID }) else { return }
                    editingCourseID = course.id
                    courseEditorMode = .editCourse(courseID: course.id)
                    courseDraft = viewModel.courseDraft(for: course, week: viewModel.selectedWeek, editsOccurrenceOnly: false)
                    selectedEntry = nil
                    isShowingCourseEditor = true
                },
                onDeleteCourseOccurrence: { courseID in
                    guard let course = activeSchedule.courses.first(where: { $0.id == courseID }) else { return }
                    let week = course.weeks.contains(viewModel.selectedWeek)
                        ? viewModel.selectedWeek
                        : (course.weeks.first ?? viewModel.selectedWeek)
                    viewModel.deleteCourseOccurrence(id: course.id, week: week)
                    selectedEntry = nil
                },
                onDeleteCourse: { courseID in
                    viewModel.deleteCourse(id: courseID)
                    selectedEntry = nil
                },
                onEditCustomSchedule: {
                    if let schedule = viewModel.cache.customSchedules.first(where: { $0.id == entry.sourceID }) {
                        editingCustomScheduleID = schedule.id
                        customScheduleDraft = viewModel.customScheduleDraft(for: schedule)
                        isShowingEditSchedule = true
                    }
                },
                onDeleteCustomSchedule: {
                    viewModel.deleteCustomSchedule(id: entry.sourceID)
                    selectedEntry = nil
                }
            )
        }
        .sheet(isPresented: $isShowingEditSchedule) {
            AddEditCustomScheduleSheet(
                draft: $customScheduleDraft,
                isEditing: editingCustomScheduleID != nil,
                onSubmit: {
                    do {
                        if let editingCustomScheduleID {
                            try viewModel.updateCustomSchedule(id: editingCustomScheduleID, draft: customScheduleDraft)
                        } else {
                            try viewModel.addCustomSchedule(customScheduleDraft)
                        }
                        isShowingEditSchedule = false
                    } catch {
                        viewModel.notice = ScheduleNotice(title: "保存失败", message: error.localizedDescription)
                    }
                },
                onDismiss: {
                    isShowingEditSchedule = false
                }
            )
        }
        .sheet(isPresented: $isShowingCourseEditor) {
            AddCourseSheet(
                draft: $courseDraft,
                mode: courseEditorMode,
                timeTable: viewModel.cache.timeTable,
                onSubmit: {
                    do {
                        switch courseEditorMode {
                        case .add:
                            try viewModel.addCourse(courseDraft)
                        case let .editOccurrence(week):
                            if let sourceID = editingCourseID {
                                try viewModel.updateCourseOccurrence(id: sourceID, week: week, draft: courseDraft)
                            } else {
                                throw NSError(
                                    domain: "BIT101.Schedule",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "找不到要调整的课程。"]
                                )
                            }
                        case let .editCourse(courseID):
                            try viewModel.updateCourse(id: courseID, draft: courseDraft)
                        }
                        editingCourseID = nil
                        isShowingCourseEditor = false
                    } catch {
                        viewModel.notice = ScheduleNotice(title: "保存失败", message: error.localizedDescription)
                    }
                },
                onDismiss: {
                    editingCourseID = nil
                    isShowingCourseEditor = false
                }
            )
        }
        .sheet(item: $selectedDayAdjustmentContext) { context in
            DayAdjustmentSheet(
                context: context,
                draft: $dayAdjustmentDraft,
                onSubmit: {
                    do {
                        switch dayAdjustmentDraft.mode {
                        case .holiday:
                            viewModel.clearCourses(week: context.week, weekday: context.weekday)
                        case .transfer:
                            try viewModel.transferCourses(
                                fromWeek: context.week,
                                fromWeekday: context.weekday,
                                to: dayAdjustmentDraft.targetDate
                            )
                        }
                        selectedDayAdjustmentContext = nil
                    } catch {
                        viewModel.notice = ScheduleNotice(title: "保存失败", message: error.localizedDescription)
                    }
                },
                onDismiss: {
                    selectedDayAdjustmentContext = nil
                }
            )
        }
        .sheet(item: $courseSharePresentation) { presentation in
            CourseActivityShareSheet(url: presentation.url, subject: presentation.subject)
        }
        .sheet(item: $exportedSchedule) { presentation in
            ScheduleExportCodeSheet(code: presentation.code)
        }
        .sheet(isPresented: $isShowingScheduleImport) {
            ScheduleImportCodeSheet(
                initialText: "",
                onImport: { text in
                    try importScheduleCode(text)
                }
            )
        }
        .sheet(item: $settingsRoute) { route in
            NavigationStack {
                SettingsRootView(initialRoute: route, studentID: "", onLogout: {}, showsCloseButton: true)
            }
        }
        .alert("导入当前学期到系统日历？", isPresented: $isShowingSystemCalendarImportConfirmation) {
            Button("导入并替换本学期旧事件") {
                importCurrentTermToSystemCalendar()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将创建“BIT101 课表”日历；重复导入时只替换 BIT101 创建的本学期事件。")
        }
        .alert("删除 BIT101 导入的日历事件？", isPresented: $isShowingSystemCalendarDeleteConfirmation) {
            Button("删除", role: .destructive) {
                deleteImportedSystemCalendarEvents()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除带 BIT101 标记的事件，不会删除你自己创建的日程。")
        }
        .diagnosticAlert(item: $courseShareAlert)
        .onChange(of: resetSignal) { _, _ in
            dismissPresentedSheets()
        }
    }

    /// 收起课表分栏当前打开的抽屉和设置页。
    ///
    /// 这里不重建整个分栏，而是直接走各个 sheet 的正常关闭路径，
    /// 这样系统会复用原生下滑关闭动画，避免出现“闪现消失”。
    private func dismissPresentedSheets() {
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
        editingCourseID = nil
        selectedDayAdjustmentContext = nil
    }

    private var weekPickerWeeks: [Int] {
        let courseWeeks = activeSchedule.courses.flatMap(\.weeks)
        let lowerBound = min(-12, min(viewModel.selectedWeek, courseWeeks.min() ?? -12))
        let upperBound = max(20, max(viewModel.selectedWeek, courseWeeks.max() ?? 20))
        return Array(lowerBound ... upperBound).filter { $0 != 0 }
    }

    private func importCurrentTermToSystemCalendar() {
        isUpdatingSystemCalendar = true
        Task {
            do {
                let count = try await ScheduleSystemCalendarManager.shared.importCurrentTerm(from: viewModel.cache)
                viewModel.notice = ScheduleNotice(
                    title: "导入成功",
                    message: "已向“BIT101 课表”日历写入 \(count) 节课程。"
                )
            } catch {
                viewModel.notice = ScheduleNotice(title: "导入失败", message: error.localizedDescription)
            }
            isUpdatingSystemCalendar = false
        }
    }

    private func deleteImportedSystemCalendarEvents() {
        isUpdatingSystemCalendar = true
        Task {
            do {
                let count = try await ScheduleSystemCalendarManager.shared.deleteAllImportedEvents()
                viewModel.notice = ScheduleNotice(
                    title: "删除成功",
                    message: "已删除 \(count) 条由 BIT101 导入的日历事件。"
                )
            } catch {
                viewModel.notice = ScheduleNotice(title: "删除失败", message: error.localizedDescription)
            }
            isUpdatingSystemCalendar = false
        }
    }

    private func exportScheduleCode() {
        guard !viewModel.cache.courses.isEmpty else {
            viewModel.notice = ScheduleNotice(title: "无法分享课表", message: "你尚未获取课表。")
            return
        }

        do {
            exportedSchedule = ScheduleCodePresentation(
                code: try ScheduleShareCodeCodec.encodeLatest(cache: viewModel.cache)
            )
        } catch {
            viewModel.notice = ScheduleNotice(title: "导出失败", message: error.localizedDescription)
        }
    }

    private func importScheduleCode(_ text: String) throws {
        let payload = try ScheduleShareCodeCodec.decode(text, using: viewModel.cache)
        try viewModel.importSharedSchedule(payload)
        viewModel.notice = ScheduleNotice(title: "导入成功", message: "分享的课表已导入。考试、DDL 与自定义日程不会随导入覆盖。")
    }

    @MainActor
    private func shareCourse(from entry: ScheduleCalendarEntry) {
        guard !isResolvingCourseShare else { return }
        guard let sourceID = entry.resolvedSourceIDs.first,
              let course = activeSchedule.courses.first(where: { $0.id == sourceID })
        else {
            courseShareAlert = AppAlert(title: "没有找到此课程", message: "课表中的课程记录已不存在。")
            return
        }

        let prefetchedResolution = prefetchedCourseID == sourceID ? prefetchedCourseResolution : nil
        isResolvingCourseShare = true
        Task { @MainActor in
            defer { isResolvingCourseShare = false }
            do {
                let resolution: ScheduleAcademicCourseResolution?
                if let prefetchedResolution {
                    resolution = prefetchedResolution
                } else {
                    resolution = try await ScheduleAcademicCourseResolver().resolve(course)
                }
                guard let resolution else {
                    courseShareAlert = AppAlert(
                        title: "没有找到此课程",
                        message: "“\(course.name)”暂未收录在学业课程中。"
                    )
                    return
                }
                guard let url = URL(string: "https://open.aihelpme.dev/course/\(resolution.selectedCourse.id)") else {
                    courseShareAlert = AppAlert(title: "分享失败", message: "课程分享链接无效。")
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
    private func prepareCourseShare(from entry: ScheduleCalendarEntry) {
        guard let sourceID = entry.resolvedSourceIDs.first,
              let course = activeSchedule.courses.first(where: { $0.id == sourceID })
        else { return }
        guard prefetchedCourseID != sourceID else { return }

        prefetchedCourseID = sourceID
        prefetchedCourseResolution = nil
        Task { @MainActor in
            guard let resolution = try? await ScheduleAcademicCourseResolver().resolve(course),
                  prefetchedCourseID == sourceID
            else { return }
            prefetchedCourseResolution = resolution
        }
    }

    /// 课表之间的上下滑循环切换。
    ///
    /// 只在“课表”分区内启用，和上方一级分栏的左右滑切换分开处理。
    private var scheduleSwitchGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height

                guard abs(vertical) > abs(horizontal), abs(vertical) >= 56 else { return }
                guard viewModel.cache.scheduleDisplayMode == .weekly else { return }

                if vertical < 0 {
                    viewModel.cycleCourseSchedule(step: 1)
                } else {
                    viewModel.cycleCourseSchedule(step: -1)
                }
            }
    }

}
