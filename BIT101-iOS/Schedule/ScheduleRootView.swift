//
//  ScheduleRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI
import UIKit

// MARK: - Schedule Root

/// 统一压缩教室名称里的冗长楼名，提升课表卡片可读性。
private func normalizeDisplayedClassroom(_ value: String) -> String {
    ScheduleDisplayNormalizer.normalizeClassroom(value)
}

/// 对课程标题做本地展示优化。
///
/// 目前主要把 `体育/xx` 压缩成 `xx`。
private func normalizeDisplayedCourseTitle(_ value: String) -> String {
    ScheduleDisplayNormalizer.normalizeCourseTitle(value)
}

/// 日程页根视图。
///
/// 顶部是系统 segmented，正文按当前分区单独渲染。
/// 这样能避免分页容器影响底部玻璃效果，同时保留轻扫切换体验。
struct ScheduleRootView: View {
    /// 壳层深链请求的目标分栏，例如从小组件点进来直接落到课表。
    @Binding var requestedSection: ScheduleSection?
    @StateObject private var viewModel = ScheduleViewModel()
    @State private var courseTabResetSignal = 0

    /// 日程主页主体。
    var body: some View {
        VStack(spacing: 0) {
            ScheduleSectionTabs(
                selectedSection: $viewModel.selectedSection,
                courseTitle: viewModel.activeCourseScheduleTitle
            )
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 8)

            ZStack {
                selectedSectionView
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .simultaneousGesture(sectionSwitchGesture)
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await viewModel.loadIfNeeded()
        }
        .onChange(of: viewModel.selectedSection) { _, section in
            if section == .classroom {
                Task {
                    await viewModel.prepareClassroomIfNeeded()
                }
            }
        }
        .onAppear {
            consumeRequestedSectionIfNeeded()
        }
        .onChange(of: requestedSection) { _, _ in
            consumeRequestedSectionIfNeeded()
        }
        .alert(item: $viewModel.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .sheet(
            item: Binding(
                get: { viewModel.smsChallenge },
                set: { challenge in
                    if challenge == nil {
                        viewModel.dismissSMSChallenge()
                    }
                }
            )
        ) { challenge in
            ScheduleSMSVerificationSheet(
                challenge: challenge,
                isSubmitting: viewModel.isSubmittingSMSCode,
                errorMessage: viewModel.smsVerificationError,
                onCancel: viewModel.dismissSMSChallenge,
                onSubmit: { code in
                    await viewModel.submitSMSCode(code)
                }
            )
        }
    }

    /// 根据当前分区切换渲染不同内容页。
    @ViewBuilder
    private var selectedSectionView: some View {
        switch viewModel.selectedSection {
        case .courses:
            CourseScheduleTabView(
                viewModel: viewModel,
                resetSignal: courseTabResetSignal
            )
        case .ddl:
            DDLScheduleTabView(viewModel: viewModel)
        case .classroom:
            FreeClassroomTabView(viewModel: viewModel)
        }
    }

    /// 轻扫切换课表 / DDL / 空教室的手势。
    ///
    /// 与话廊页保持同一套交互语义：顶部 segmented 可点，正文支持横向轻扫切换。
    private var sectionSwitchGesture: some Gesture {
        makeHorizontalSwitchGesture(onStep: switchSection)
    }

    /// 根据方向切换一级分区。
    private func switchSection(step: Int) {
        let allSections = ScheduleSection.allCases
        guard let currentIndex = allSections.firstIndex(of: viewModel.selectedSection) else { return }

        let nextIndex = currentIndex + step
        guard allSections.indices.contains(nextIndex) else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.selectedSection = allSections[nextIndex]
        }
    }

    /// 消费来自 App 壳层的深链跳转请求。
    private func consumeRequestedSectionIfNeeded() {
        guard let requestedSection else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.selectedSection = requestedSection
            if requestedSection == .courses {
                // 从小组件、锁屏组件或灵动岛回到课表时，发一个“回首页”信号，
                // 让课表分栏按正常 dismiss 路径收起当前 sheet。
                courseTabResetSignal &+= 1
                viewModel.resetToCurrentWeek()
            }
        }

        self.requestedSection = nil
    }
}

/// 顶部胶囊切换条。
///
/// 保持成单独子视图后，根视图可以专注处理路由和副作用，而不是把 segmented 样式细节塞在一起。
private struct ScheduleSectionTabs: View {
    @Binding var selectedSection: ScheduleSection
    let courseTitle: String

    /// 日程页顶部原生分段控件。
    var body: some View {
        Picker("日程模块", selection: $selectedSection) {
            Text(courseTitle).tag(ScheduleSection.courses)
            Text(ScheduleSection.ddl.title).tag(ScheduleSection.ddl)
            Text(ScheduleSection.classroom.title).tag(ScheduleSection.classroom)
        }
        .pickerStyle(.segmented)
    }
}

