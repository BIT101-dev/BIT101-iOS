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

enum CourseEditorMode: Equatable {
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
