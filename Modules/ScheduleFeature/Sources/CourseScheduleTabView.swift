#if os(iOS)
import ScheduleDomain
import DesignSystemKit
//
//  CourseScheduleTabView.swift
//  BIT101-iOS
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private struct ScheduleRefreshStatusContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct CourseScheduleRefreshStatusRow: View {
    @ObservedObject var viewModel: ScheduleViewModel
    private var activeSchedule: ScheduleViewModel.CourseScheduleVariant { viewModel.activeCourseSchedule }
    var body: some View {
        refreshStatus
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("schedule.refresh-status")
    }
    @ViewBuilder private var refreshStatus: some View {
        if activeSchedule.isPrimary {
            AppRefreshStatusRow(
                isRefreshing: viewModel.isSyncingCourses,
                refreshingText: "正在刷新课表",
                lastUpdatedText: viewModel.coursesLastUpdatedText,
                actionTitle: "刷新",
                onRefresh: {
                    Task { await viewModel.syncSelectedTerm() }
                }
            )
        } else {
            AppRefreshStatusRow(
                isRefreshing: false,
                refreshingText: "",
                lastUpdatedText: activeSchedule.importedAt.map {
                    "导入时间：\($0.formatted(.dateTime.month().day().hour().minute()))"
                } ?? "分享课表",
                trailingText: "只读"
            )
        }
    }
}

struct CourseScheduleTabView: View {
    @Environment(\.appWindowLayout) private var layout
    @Environment(\.scheduleCurrentDate) private var currentDate
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
    let destinations: ScheduleDestinations
    @State var selectedEntry: ScheduleCalendarEntry?
    @State var editingCustomScheduleID: String?
    @State var selectedDayAdjustmentContext: ScheduleDayAdjustmentContext?
    @State var customScheduleDraft = CustomScheduleDraft()
    @State var courseDraft = CourseDraft()
    @State var dayAdjustmentDraft = ScheduleDayAdjustmentDraft()
    @State var isShowingEditSchedule = false
    @State var isShowingCourseEditor = false
    @State var courseEditorMode: CourseEditorMode = .add
    @State var isShowingScheduleImport = false
    @State private var isShowingAddContentMenu = false
    @State var exportedSchedule: ScheduleCodePresentation?
    @State var courseSharePresentation: CourseSharePresentation?
    @State var courseShareAlert: AppAlert?
    @State var isResolvingCourseShare = false
    @State var calendarMutationTask: Task<Void, Never>?
    @State var courseShareTask: Task<Void, Never>?
    @State var scheduleExportTask: Task<Void, Never>?
    @State var courseShareGeneration = 0
    @State var prefetchedCourseID: String?
    @State var prefetchedCourseResolution: ScheduleCourseShare?
    @State var bottomTabBarOverlap: CGFloat?
    @State var refreshStatusContentHeight = AppDesignSystem.Size.Control.touchTarget
    @AppStorage("schedule.calendar.axisMode") var storedCalendarAxisMode = ScheduleCalendarAxisMode.quantized.rawValue
    @State var calendarAxisZoomScale: CGFloat = AppDesignSystem.Schedule.timelineDefaultScale

    var activeSchedule: ScheduleViewModel.CourseScheduleVariant {
        viewModel.activeCourseSchedule
    }

    var calendarAxisMode: ScheduleCalendarAxisMode {
        ScheduleCalendarAxisMode(rawValue: storedCalendarAxisMode) ?? .quantized
    }

    var supportsEditingDisplayedSchedule: Bool {
        activeSchedule.isPrimary && viewModel.isCacheWritable
    }