/// 课表分页。
///
/// 负责周视图课表、悬浮操作按钮、自定义日程编辑以及跳转到共享设置中心。
private struct CourseScheduleTabView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    let resetSignal: Int
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

    private var activeSchedule: ScheduleViewModel.CourseScheduleVariant {
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
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 10)

                        VStack(spacing: 10) {
                            CourseScheduleFAB(systemImage: "chevron.up") {
                                viewModel.previousWeek()
                            }

                            CourseScheduleFAB(systemImage: "chevron.down") {
                                viewModel.nextWeek()
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
                            }

                            CourseScheduleFAB(systemImage: "gearshape") {
                                settingsRoute = .calendar
                            }
                        }
                        .padding(.trailing, 10)
                        .padding(.bottom, 20)
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
                currentWeek: viewModel.selectedWeek,
                timeTable: activeSchedule.timeTable,
                allowsCourseMutation: supportsEditingDisplayedSchedule,
                allowsCustomScheduleMutation: supportsEditingDisplayedSchedule,
                onEditCourseOccurrence: {
                    guard let course = viewModel.cache.courses.first(where: { $0.id == entry.sourceID }) else { return }
                    editingCourseID = course.id
                    courseEditorMode = .editOccurrence(week: viewModel.selectedWeek)
                    courseDraft = viewModel.courseDraft(for: course, week: viewModel.selectedWeek, editsOccurrenceOnly: true)
                    selectedEntry = nil
                    isShowingCourseEditor = true
                },
                onEditCourse: {
                    guard let course = viewModel.cache.courses.first(where: { $0.id == entry.sourceID }) else { return }
                    editingCourseID = course.id
                    courseEditorMode = .editCourse(courseID: course.id)
                    courseDraft = viewModel.courseDraft(for: course, week: viewModel.selectedWeek, editsOccurrenceOnly: false)
                    selectedEntry = nil
                    isShowingCourseEditor = true
                },
                onDeleteCourseOccurrence: {
                    viewModel.deleteCourseOccurrence(id: entry.sourceID, week: viewModel.selectedWeek)
                    selectedEntry = nil
                },
                onDeleteCourse: {
                    viewModel.deleteCourse(id: entry.sourceID)
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
        .sheet(item: $settingsRoute) { route in
            NavigationStack {
                SettingsRootView(initialRoute: route, studentID: "", onLogout: {}, showsCloseButton: true)
            }
        }
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
        editingCustomScheduleID = nil
        editingCourseID = nil
        selectedDayAdjustmentContext = nil
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

                if vertical < 0 {
                    viewModel.cycleCourseSchedule(step: 1)
                } else {
                    viewModel.cycleCourseSchedule(step: -1)
                }
            }
    }

    private var scheduleEntries: [ScheduleCalendarEntry] {
        guard let firstDay = activeSchedule.firstDay else {
            return []
        }

        // 课表网格只关心当前周，所以先把课程、考试和自定义日程全部压平成同一套日历块模型。
        let weekStart = Calendar.current.date(
            byAdding: .day,
            value: ScheduleWeekCodec.weekOffset(forWeekNumber: viewModel.selectedWeek) * 7,
            to: firstDay
        ) ?? firstDay
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart

        let courseEntries = activeSchedule.courses
            .filter { $0.weeks.contains(viewModel.selectedWeek) }
            .map {
                ScheduleCalendarEntry(
                    id: "course-\($0.id)",
                    sourceID: $0.id,
                    dayOfWeek: $0.weekday,
                    startSection: CGFloat($0.startSection - 1),
                    endSection: CGFloat($0.endSection),
                    title: normalizeDisplayedCourseTitle($0.name),
                    subtitle: normalizeDisplayedClassroom($0.classroom),
                    detailLines: [
                        $0.teacher.isEmpty ? nil : "教师：\($0.teacher)",
                        $0.classroom.isEmpty ? nil : "教室：\(normalizeDisplayedClassroom($0.classroom))",
                        "学分：\($0.credit > 0 ? String($0.credit) : "-")",
                        "节次：\($0.sectionText)",
                        $0.description.isEmpty ? nil : $0.description,
                    ].compactMap { $0 },
                    kind: .course
                )
            }

        let examEntries = viewModel.cache.showExamInfo ? activeSchedule.exams.compactMap { exam -> ScheduleCalendarEntry? in
            guard
                let examDate = ScheduleDateCodec.parseDate(exam.dateString),
                examDate >= weekStart,
                examDate < weekEnd
            else {
                return nil
            }

            let weekday = ScheduleDateCodec.weekdayIndex(from: examDate)
            let startSection = convertTimeToSection(timeText: exam.beginTime, timeTable: activeSchedule.timeTable)
            let endSection = convertTimeToSection(timeText: exam.endTime, timeTable: activeSchedule.timeTable)

            guard endSection > startSection + 0.05 else {
                return nil
            }

            return ScheduleCalendarEntry(
                id: "exam-\(exam.id)",
                sourceID: exam.id,
                dayOfWeek: weekday,
                startSection: startSection,
                endSection: endSection,
                title: "(考试)\n\(exam.name)",
                subtitle: normalizeDisplayedClassroom(exam.classroom),
                detailLines: [
                    exam.teacher.isEmpty ? nil : "教师：\(exam.teacher)",
                    exam.classroom.isEmpty ? nil : "教室：\(normalizeDisplayedClassroom(exam.classroom))",
                    exam.examMode.isEmpty ? nil : "形式：\(exam.examMode)",
                    (exam.beginTime.isEmpty || exam.endTime.isEmpty) ? nil : "时间：\(exam.beginTime)-\(exam.endTime)",
                    exam.seatID.isEmpty ? nil : "座位号：\(exam.seatID)",
                ].compactMap { $0 },
                kind: .exam
            )
        } : []

        let customEntries = activeSchedule.customSchedules.compactMap { schedule -> ScheduleCalendarEntry? in
            guard
                let date = ScheduleDateCodec.parseDate(schedule.dateString),
                date >= weekStart,
                date < weekEnd
            else {
                return nil
            }

            let weekday = ScheduleDateCodec.weekdayIndex(from: date)
            let startSection = convertTimeToSection(timeText: schedule.beginTime, timeTable: activeSchedule.timeTable)
            let endSection = convertTimeToSection(timeText: schedule.endTime, timeTable: activeSchedule.timeTable)
            guard endSection > startSection + 0.05 else {
                return nil
            }

            return ScheduleCalendarEntry(
                id: "custom-\(schedule.id)",
                sourceID: schedule.id,
                dayOfWeek: weekday,
                startSection: startSection,
                endSection: endSection,
                title: schedule.title,
                subtitle: schedule.subtitle,
                detailLines: [
                    schedule.subtitle.isEmpty ? nil : "副标题：\(schedule.subtitle)",
                    schedule.description.isEmpty ? nil : "描述：\(schedule.description)",
                    "日期：\(schedule.dateString)",
                    "时间：\(schedule.beginTime)-\(schedule.endTime)",
                ].compactMap { $0 },
                kind: .custom
            )
        }

        return normalize(entries: courseEntries + examEntries + customEntries)
    }
}

