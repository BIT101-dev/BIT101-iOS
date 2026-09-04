//
//  CourseScheduleTabView.swift
//  BIT101-iOS
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
    @State private var cardDisplayFeedbackToken = 0
    @State private var isShowingScheduleImport = false
    @State private var exportedSchedule: ScheduleCodePresentation?
    @State private var courseSharePresentation: CourseSharePresentation?
    @State private var courseShareAlert: AppAlert?
    @State private var isResolvingCourseShare = false
    @State private var prefetchedCourseID: String?
    @State private var prefetchedCourseResolution: ScheduleAcademicCourseResolution?
    @State private var bottomTabBarOverlap: CGFloat?

    var activeSchedule: ScheduleViewModel.CourseScheduleVariant {
        viewModel.activeCourseSchedule
    }

    private var supportsEditingDisplayedSchedule: Bool {
        activeSchedule.isPrimary
    }

    /// 课表分区主体。
    ///
    /// 课表页直接使用主 List 承载更新时间和表格两个 Section；不再嵌套一个只为
    /// 模拟原生圆角的更新时间 List。
    var body: some View {
        GeometryReader { proxy in
            let listHeight = max(
                proxy.size.height
                    - (bottomTabBarOverlap ?? 0),
                1
            )
            let calendarHeight = max(
                listHeight
                    - (activeSchedule.isPrimary ? AppDesignSystem.TopBar.statusListHeight : 0)
                    - (AppDesignSystem.TopBar.contentGap * 2),
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

                    // 学校尚未发布未来学期课表时，课程接口通常会正常返回空数组，而不是 404。
                    // 只要首周日期有效，就照常展示空课表网格和右下角操作按钮，不能让“无课程”
                    // 占位页挡住周次浏览、设置以及手动添加日程的入口。
                    if let firstDay = activeSchedule.firstDay {
                        Section {
                            CourseScheduleCalendarView(
                                entries: scheduleEntries,
                                week: viewModel.selectedWeek,
                                availableWeeks: weekPickerWeeks,
                                displayMode: viewModel.cache.scheduleDisplayMode,
                                cardContentMode: viewModel.cache.scheduleCardContentMode,
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
                            .frame(height: calendarHeight)
                            // 只让课表自身绘制白色分组背景；List 行背景不能延伸到悬浮 Tab 栏下方。
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(AppDesignSystem.Palette.groupedBackground)
                        }
                    } else {
                        Section {
                            VStack(spacing: AppDesignSystem.Spacing.section) {
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

    private var cardDisplayAccessibilityLabel: String {
        switch viewModel.cache.scheduleCardContentMode {
        case .nameAndLocation:
            return "显示课程名称和地点"
        case .name:
            return "显示课程名称"
        case .location:
            return "显示课程地点"
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

#if canImport(UIKit)
/// 读取当前 TabView 的真实底部栏重叠区域。
///
/// iOS 26 的 TabView 在 iPhone 上使用悬浮栏，系统 safe area 会比可见胶囊更保守；
/// 直接把 `safeAreaInsets.bottom` 当作课表高度扣除，会在不同平台产生过大的空白。
/// 这里读取系统栏实际 frame，不保存任何机型相关的高度常量；iPad / Mac 上如果底栏
/// 不在当前内容底部，返回 0，让容器继续使用自身的自适应尺寸。
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
