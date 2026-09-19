//
//  CourseScheduleTabView.swift
//  BIT101-iOS
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CourseScheduleTabView: View {
    struct ScheduleCodePresentation: Identifiable {
        let id = UUID()
        let code: String
    }

    struct CourseSharePresentation: Identifiable {
        let id = UUID()
        let url: URL
        let subject: String
    }

    @ObservedObject var viewModel: ScheduleViewModel
    let resetSignal: Int
    let onOpenAcademicCourse: (CourseNavigationRequest) -> Void
    let onOpenCourseLocation: (CampusMapLocationRequest) -> Void
    @State var selectedEntry: ScheduleCalendarEntry?
    @State var editingCustomScheduleID: String?
    @State var editingCourseID: String?
    @State var selectedDayAdjustmentContext: ScheduleDayAdjustmentContext?
    @State var customScheduleDraft = CustomScheduleDraft()
    @State var courseDraft = CourseDraft()
    @State var dayAdjustmentDraft = ScheduleDayAdjustmentDraft()
    @State var isShowingEditSchedule = false
    @State var isShowingCourseEditor = false
    @State var courseEditorMode: CourseEditorMode = .add
    @State var settingsRoute: SettingsRoute?
    @State var cardDisplayFeedbackToken = 0
    @State var isShowingScheduleImport = false
    @State var exportedSchedule: ScheduleCodePresentation?
    @State var courseSharePresentation: CourseSharePresentation?
    @State var courseShareAlert: AppAlert?
    @State var isResolvingCourseShare = false
    @State var prefetchedCourseID: String?
    @State var prefetchedCourseResolution: ScheduleAcademicCourseResolution?
    @State var bottomTabBarOverlap: CGFloat?
    @AppStorage("schedule.calendar.axisMode") var storedCalendarAxisMode = ScheduleCalendarAxisMode.quantized.rawValue
    @State var calendarAxisZoomScale: CGFloat = AppDesignSystem.Schedule.timelineDefaultScale

    var activeSchedule: ScheduleViewModel.CourseScheduleVariant {
        viewModel.activeCourseSchedule
    }

    var calendarAxisMode: ScheduleCalendarAxisMode {
        ScheduleCalendarAxisMode(rawValue: storedCalendarAxisMode) ?? .quantized
    }

    var supportsEditingDisplayedSchedule: Bool {
        activeSchedule.isPrimary
    }

    /// 课表分区主体。
    ///
    /// 课表页使用主 List 承载更新时间和表格两个 Section，更新时间与表格共享同一个列表。
    var body: some View {
        GeometryReader { proxy in
            let listHeight = max(
                proxy.size.height
                    - (bottomTabBarOverlap ?? 0),
                1
            )
            let calendarHeight = max(
                listHeight
                    - (activeSchedule.isPrimary ? AppDesignSystem.Size.content.refreshStatusListHeight : 0)
                    - AppDesignSystem.Spacing.content,
                1
            )

            ZStack(alignment: .bottomTrailing) {
                List {
                    if activeSchedule.isPrimary {
                        Section {
                            AppRefreshStatusRow(
                                isRefreshing: viewModel.isSyncingCourses,
                                refreshingText: "正在刷新课表",
                                lastUpdatedText: viewModel.coursesLastUpdatedText,
                                actionTitle: "刷新",
                                onRefresh: {
                                    Task { await viewModel.syncSelectedTerm() }
                                }
                            )
                        }
                    }

                    // 学校尚未发布未来学期课表时，课程接口通常正常返回空数组。
                    // 首周日期有效时，页面展示空课表网格和右下角操作按钮，周次浏览、设置以及
                    // 手动添加日程入口保持可用。
                    if let firstDay = activeSchedule.firstDay {
                        Section {
                            CourseScheduleCalendarView(
                                entries: scheduleEntries,
                                week: viewModel.selectedWeek,
                                availableWeeks: weekPickerWeeks,
                                displayMode: viewModel.cache.scheduleDisplayMode,
                                cardContentMode: viewModel.cache.scheduleCardContentMode,
                                axisMode: calendarAxisMode,
                                axisZoomScale: $calendarAxisZoomScale,
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
                                        viewModel.notice = ScheduleNotice.userInput(
                                            title: "无法调整分享课表",
                                            message: "分享课表是只读副本。调休 / 放假操作面向当前账号自己的课表，导入的分享课表保持原样。"
                                        )
                                        return
                                    }
                                    selectedDayAdjustmentContext = ScheduleDayAdjustmentContext(
                                        date: date,
                                        week: viewModel.selectedWeek,
                                        weekday: weekday
                                    )
                                    dayAdjustmentDraft = ScheduleDayAdjustmentDraft(
                                        targetDate: ScheduleDateCodec.calendar.date(byAdding: .day, value: 1, to: date) ?? date
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
                            .frame(height: calendarHeight)
                            // 课表自身绘制白色分组背景；List 行背景保持在悬浮 Tab 栏上方。
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(AppDesignSystem.Palette.groupedBackground)
                        }
                    } else {
                        Section {
                            VStack(spacing: AppDesignSystem.Spacing.section) {
                                Text(activeSchedule.isPrimary ? "尚未设置学期起始日期" : "这份分享课表缺少起始日期")
                                    .font(AppDesignSystem.Typography.headline)
                                Text(activeSchedule.isPrimary ? "请先同步所选学期，或在课表设置中手动设置起始日期。" : "试试上下滑切换到别的课表，或重新导入一份分享课表。")
                                    .foregroundStyle(.secondary)
                                if supportsEditingDisplayedSchedule {
                                    Button {
                                        Task { await viewModel.syncSelectedTerm() }
                                    } label: {
                                        HStack(spacing: AppDesignSystem.Spacing.control) {
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
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .appGroupedListStyle()
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: listHeight, alignment: .top)

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

                        Button {
                            cardDisplayFeedbackToken &+= 1
                            viewModel.toggleScheduleCardContentMode()
                        } label: {
                            CourseScheduleFABLabel(text: "名/地")
                        }
                        .buttonStyle(.plain)
                        .tint(.primary)
                        .appImpactFeedback(trigger: cardDisplayFeedbackToken)
                        .accessibilityLabel(cardDisplayAccessibilityLabel)
                        .accessibilityValue("名/地")
                    }

                    Button {
                        storedCalendarAxisMode = calendarAxisMode.next.rawValue
                        calendarAxisZoomScale = AppDesignSystem.Schedule.timelineDefaultScale
                    } label: {
                        CourseScheduleFABLabel(text: "节/时")
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)
                    .accessibilityLabel(calendarAxisMode.accessibilityLabel)
                    .accessibilityValue(calendarAxisMode == .quantized ? "节次" : "时间")

                    CourseScheduleFAB(systemImage: "gearshape", accessibilityLabel: "课表设置") {
                        settingsRoute = .calendar
                    }
                }

            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
#if canImport(UIKit)
            .background {
                ScheduleTabBarOverlapReader { overlap in
                    guard bottomTabBarOverlap != overlap else { return }
                    bottomTabBarOverlap = overlap
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
#endif
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
                    let week = preferredCourseWeek(from: course.weeks)
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
                    let week = preferredCourseWeek(from: course.weeks)
                    viewModel.deleteCourseOccurrence(id: course.id, week: week)
                    selectedEntry = nil
                },
                onDeleteCourse: { courseID in
                    viewModel.deleteCourse(id: courseID)
                    selectedEntry = nil
                },
                onImportCourseOccurrence: { courseID, week in
                    guard let course = activeSchedule.courses.first(where: { $0.id == courseID }),
                          let firstDay = activeSchedule.firstDay else { return }
                    let drafts = ScheduleSystemCalendarEventBuilder.makeDrafts(
                        courses: [course],
                        firstDay: firstDay,
                        timeTable: activeSchedule.timeTable
                    ).filter { $0.markerID == "\(course.id)-w\(week)" }
                    Task {
                        do {
                            let count = try await ScheduleSystemCalendarManager.shared.importDrafts(
                                drafts,
                                term: activeSchedule.currentTerm
                            )
                            courseShareAlert = AppAlert.informational(
                                title: "已导入系统日历",
                                message: "已导入 \(count) 个日历事件。"
                            )
                        } catch {
                            courseShareAlert = AppAlert(title: "导入日历失败", message: error.localizedDescription)
                        }
                    }
                },
                onImportCourse: { courseID in
                    guard let course = activeSchedule.courses.first(where: { $0.id == courseID }),
                          let firstDay = activeSchedule.firstDay else { return }
                    let relatedCourses = activeSchedule.courses.filter {
                        scheduleCourseIdentity($0) == scheduleCourseIdentity(course)
                    }
                    let drafts = ScheduleSystemCalendarEventBuilder.makeDrafts(
                        courses: relatedCourses,
                        firstDay: firstDay,
                        timeTable: activeSchedule.timeTable
                    )
                    Task {
                        do {
                            let count = try await ScheduleSystemCalendarManager.shared.importDrafts(
                                drafts,
                                term: activeSchedule.currentTerm
                            )
                            courseShareAlert = AppAlert.informational(
                                title: "已导入系统日历",
                                message: "已导入 \(count) 个日历事件。"
                            )
                        } catch {
                            courseShareAlert = AppAlert(title: "导入日历失败", message: error.localizedDescription)
                        }
                    }
                },
                onDeleteCalendarMarkers: { markerIDs in
                    Task {
                        do {
                            let result = try await ScheduleSystemCalendarManager.shared.deleteImportedEvents(markerIDs: markerIDs)
                            courseShareAlert = calendarMutationAlert(result)
                        } catch {
                            courseShareAlert = AppAlert(title: "移除日历失败", message: error.localizedDescription)
                        }
                    }
                },
                onDeleteCalendarCourse: { courseID in
                    guard let course = activeSchedule.courses.first(where: { $0.id == courseID }),
                          let firstDay = activeSchedule.firstDay else { return }
                    let relatedCourses = activeSchedule.courses.filter {
                        scheduleCourseIdentity($0) == scheduleCourseIdentity(course)
                    }
                    let drafts = ScheduleSystemCalendarEventBuilder.makeDrafts(
                        courses: relatedCourses,
                        firstDay: firstDay,
                        timeTable: activeSchedule.timeTable
                    )
                    Task {
                        do {
                            let result = try await ScheduleSystemCalendarManager.shared.deleteImportedEvents(drafts: drafts)
                            courseShareAlert = calendarMutationAlert(result)
                        } catch {
                            courseShareAlert = AppAlert(title: "移除日历失败", message: error.localizedDescription)
                        }
                    }
                },
                onImportExam: { examID in
                    guard let exam = activeSchedule.exams.first(where: { $0.id == examID }),
                          let draft = ScheduleSystemCalendarEventBuilder.makeDraft(for: exam) else {
                        courseShareAlert = AppAlert(title: "导入日历失败", message: "考试时间数据无法生成系统日历事件。")
                        return
                    }
                    Task {
                        do {
                            let count = try await ScheduleSystemCalendarManager.shared.importDrafts(
                                [draft],
                                term: activeSchedule.currentTerm
                            )
                            courseShareAlert = AppAlert.informational(
                                title: "已导入系统日历",
                                message: "已导入 \(count) 个日历事件。"
                            )
                        } catch {
                            courseShareAlert = AppAlert(title: "导入日历失败", message: error.localizedDescription)
                        }
                    }
                },
                onImportCustomSchedule: { scheduleID in
                    guard let schedule = activeSchedule.customSchedules.first(where: { $0.id == scheduleID }),
                          let draft = ScheduleSystemCalendarEventBuilder.makeDraft(for: schedule) else {
                        courseShareAlert = AppAlert(title: "导入日历失败", message: "自定义日程时间数据无法生成系统日历事件。")
                        return
                    }
                    Task {
                        do {
                            let count = try await ScheduleSystemCalendarManager.shared.importDrafts(
                                [draft],
                                term: activeSchedule.currentTerm
                            )
                            courseShareAlert = AppAlert.informational(
                                title: "已导入系统日历",
                                message: "已导入 \(count) 个日历事件。"
                            )
                        } catch {
                            courseShareAlert = AppAlert(title: "导入日历失败", message: error.localizedDescription)
                        }
                    }
                },
                onDeleteCalendarEntry: { markerID in
                    Task {
                        do {
                            let result = try await ScheduleSystemCalendarManager.shared.deleteImportedEvents(
                                markerIDs: Set([markerID])
                            )
                            courseShareAlert = calendarMutationAlert(result)
                        } catch {
                            courseShareAlert = AppAlert(title: "移除日历失败", message: error.localizedDescription)
                        }
                    }
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
                        editingCustomScheduleID = nil
                        isShowingEditSchedule = false
                    } catch {
                        presentSaveError(error)
                    }
                },
                onDismiss: {
                    editingCustomScheduleID = nil
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
                        presentSaveError(error)
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
                        presentSaveError(error)
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
        .diagnosticAlert(item: $courseShareAlert)
        .onChange(of: resetSignal) { _, _ in
            dismissPresentedSheets()
        }
    }


}

#if canImport(UIKit)
/// 读取当前 TabView 的真实底部栏重叠区域。
///
/// iOS 26 的 TabView 在 iPhone 上使用悬浮栏，系统 safe area 覆盖范围大于可见胶囊；
/// 课表高度使用系统栏实际 frame 计算，以保持不同平台的内容空间一致。
/// iPad / Mac 上底栏位于当前内容底部之外时返回 0，容器使用自身的自适应尺寸。
private struct ScheduleTabBarOverlapReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(onChange: onChange)
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onChange = onChange
        uiView.measure()
    }

    final class ProbeView: UIView {
        var onChange: (CGFloat) -> Void
        private var lastOverlap: CGFloat?

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            measure()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            measure()
        }

        func measure() {
            guard let window else { return }
            let overlap = bottomOverlap(with: window)
            guard lastOverlap.map({ abs($0 - overlap) < 0.5 }) != true else { return }
            lastOverlap = overlap
            DispatchQueue.main.async { [weak self] in
                self?.onChange(overlap)
            }
        }

        private func bottomOverlap(with window: UIWindow) -> CGFloat {
            guard let tabBar = findTabBarController(in: window.rootViewController)?.tabBar,
                  !tabBar.isHidden,
                  tabBar.window === window
            else { return 0 }

            let contentFrame = convert(bounds, to: window)
            let tabBarFrame = tabBar.convert(tabBar.bounds, to: window)
            guard tabBarFrame.minY >= contentFrame.minY,
                  tabBarFrame.minY < contentFrame.maxY,
                  tabBarFrame.maxX > contentFrame.minX,
                  tabBarFrame.minX < contentFrame.maxX
            else { return 0 }

            return max(contentFrame.maxY - tabBarFrame.minY, 0)
        }

        private func findTabBarController(in controller: UIViewController?) -> UITabBarController? {
            guard let controller else { return nil }
            if let tabBarController = controller as? UITabBarController {
                return tabBarController
            }
            if let presented = controller.presentedViewController,
               let tabBarController = findTabBarController(in: presented) {
                return tabBarController
            }
            for child in controller.children {
                if let tabBarController = findTabBarController(in: child) {
                    return tabBarController
                }
            }
            return nil
        }
    }
}
#endif