private enum CourseEditorMode: Equatable {
    case add
    case editOccurrence(week: Int)
    case editCourse(courseID: String)

    var title: String {
        switch self {
        case .add:
            return "添加课程"
        case .editOccurrence:
            return "调这节课"
        case .editCourse:
            return "调这门课"
        }
    }

    var locksWeeks: Bool {
        if case .editOccurrence = self {
            return true
        }
        return false
    }

    var fixedWeek: Int? {
        if case let .editOccurrence(week) = self {
            return week
        }
        return nil
    }

    var footerText: String {
        switch self {
        case .add:
            return "添加的课程会存储在本地；删除应用后信息将丢失。"
        case let .editOccurrence(week):
            return "这次只会修改第\(week)周这一节课，系统会把它从原课程里拆出来单独保存。"
        case .editCourse:
            return "这会修改这门课在所选周次内的统一排课信息。"
        }
    }
}

/// 点击课表顶部日期后进入的日期调整上下文。
private struct ScheduleDayAdjustmentContext: Identifiable {
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M.d"
        return formatter
    }()

    let date: Date
    let week: Int
    let weekday: Int

    var id: String {
        "\(week)-\(weekday)-\(ScheduleDateCodec.formatDate(date))"
    }

    var shortTitle: String {
        "\(weekdayText) \(Self.shortDateFormatter.string(from: date))"
    }

    var fullDateText: String {
        "\(ScheduleDateCodec.formatDate(date))（\(weekdayText)）"
    }

    private var weekdayText: String {
        let titles = ["一", "二", "三", "四", "五", "六", "日"]
        guard (1 ... titles.count).contains(weekday) else { return "?" }
        return "周\(titles[weekday - 1])"
    }
}

/// 单日课表调整模式。
private enum ScheduleDayAdjustmentMode: String, CaseIterable, Identifiable {
    case holiday
    case transfer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holiday:
            return "放假"
        case .transfer:
            return "调至某天"
        }
    }
}

/// 单日课表调整草稿。
private struct ScheduleDayAdjustmentDraft: Equatable {
    var mode: ScheduleDayAdjustmentMode = .holiday
    var targetDate = Date()
}

/// 放假 / 调休调整页。
private struct DayAdjustmentSheet: View {
    let context: ScheduleDayAdjustmentContext
    @Binding var draft: ScheduleDayAdjustmentDraft
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    @State private var pendingConfirmation: PendingDayAdjustmentConfirmation?