    private var addContentMenu: some View {
        AppFloatingActionStack {
            if supportsEditingDisplayedSchedule {
                Button {
                    isShowingAddContentMenu = true
                } label: {
                    CourseScheduleFABLabel(systemImage: "plus")
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .accessibilityLabel("添加课表内容")
                .accessibilityIdentifier("schedule.add-content")
                .accessibilityAddTraits(.isButton)
                .appInteractiveListRow()
                .confirmationDialog(
                    "添加课表内容",
                    isPresented: $isShowingAddContentMenu,
                    titleVisibility: .hidden
                ) {
                    Button("添加日程") {
                        editingCustomScheduleID = nil
                        customScheduleDraft = viewModel.customScheduleDraft(for: nil)
                        isShowingEditSchedule = true
                    }
                    .accessibilityIdentifier("schedule.add-custom")

                    Button("添加课程") {
                        courseEditorMode = .add
                        courseDraft = viewModel.courseDraft(for: viewModel.selectedWeek)
                        isShowingCourseEditor = true
                    }
                }
            }
        }
        .padding(.bottom, layout.usesBottomTabBar ? AppDesignSystem.Spacing.none : layout.safeAreaInsets.bottom)
    }

    @ViewBuilder
    private func calendarSurface(height: CGFloat) -> some View {
        if let firstDay = activeSchedule.firstDay {
            ZStack(alignment: .bottomTrailing) {
                CourseScheduleCalendarView(
                    entries: scheduleEntries,
                    week: viewModel.selectedWeek,
                    availableWeeks: weekPickerWeeks,
                    displayMode: viewModel.presentationPreferences.scheduleDisplayMode,
                    cardContentMode: viewModel.presentationPreferences.scheduleCardContentMode,
                    axisMode: calendarAxisMode,
                    axisZoomScale: $calendarAxisZoomScale,
                    firstDay: firstDay,
                    timeTable: activeSchedule.timeTable,
                    currentWeek: resolvedCurrentWeek(firstDay: firstDay, now: currentDate),
                    showSaturday: viewModel.presentationPreferences.showSaturday,
                    showSunday: viewModel.presentationPreferences.showSunday,
                    onSelect: { entry in
                        selectedEntry = entry
                    },
                    onSelectDay: { date, weekday in
                        guard viewModel.presentationPreferences.scheduleDisplayMode == .weekly else { return }
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
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("schedule.calendar")
                addContentMenu
            }
            .frame(height: height)
        } else {
            ZStack(alignment: .bottomTrailing) {
                AppEmptyState(
                    title: activeSchedule.isPrimary ? "暂无课表" : "分享课表缺少起始日期",
                    systemImage: "calendar",
                    message: activeSchedule.isPrimary
                        ? "点击上方刷新获取学校课表，也可手动添加日程。"
                        : "试试上下滑切换到别的课表，或重新导入一份分享课表。"
                )
                .padding(.horizontal, AppDesignSystem.Spacing.content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                addContentMenu
            }
            .frame(height: height)
        }
    }

    /// 课表分区主体。
    ///
    /// 更新时间沿模块分组行展示，横屏表格按所属分栏的可用高度铺开。
    var body: some View {
        GeometryReader { proxy in
            let listHeight = max(
                proxy.size.height
                    - (bottomTabBarOverlap ?? 0),
                1
            )
            let scheduleSectionGap = AppDesignSystem.Spacing.content
            let usesLandscapeCalendar = layout.isLandscapeWindow && !layout.usesAccessibilityText
            let refreshStatusHeight = AppDesignSystem.Schedule.refreshStatusRowHeight(
                contentHeight: refreshStatusContentHeight
            )
            let calendarHeight = max(
                listHeight
                    - refreshStatusHeight
                    - scheduleSectionGap
                    - (usesLandscapeCalendar || !layout.usesBottomTabBar ? AppDesignSystem.Spacing.none : scheduleSectionGap),
                1
            )

            ZStack(alignment: .bottomTrailing) {
                if usesLandscapeCalendar {
                    VStack(spacing: AppDesignSystem.Spacing.content) {
                        List { refreshStatusSection }
                            .accessibilityIdentifier("interaction.CourseScheduleTabView.refresh")
                            .appGroupedListStyle()
                            .scrollContentBackground(.hidden)
                            .scrollDisabled(true)
                            .frame(height: refreshStatusHeight)
                        calendarSurface(height: calendarHeight)
                            .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.grouped))
                            .padding(.horizontal, AppDesignSystem.Spacing.section)
                    }
                    .onPreferenceChange(ScheduleRefreshStatusContentHeightKey.self) { height in
                        guard height > 0 else { return }
                        refreshStatusContentHeight = max(height, AppDesignSystem.Size.Control.touchTarget)
                    }
                } else {
                    List {
                        refreshStatusSection

                        // 学校尚未发布未来学期课表时，课程接口通常正常返回空数组。
                        // 首周日期有效时，页面展示空课表网格和右下角操作按钮，周次浏览以及
                        // 手动添加日程入口保持可用。
                        Section {
                            calendarSurface(height: calendarHeight)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(AppDesignSystem.Palette.Background.grouped)
                        }
                    }
                    .accessibilityIdentifier("interaction.CourseScheduleTabView.list")
                    .appGroupedListStyle()
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(calendarAxisMode == .quantized || activeSchedule.firstDay != nil)
                    .frame(height: listHeight, alignment: .top)
                    .zIndex(0)
                    .onPreferenceChange(ScheduleRefreshStatusContentHeightKey.self) { height in
                        guard height > 0 else { return }
                        refreshStatusContentHeight = max(height, AppDesignSystem.Size.Control.touchTarget)
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
        .ignoresSafeArea(.container, edges: layout.usesBottomTabBar ? [] : .bottom)
        .simultaneousGesture(scheduleSwitchGesture)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schedule.variant-surface")
        .sheet(item: $selectedEntry, onDismiss: {
            if editingCustomScheduleID != nil {
                isShowingEditSchedule = true
            }
        }) { entry in
            ScheduleEntryDetailSheet(
                entry: entry,
                academicCourses: {
                    let displayedCourses = entry.resolvedSourceIDs.compactMap { sourceID in
                        activeSchedule.courses.first(where: { $0.id == sourceID })
                    }
                    let identities = Set(displayedCourses.map(scheduleCourseIdentity))
                    return activeSchedule.courses.filter { identities.contains(scheduleCourseIdentity($0)) }
                }(),
                currentWeek: viewModel.selectedWeek,
                currentTerm: activeSchedule.currentTerm,
                allowsCourseMutation: supportsEditingDisplayedSchedule,
                allowsCustomScheduleMutation: supportsEditingDisplayedSchedule,
                destinations: destinations,
                timeTable: viewModel.courseState.timeTable,
                buildings: viewModel.courseArrangementBuildings,
                courseArrangementDraftsForCourse: { courseID in
                    viewModel.courseArrangementDrafts(forCourseID: courseID)
                },
                courseArrangementDraftForOccurrence: { courseID, week in
                    guard let course = activeSchedule.courses.first(where: { $0.id == courseID }) else {
                        return nil
                    }
                    return viewModel.courseArrangementDraft(for: course, week: week)
                },
                onSaveCourseArrangements: { arrangements, mode in
                    do {
                        switch mode {
                        case .course:
                            try viewModel.updateCourseArrangements(arrangements)
                        case .occurrence:
                            guard let arrangement = arrangements.first,
                                  let weeks = try? ScheduleCourseEditor.parseWeeks(arrangement.draft.weeksText)
                            else {
                                throw viewModel.scheduleValidationError("至少选择一周课程。")
                            }
                            try viewModel.updateCourseOccurrences(
                                id: arrangement.id,
                                weeks: weeks,
                                draft: arrangement.draft
                            )
                        }
                        return true
                    } catch {
                        presentSaveError(error)
                        return false
                    }
                },
                onDeleteCourseOccurrence: { courseID, week in
                    guard let course = activeSchedule.courses.first(where: { $0.id == courseID }) else { return }
                    do {
                        try viewModel.deleteCourseOccurrence(id: course.id, week: week)
                        selectedEntry = nil
                    } catch { presentSaveError(error) }
                },
                onDeleteCourse: { courseID in
                    do {
                        try viewModel.deleteCourse(id: courseID)
                        selectedEntry = nil
                    } catch { presentSaveError(error) }
                },
                onImportCourseOccurrence: { courseID, week in
                    guard let content = calendarCourseContent(courseID: courseID, week: week) else { return }
                    importCalendarEntries(content, term: activeSchedule.currentTerm)
                },
                onImportCourse: { courseID in
                    guard let content = calendarCourseContent(courseID: courseID) else { return }
                    importCalendarEntries(content, term: activeSchedule.currentTerm)
                },
                onDeleteCalendarMarkers: { markerIDs, term in
                    deleteCalendarEntries(markerIDs: markerIDs, term: term)
                },
                onDeleteCalendarCourse: { courseID, term in
                    guard let content = calendarCourseContent(courseID: courseID) else { return }
                    deleteCalendarEntries(content, term: term)
                },
                onImportExam: { examID in
                    guard let exam = activeSchedule.exams.first(where: { $0.id == examID }) else { return }
                    importCalendarEntries(.exam(exam), term: activeSchedule.currentTerm)
                },
                onImportCustomSchedule: { scheduleID in
                    guard let schedule = activeSchedule.customSchedules.first(where: { $0.id == scheduleID }) else { return }
                    importCalendarEntries(.customSchedule(schedule), term: activeSchedule.currentTerm)
                },
                onDeleteCalendarEntry: { markerID, term in
                    if entry.kind == .custom,
                       let schedule = activeSchedule.customSchedules.first(where: { $0.id == entry.sourceID }) {
                        deleteCalendarEntries(.customSchedule(schedule), term: term)
                    } else {
                        deleteCalendarEntries(markerIDs: Set([markerID]), term: term)
                    }
                },
                onEditCustomSchedule: {
                    if let schedule = viewModel.courseState.customSchedules.first(where: { $0.id == entry.sourceID }) {
                        editingCustomScheduleID = schedule.id
                        customScheduleDraft = viewModel.customScheduleDraft(for: schedule)
                    }
                },
                onDeleteCustomSchedule: {
                    do {
                        try viewModel.deleteCustomSchedule(id: entry.sourceID)
                        selectedEntry = nil
                    } catch { presentSaveError(error) }
                }
            )
        }
        .sheet(isPresented: $isShowingEditSchedule) {
            AddEditCustomScheduleSheet(
                draft: $customScheduleDraft,
                firstDay: activeSchedule.firstDay,
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
                timeTable: viewModel.courseState.timeTable,
                onSubmit: {
                    do {
                        try viewModel.addCourse(courseDraft)
                        isShowingCourseEditor = false
                    } catch {
                        presentSaveError(error)
                    }
                },
                onDismiss: {
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
                            try viewModel.clearCourses(week: context.week, weekday: context.weekday)
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
                appStoreURL: destinations.appStoreURL,
                onImport: { text in
                    try await importScheduleCode(text)
                }
            )
        }
        .diagnosticAlert(item: $courseShareAlert)
        .task(id: prefetchedCourseID) { await resolvePreparedCourseShare() }
        .onAppear { consumeSystemCalendarRequest() }
        .onChange(of: viewModel.requestedSystemCalendarEvent) { _, _ in consumeSystemCalendarRequest() }
        .onDisappear { cancelPendingActions() }
        .onChange(of: viewModel.accountGeneration) { _, _ in
            dismissPresentedSheets()
        }
        .onChange(of: resetSignal) { _, _ in
            dismissPresentedSheets()
        }
    }

    private var refreshStatusSection: some View {
        Section {
            CourseScheduleRefreshStatusRow(viewModel: viewModel)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ScheduleRefreshStatusContentHeightKey.self, value: proxy.size.height)
                    }
                }
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

        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); measure() }

        func measure() {
            guard let window else { return }
            let overlap = bottomOverlap(with: window)
            guard lastOverlap.map({ abs($0 - overlap) < 0.5 }) != true else { return }
            lastOverlap = overlap
            Task { @MainActor [weak self] in
                guard let self, lastOverlap == overlap else { return }
                onChange(overlap)
            }
        }

        private func bottomOverlap(with window: UIWindow) -> CGFloat {
            guard let tabBar = findTabBarController(in: window.rootViewController)?.tabBar,
                  !tabBar.isHidden,
                  tabBar.window === window
            else { return 0 }

            let contentFrame = convert(bounds, to: window)
            let tabBarFrame = tabBar.convert(tabBar.bounds, to: window)
            return ScheduleTabBarGeometry.bottomOverlap(content: contentFrame, tabBar: tabBarFrame)
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

#endif