    var body: some View {
        NavigationStack {
            Form {
                Section("日期") {
                    LabeledContent("当前日期", value: context.fullDateText)
                    LabeledContent("当前周次", value: "第\(context.week)周")
                }

                Section("操作") {
                    Picker("类型", selection: $draft.mode) {
                        ForEach(ScheduleDayAdjustmentMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if draft.mode == .transfer {
                        DatePicker("调至", selection: $draft.targetDate, displayedComponents: .date)
                    }
                }

                Section {
                    Text(footerText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("调休 / 放假")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onDismiss)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定") {
                        pendingConfirmation = PendingDayAdjustmentConfirmation(
                            mode: draft.mode,
                            sourceDateText: context.fullDateText,
                            targetDateText: ScheduleDateCodec.formatDate(draft.targetDate)
                        )
                    }
                }
            }
            .alert(item: $pendingConfirmation) { confirmation in
                Alert(
                    title: Text(confirmation.title),
                    message: Text(confirmation.message),
                    primaryButton: .destructive(Text("确定")) {
                        onSubmit()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
    }

    private var footerText: String {
        switch draft.mode {
        case .holiday:
            return "放假会清空这一天的课程；考试和自定义日程不会被删除。"
        case .transfer:
            return "调课会先清空当前日期的课程，再把这些课程移动到目标日期；如果目标日期已有课程，将被覆盖。"
        }
    }

    private struct PendingDayAdjustmentConfirmation: Identifiable {
        let id = UUID()
        let mode: ScheduleDayAdjustmentMode
        let sourceDateText: String
        let targetDateText: String

        var title: String {
            switch mode {
            case .holiday:
                return "确认放假"
            case .transfer:
                return "确认调课"
            }
        }

        var message: String {
            switch mode {
            case .holiday:
                return "这会清空 \(sourceDateText) 的课程。"
            case .transfer:
                return "这会清空 \(sourceDateText) 的课程，并调至 \(targetDateText)。如果目标日期已有课程，将被覆盖。"
            }
        }
    }
}

/// 周课表大网格。
///
/// 这里是一个完全自绘的课表网格，而不是 `LazyVGrid` 套组件，原因是：
/// - 需要精确控制节次高度
/// - 需要叠加当前时间线
/// - 需要把课程、考试、自定义日程放到同一坐标系里
private struct CourseScheduleCalendarView: View {
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M.d"
        return formatter
    }()
    private static let weekdayTitles = ["一", "二", "三", "四", "五", "六", "七"]

    let entries: [ScheduleCalendarEntry]
    let week: Int
    let firstDay: Date
    let timeTable: [TimeSlot]
    let currentWeek: Int
    let showSaturday: Bool
    let showSunday: Bool
    let showHighlightToday: Bool
    let showDivider: Bool
    let showCurrentTime: Bool
    let showBorder: Bool
    let onSelect: (ScheduleCalendarEntry) -> Void
    let onSelectDay: (Date, Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let leftWidth: CGFloat = 50
            let headerHeight: CGFloat = 42
            let usableHeight = max(proxy.size.height - headerHeight, 1)
            let rowHeight = usableHeight / CGFloat(max(timeTable.count, 1))
            let visibleWeekdays = (1 ... 7).filter {
                if $0 == 6 { return showSaturday }
                if $0 == 7 { return showSunday }
                return true
            }
            let dayWidth = max((proxy.size.width - leftWidth) / CGFloat(max(visibleWeekdays.count, 1)), 1)
            let weekDates = visibleWeekdays.compactMap {
                Calendar.current.date(
                    byAdding: .day,
                    value: ($0 - 1) + ScheduleWeekCodec.weekOffset(forWeekNumber: week) * 7,
                    to: firstDay
                )
            }
            let highlightWeekday = (currentWeek == week && showHighlightToday) ? ScheduleDateCodec.weekdayIndex(from: Date()) : nil
            let timeLineSection = (currentWeek == week && showCurrentTime) ? convertTimeToSection(timeText: currentTimeText(), timeTable: timeTable) : nil

            ZStack(alignment: .topLeading) {
                if let highlightWeekday, visibleWeekdays.contains(highlightWeekday), let index = visibleWeekdays.firstIndex(of: highlightWeekday) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.10))
                        .frame(width: dayWidth, height: usableHeight)
                        .offset(x: leftWidth + dayWidth * CGFloat(index), y: headerHeight)
                }

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        VStack(spacing: 1) {
                            Text("\(week)")
                            Text("周")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: leftWidth, height: headerHeight)
                        .background(Color(.secondarySystemBackground))

                        ForEach(Array(weekDates.enumerated()), id: \.offset) { index, date in
                            Button {
                                onSelectDay(date, visibleWeekdays[index])
                            } label: {
                                VStack(spacing: 2) {
                                    Text(weekdayText(for: visibleWeekdays[index]))
                                    Text(mmddText(for: date))
                                }
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .frame(width: dayWidth, height: headerHeight)
                                .background(Color(.secondarySystemBackground))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ForEach(Array(timeTable.enumerated()), id: \.offset) { index, slot in
                        HStack(spacing: 0) {
                            VStack(spacing: 1) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                Text(slot.start)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: leftWidth, height: rowHeight)

                            ForEach(visibleWeekdays, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(width: dayWidth, height: rowHeight)
                            }
                        }
                    }
                }

                if showDivider {
                    ForEach(0 ... timeTable.count, id: \.self) { row in
                        Rectangle()
                            .fill(Color.secondary.opacity(row == 0 ? 0.18 : 0.12))
                            .frame(height: 0.5)
                            .offset(y: headerHeight + rowHeight * CGFloat(row))
                    }
                }

                ForEach(0 ... visibleWeekdays.count, id: \.self) { column in
                    Rectangle()
                        .fill(Color.secondary.opacity(column == 0 ? 0.18 : 0.12))
                        .frame(width: 0.5, height: proxy.size.height)
                        .offset(x: leftWidth + dayWidth * CGFloat(column))
                }

                if let timeLineSection,
                   timeLineSection > 0,
                   timeLineSection < CGFloat(timeTable.count),
                   let highlightWeekday,
                   visibleWeekdays.contains(highlightWeekday),
                   let index = visibleWeekdays.firstIndex(of: highlightWeekday) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: dayWidth, height: 1.5)
                        .offset(
                            x: leftWidth + dayWidth * CGFloat(index),
                            y: headerHeight + rowHeight * timeLineSection
                        )
                }

                ForEach(entries.filter { visibleWeekdays.contains($0.dayOfWeek) }) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        CourseScheduleBlockView(entry: entry, showBorder: showBorder)
                    }
                    .buttonStyle(.plain)
                    .frame(
                        width: max(dayWidth - 4, 1),
                        height: max(rowHeight * (entry.endSection - entry.startSection) - 4, 1)
                    )
                    .offset(
                        x: leftWidth + dayWidth * CGFloat(visibleWeekdays.firstIndex(of: entry.dayOfWeek) ?? 0) + 2,
                        y: headerHeight + rowHeight * entry.startSection + 2
                    )
                }
            }
            .clipped()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func mmddText(for date: Date) -> String {
        Self.monthDayFormatter.string(from: date)
    }

    private func weekdayText(for weekday: Int) -> String {
        guard (1 ... Self.weekdayTitles.count).contains(weekday) else {
            return "?"
        }
        return Self.weekdayTitles[weekday - 1]
    }

    private func currentTimeText() -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

/// 课表中的单个课程 / 考试 / 自定义日程块。
private struct CourseScheduleBlockView: View {
    let entry: ScheduleCalendarEntry
    let showBorder: Bool

    var body: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)

            Text(entry.title)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.75)
                .foregroundStyle(textColor)

            Spacer(minLength: 0)

            Text(entry.subtitle)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if showBorder {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.8)
            }
        }
    }

    private var backgroundColor: Color {
        switch entry.kind {
        case .course:
            return Color(uiColor: .secondarySystemFill).opacity(0.95)
        case .exam:
            return Color.orange.opacity(0.22)
        case .custom:
            return Color.blue.opacity(0.18)
        }
    }

    private var borderColor: Color {
        switch entry.kind {
        case .course:
            return Color.secondary.opacity(0.25)
        case .exam:
            return Color.orange.opacity(0.35)
        case .custom:
            return Color.blue.opacity(0.30)
        }
    }

    private var textColor: Color {
        switch entry.kind {
        case .course:
            return .primary
        case .exam:
            return .orange
        case .custom:
            return .blue
        }
    }
}

/// 右下角悬浮按钮。
private struct CourseScheduleFAB: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CourseScheduleFABLabel(systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

/// 课表页悬浮圆形按钮的统一外观。
///
/// 单独抽出来后，`Button` 和 `Menu` 可以共用同一套视觉样式，
/// 避免“添加”按钮因为交互容器不同而出现尺寸或命中区域错位。
private struct CourseScheduleFABLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
            .contentShape(Circle())
    }
}

/// 课表网格内部统一使用的条目类型。
///
/// 课程、考试、自定义日程最终都会投影成同一种“日历块”，但颜色和详情逻辑不同。
private enum ScheduleCalendarKind {
    case course
    case exam
    case custom
}

/// 供课表网格渲染的统一条目模型。
///
/// 这是课表 UI 层内部使用的适配模型，不直接持久化。
private struct ScheduleCalendarEntry: Identifiable {
    let id: String
    let sourceID: String
    let dayOfWeek: Int
    let startSection: CGFloat
    let endSection: CGFloat
    let title: String
    let subtitle: String
    let detailLines: [String]
    let kind: ScheduleCalendarKind
}

/// 课表条目详情。
///
/// 课表块点击后的二级详情页，兼容课程、考试和自定义日程三种来源。
private struct ScheduleEntryDetailSheet: View {
    let entry: ScheduleCalendarEntry
    let currentWeek: Int
    let timeTable: [TimeSlot]
    let allowsCourseMutation: Bool
    let allowsCustomScheduleMutation: Bool
    let onEditCourseOccurrence: () -> Void
    let onEditCourse: () -> Void
    let onDeleteCourseOccurrence: () -> Void
    let onDeleteCourse: () -> Void
    let onEditCustomSchedule: () -> Void
    let onDeleteCustomSchedule: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingCourseDeletion: PendingCourseDeletion?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(entry.title)
                        .font(.headline)
                    if !entry.subtitle.isEmpty {
                        Text(entry.subtitle)
                            .foregroundStyle(.secondary)
                    }
                }

                if !entry.detailLines.isEmpty {
                    Section("详情") {
                        ForEach(entry.detailLines, id: \.self) { line in
                            Text(line)
                        }
                    }
                }

                if entry.kind == .course, allowsCourseMutation {
                    Section {
                        Button("调这节课") {
                            dismiss()
                            onEditCourseOccurrence()
                        }
                        Button("调这门课") {
                            dismiss()
                            onEditCourse()
                        }
                    }

                    Section {
                        Button("删除这节课", role: .destructive) {
                            pendingCourseDeletion = .occurrence
                        }
                        Button("删除这门课", role: .destructive) {
                            pendingCourseDeletion = .wholeCourse
                        }
                    }
                }

                if entry.kind == .course, !allowsCourseMutation {
                    Section("编辑") {
                        Text("分享课表是只读副本，不能调课、删除课程或做调休 / 放假。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if entry.kind == .custom, allowsCustomScheduleMutation {
                    Section {
                        Button("编辑") {
                            dismiss()
                            onEditCustomSchedule()
                        }
                        Button("删除", role: .destructive) {
                            onDeleteCustomSchedule()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert(item: $pendingCourseDeletion) { target in
                Alert(
                    title: Text("确认删除"),
                    message: Text(target.message(entry: entry, currentWeek: currentWeek)),
                    primaryButton: .destructive(Text("删除")) {
                        switch target {
                        case .occurrence:
                            onDeleteCourseOccurrence()
                        case .wholeCourse:
                            onDeleteCourse()
                        }
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
    }

    private var title: String {
        switch entry.kind {
        case .course: return "课程详情"
        case .exam: return "考试详情"
        case .custom: return "自定义日程"
        }
    }

    private enum PendingCourseDeletion: Identifiable {
        case occurrence
        case wholeCourse

        var id: Int {
            switch self {
            case .occurrence: return 0
            case .wholeCourse: return 1
            }
        }

        func message(entry: ScheduleCalendarEntry, currentWeek: Int) -> String {
            switch self {
            case .occurrence:
                return "你要删除的是第\(currentWeek)周第\(Int(entry.startSection) + 1)到第\(Int(entry.endSection))节的一节课：\(entry.title)"
            case .wholeCourse:
                return "你要删除的是\(entry.title)这门课的本学期所有课程"
            }
        }
    }
}

/// 新增课程弹层。
///
/// 这是纯本地课程的补录入口，主要用于补一周里的临时课或手动修正课表。
private struct AddCourseSheet: View {
    @Binding var draft: CourseDraft
    let mode: CourseEditorMode
    let timeTable: [TimeSlot]
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    private let weekdays = Array(1 ... 7)

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("课程名称", text: $draft.title)
                    TextField("教师", text: $draft.teacher)
                    TextField("教室", text: $draft.classroom)
                    if mode.locksWeeks, let fixedWeek = mode.fixedWeek {
                        LabeledContent("周次") {
                            Text("第\(fixedWeek)周")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("周次（如 1-16,18）", text: $draft.weeksText)
                    }
                }

                Section("时间") {
                    Picker("星期", selection: $draft.weekday) {
                        ForEach(weekdays, id: \.self) { weekday in
                            Text("周\(weekday)").tag(weekday)
                        }
                    }

                    Picker("开始节次", selection: $draft.startSection) {
                        ForEach(timeTable) { slot in
                            Text("第\(slot.id)节  \(slot.start)").tag(slot.id)
                        }
                    }

                    Picker("结束节次", selection: $draft.endSection) {
                        ForEach(timeTable.filter { $0.id >= draft.startSection }) { slot in
                            Text("第\(slot.id)节  \(slot.end)").tag(slot.id)
                        }
                    }
                }

                Section {
                    Text(mode.footerText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onDismiss)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定", action: onSubmit)
                }
            }
        }
    }
}

/// 新增 / 编辑自定义日程弹层。
///
/// 课表页和自定义日程列表页都共用这一套编辑器。
private struct AddEditCustomScheduleSheet: View {
    @Binding var draft: CustomScheduleDraft
    let isEditing: Bool
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("标题", text: $draft.title)
                    TextField("副标题（通常为地点）", text: $draft.subtitle)
                    TextField("描述（详情页显示）", text: $draft.description, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }

                Section("时间") {
                    DatePicker("日期", selection: $draft.date, displayedComponents: .date)
                    DatePicker("开始时间", selection: $draft.beginTime, displayedComponents: .hourAndMinute)
                    DatePicker("结束时间", selection: $draft.endTime, displayedComponents: .hourAndMinute)
                }

                Section {
                    Text("请不要把时间设在课间或极短时段，和其它日程冲突时会发生覆盖。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
          }
            .navigationTitle(isEditing ? "修改自定义日程" : "添加自定义日程")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: draft.beginTime) { _, newValue in
                guard draft.endTime <= newValue else { return }
                draft.endTime = Calendar.current.date(byAdding: .minute, value: 60, to: newValue) ?? newValue
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onDismiss)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定", action: onSubmit)
                }
            }
        }
    }
}

/// 时间表编辑器。
///
/// 这是一个偏工程化的入口，允许直接批量编辑整份节次表文本。
struct TimeTableEditorSheet: View {
    @Binding var text: String
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("每行格式：开始时间, 结束时间")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Spacer()
            }
            .padding(16)
            .navigationTitle("设置时间表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定", action: onSubmit)
                }
            }
        }
    }
}

/// 自定义日程列表页。
///
/// 从课表页右下角加号新增的是单条自定义日程；这张列表页则负责管理全部已有自定义日程。
struct CustomScheduleListSheet: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRecord: CustomScheduleRecord?
    @State private var editingRecordID: String?
    @State private var draft = CustomScheduleDraft()
    @State private var isShowingEditor = false

    var body: some View {
        NavigationStack {
            List {
                if viewModel.cache.customSchedules.isEmpty {
                    ContentUnavailableView(
                        "还没有自定义日程",
                        systemImage: "calendar.badge.plus",
                        description: Text("点击右上角的加号可以先新增一个。")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(viewModel.cache.customSchedules) { record in
                        Button {
                            selectedRecord = record
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title)
                                    .foregroundStyle(.primary)
                                Text(record.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("\(record.dateString)  \(record.beginTime)-\(record.endTime)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("自定义日程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingRecordID = nil
                        draft = viewModel.customScheduleDraft(for: nil)
                        isShowingEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $selectedRecord) { record in
                NavigationStack {
                    List {
                        Section {
                            Text(record.title).font(.headline)
                            if !record.subtitle.isEmpty {
                                Text(record.subtitle).foregroundStyle(.secondary)
                            }
                        }

                        Section("详情") {
                            Text(record.description.isEmpty ? "无描述" : record.description)
                            Text(record.dateString)
                            Text("\(record.beginTime) - \(record.endTime)")
                        }

                        Section {
                            Button("编辑") {
                                selectedRecord = nil
                                editingRecordID = record.id
                                draft = viewModel.customScheduleDraft(for: record)
                                isShowingEditor = true
                            }
                            Button("删除", role: .destructive) {
                                viewModel.deleteCustomSchedule(id: record.id)
                                selectedRecord = nil
                            }
                        }
                    }
                    .navigationTitle("自定义日程")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { selectedRecord = nil }
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingEditor) {
                AddEditCustomScheduleSheet(
                    draft: $draft,
                    isEditing: editingRecordID != nil,
                    onSubmit: {
                        do {
                            if let editingRecordID {
                                try viewModel.updateCustomSchedule(id: editingRecordID, draft: draft)
                            } else {
                                try viewModel.addCustomSchedule(draft)
                            }
                            isShowingEditor = false
                        } catch {
                            viewModel.notice = ScheduleNotice(title: "保存失败", message: error.localizedDescription)
                        }
                    },
                    onDismiss: { isShowingEditor = false }
                )
            }
        }
    }
}

/// 处理同一天中互相重叠的日历块，避免后插入的块把前一个块完全遮住。
private func normalize(entries: [ScheduleCalendarEntry]) -> [ScheduleCalendarEntry] {
    let sorted = entries.sorted { lhs, rhs in
        if lhs.dayOfWeek == rhs.dayOfWeek {
            return lhs.startSection < rhs.startSection
        }
        return lhs.dayOfWeek < rhs.dayOfWeek
    }

    var result: [ScheduleCalendarEntry] = []

    for day in 1 ... 7 {
        var dayEntries: [ScheduleCalendarEntry] = []
        for entry in sorted where entry.dayOfWeek == day {
            if let last = dayEntries.last, last.endSection > entry.startSection {
                if last.endSection < entry.endSection {
                    dayEntries.append(
                        ScheduleCalendarEntry(
                            id: "\(entry.id)-trim-\(last.endSection)",
                            sourceID: entry.sourceID,
                            dayOfWeek: entry.dayOfWeek,
                            startSection: last.endSection,
                            endSection: entry.endSection,
                            title: entry.title,
                            subtitle: entry.subtitle,
                            detailLines: entry.detailLines,
                            kind: entry.kind
                        )
                    )
                }
            } else {
                dayEntries.append(entry)
            }
        }
        result.append(contentsOf: dayEntries)
    }

    return result
}

/// 把具体时间映射到课表网格中的“浮点节次位置”。
///
/// 例如 10:15 可能落在第 3.4 节的位置，用于考试和自定义日程块的连续时间定位。
private func convertTimeToSection(timeText: String, timeTable: [TimeSlot]) -> CGFloat {
    let minutes = TimeSlot.parseMinutes(timeText)
    guard !timeTable.isEmpty else { return 0 }

    let sectionIndex = timeTable.firstIndex(where: { minutes <= $0.endMinutes }) ?? (timeTable.count - 1)
    let slot = timeTable[sectionIndex]
    let duration = max(slot.endMinutes - slot.startMinutes, 1)
    let rawRatio = CGFloat(minutes - slot.startMinutes) / CGFloat(duration)
    let ratio = min(max(rawRatio, 0), 1)
    return CGFloat(sectionIndex) + ratio
}

/// 根据首周日期计算课表页当前周次。
private func resolvedCurrentWeek(firstDay: Date) -> Int {
    let start = Calendar.current.startOfDay(for: firstDay)
    let today = Calendar.current.startOfDay(for: Date())
    let diff = Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0
    return ScheduleWeekCodec.weekNumber(forDayOffset: diff)
}

/// DDL 分页。
///
/// DDL 页当前走最原生的 `List(.insetGrouped)`，与成绩和空教室保持一致。
private struct DDLScheduleTabView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @State private var selectedEvent: DDLEventRecord?
    @State private var draft = DDLDraft()
    @State private var editingEventID: String?
    @State private var isShowingEditor = false
    @State private var settingsRoute: SettingsRoute?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(.systemGroupedBackground)
                .ignoresSafeArea(edges: .bottom)

            Group {
                if !viewModel.hasLexueCalendarURL {
                    VStack(spacing: 16) {
                        Button {
                            Task {
                                await viewModel.refreshLexueCalendarURL(showSuccessNotice: false)
                                await viewModel.syncDDL()
                            }
                        } label: {
                            HStack {
                                if viewModel.isSyncingDDL {
                                    ProgressView()
                                }
                                Text("获取乐学日程")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isSyncingDDL)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if viewModel.visibleDDLEvents.isEmpty {
                            Section {
                                ContentUnavailableView(
                                    "暂无 DDL",
                                    systemImage: "list.bullet.clipboard",
                                    description: Text("先获取乐学日程，或手动添加一条。")
                                )
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            Section {
                                ForEach(viewModel.visibleDDLEvents) { event in
                                    DDLEventCard(
                                        event: event,
                                        remainText: viewModel.ddlRemainingText(for: event),
                                        dueText: viewModel.ddlDueText(for: event),
                                        tint: color(for: event),
                                        onToggleDone: { viewModel.toggleDDLDone(event) },
                                        onOpenDetail: { selectedEvent = event }
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }

            VStack(spacing: 10) {
                CourseScheduleFAB(systemImage: "plus") {
                    editingEventID = nil
                    draft = DDLDraft()
                    isShowingEditor = true
                }

                CourseScheduleFAB(systemImage: "gearshape") {
                    settingsRoute = .ddl
                }
            }
            .padding(.trailing, 10)
            .padding(.bottom, 20)
        }
        .sheet(item: $selectedEvent) { event in
            DDLEventDetailSheet(
                event: event,
                remainText: viewModel.ddlRemainingText(for: event),
                onEdit: {
                    editingEventID = event.id
                    draft = viewModel.ddlDraft(for: event)
                    isShowingEditor = true
                },
                onDelete: {
                    viewModel.deleteDDL(id: event.id)
                    selectedEvent = nil
                }
            )
        }
        .sheet(isPresented: $isShowingEditor) {
            DDLEditSheet(
                draft: $draft,
                isEditing: editingEventID != nil,
                onSubmit: {
                    do {
                        if let editingEventID {
                            try viewModel.updateDDL(id: editingEventID, draft: draft)
                        } else {
                            try viewModel.addDDL(draft)
                        }
                        isShowingEditor = false
                    } catch {
                        viewModel.notice = ScheduleNotice(title: "保存失败", message: error.localizedDescription)
                    }
                },
                onDismiss: { isShowingEditor = false }
            )
        }
        .sheet(item: $settingsRoute) { route in
            NavigationStack {
                SettingsRootView(initialRoute: route, studentID: "", onLogout: {}, showsCloseButton: true)
            }
        }
    }

    private func color(for event: DDLEventRecord) -> Color {
        switch viewModel.ddlTint(for: event) {
        case "red":
            return .red
        case "orange":
            return .orange
        case "gray":
            return .gray
        default:
            return .green
        }
    }
}

/// DDL 列表卡片。
///
/// DDL 虽然放在 `List` 里，但单条仍保留卡片式内容区，以便容纳剩余时间、详情摘要和完成按钮。
private struct DDLEventCard: View {
    let event: DDLEventRecord
    let remainText: String
    let dueText: String
    let tint: Color
    let onToggleDone: () -> Void
    let onOpenDetail: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggleDone) {
                Image(systemName: event.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text(event.title)
                    .font(.headline)
                    .strikethrough(event.done)

                if !displayText.isEmpty {
                    Text(displayText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Text(remainText)
                    .font(.subheadline)
                    .foregroundStyle(tint)

                Text(dueText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpenDetail)
    }

    private var displayText: String {
        event.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// DDL 详情页。
///
/// 乐学同步项只允许查看，不允许编辑和删除；手动项才会出现编辑/删除按钮。
private struct DDLEventDetailSheet: View {
    let event: DDLEventRecord
    let remainText: String
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(event.title)
                        .font(.headline)
                        .strikethrough(event.done)
                    Text(ScheduleDateCodec.formatDateTime(event.dueAt))
                        .foregroundStyle(.secondary)
                    Text(event.group == "lexue" ? "乐学" : "自定义")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("详情") {
                    Text(remainText)
                    Text(detailText.isEmpty ? "无详情" : detailText)
                }

                if event.group != "lexue" {
                    Section {
                        Button("编辑") {
                            dismiss()
                            onEdit()
                        }
                        Button("删除", role: .destructive) {
                            onDelete()
                        }
                    }
                }
            }
            .navigationTitle("DDL 详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var detailText: String {
        event.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 自定义 DDL 编辑页。
///
/// 这里同时服务新增和编辑两种场景，仅靠 `isEditing` 调整标题文案。
private struct DDLEditSheet: View {
    @Binding var draft: DDLDraft
    let isEditing: Bool
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("标题", text: $draft.title)
                    DatePicker("时间", selection: $draft.dueAt, displayedComponents: [.date, .hourAndMinute])
                    TextField("详情", text: $draft.text, axis: .vertical)
                        .lineLimit(4, reservesSpace: true)
                }
            }
            .navigationTitle(isEditing ? "编辑 DDL" : "添加 DDL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onDismiss)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定", action: onSubmit)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
