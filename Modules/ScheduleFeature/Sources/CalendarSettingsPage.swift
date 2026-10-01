import SchedulePorts
#if os(iOS)
import ClientCore
import ScheduleDomain
import DesignSystemKit

import SwiftUI

public struct CalendarSettingsPage<PreferenceSyncControls: View>: View {
    @Binding private var hasSeenSharedScheduleImportGuide: Bool
    private let appStoreURL: URL
    private let preferenceSyncControls: PreferenceSyncControls

    public init(
        viewModel: ScheduleViewModel,
        hasSeenSharedScheduleImportGuide: Binding<Bool>,
        appStoreURL: URL,
        @ViewBuilder preferenceSyncControls: () -> PreferenceSyncControls
    ) {
        self.viewModel = viewModel
        self._hasSeenSharedScheduleImportGuide = hasSeenSharedScheduleImportGuide
        self.appStoreURL = appStoreURL
        self.preferenceSyncControls = preferenceSyncControls()
    }

    private struct ExportedScheduleCode: Identifiable {
        let id = UUID()
        let code: String
    }

    private struct ImportSheetPresentation: Identifiable {
        let id = UUID()
    }

    private struct RenamingScheduleTarget: Identifiable {
        enum Kind {
            case primary
            case shared(String)
        }

        let id = UUID()
        let kind: Kind
        let currentName: String
        let title: String
    }

    @ObservedObject private var viewModel: ScheduleViewModel
    @AppStorage("schedule.calendar.axisMode") private var storedCalendarAxisMode = ScheduleCalendarAxisMode.quantized.rawValue
    @State private var isShowingTimeTableEditor = false
    @State private var timeTableText = ""
    @State private var isShowingSemesterStartDatePicker = false
    @State private var isShowingLiveActivityLeadMinutesPicker = false
    @State private var isShowingEmptyScheduleExportConfirmation = false
    @State private var isShowingSharedScheduleImportGuide = false
    @State private var isShowingLiveActivityExperimentalWarning = false
    @State private var isShowingSystemCalendarImportConfirmation = false
    @State private var isShowingSystemCalendarDeleteConfirmation = false
    @State private var isUpdatingSystemCalendar = false
    @State private var shouldOpenImportSheetAfterGuide = false
    @State private var exportedScheduleCode: ExportedScheduleCode?
    @State private var importSheetPresentation: ImportSheetPresentation?
    @State private var renamingScheduleTarget: RenamingScheduleTarget?

    private var normalizedLeadMinutes: Int {
        min(max(viewModel.settingsSnapshot.courseLiveActivityLeadMinutes, 1), 60)
    }

    private var iCloudSyncSection: some View {
        Section {
            Toggle("iCloud 多端同步", isOn: Binding(
                get: { viewModel.settingsSnapshot.iCloudSyncEnabled },
                set: { viewModel.setICloudSyncEnabled($0) }
            ))
            .appSelectionFeedback(trigger: viewModel.settingsSnapshot.iCloudSyncEnabled)
            .appInteractiveListRow()
            Text("同步手动调课、放假、个人日程、分享课表、DDL 状态和日程偏好。课程、考试与乐学 DDL 正文由本机刷新。")
                .font(AppDesignSystem.Typography.footnote)
                .foregroundStyle(AppDesignSystem.Foreground.secondary)
            preferenceSyncControls
        } header: {
            AppListSectionHeader("iCloud 同步")
        }
    }

    private var dataSettingsSection: some View {
        Section("数据设置") {
            NavigationLink {
                ScheduleTermPickerPage(viewModel: viewModel)
            } label: {
                LabeledContent {
                    Text(viewModel.settingsSnapshot.currentTerm.isEmpty ? "未设置" : viewModel.settingsSnapshot.currentTerm)
                        .foregroundStyle(.tint)
                } label: {
                    Text("当前学期")
                        .foregroundStyle(.tint)
                }
            }
            .appInteractiveListRow()
            if viewModel.settingsSnapshot.firstDay != nil {
                Button {
                    isShowingSemesterStartDatePicker = true
                } label: {
                    LabeledContent("学期起始日期", value: viewModel.settingsSnapshot.firstDayString)
                }
                .disabled(viewModel.settingsSnapshot.currentTerm.isEmpty || !viewModel.isCacheWritable)
                .appInteractiveListRow()
            }
            Button("时间表") {
                timeTableText = viewModel.settingsSnapshot.timeTableText
                isShowingTimeTableEditor = true
            }
            .appInteractiveListRow()

            Button("分享课表") {
                exportScheduleCode()
            }
            .appInteractiveListRow()

            Button("导入课表") {
                presentImportGuideIfNeeded(openImportAfterGuide: true)
            }
            .appInteractiveListRow()

            Button("导入到系统日历") {
                isShowingSystemCalendarImportConfirmation = true
            }
            .disabled(isUpdatingSystemCalendar)
            .appInteractiveListRow()

            Button("删除已导入的日历", role: .destructive) {
                isShowingSystemCalendarDeleteConfirmation = true
            }
            .disabled(isUpdatingSystemCalendar)
            .appInteractiveListRow(isDestructive: true)
        }
    }

    private var scheduleNamesSection: some View {
        Section("课表名称") {
            Button {
                renamingScheduleTarget = RenamingScheduleTarget(
                    kind: .primary,
                    currentName: viewModel.settingsSnapshot.primaryScheduleTitle,
                    title: "重命名课表"
                )
            } label: {
                LabeledContent("我的课表", value: viewModel.settingsSnapshot.primaryScheduleTitle)
            }
            .accessibilityIdentifier("schedule.settings.primary-name")
            .appInteractiveListRow()

            ForEach(viewModel.settingsSnapshot.sharedSchedules) { schedule in
                Button {
                    renamingScheduleTarget = RenamingScheduleTarget(
                        kind: .shared(schedule.id),
                        currentName: schedule.title,
                        title: "重命名分享课表"
                    )
                } label: {
                    LabeledContent("分享课表", value: schedule.title)
                }
                .accessibilityIdentifier("schedule.settings.shared.\(schedule.id)")
                .appInteractiveListRow()
            }
            .onDelete { offsets in
                let schedules = viewModel.settingsSnapshot.sharedSchedules
                let ids = offsets.compactMap { index in
                    schedules.indices.contains(index) ? schedules[index].id : nil
                }
                for id in ids {
                    viewModel.deleteSharedSchedule(id: id)
                }
            }
        }
    }

    private var displaySettingsSection: some View {
        Section {
            Picker("时间轴", selection: Binding(
                get: { ScheduleCalendarAxisMode(rawValue: storedCalendarAxisMode) ?? .quantized },
                set: {
                    storedCalendarAxisMode = $0.rawValue
                }
            )) {
                ForEach(ScheduleCalendarAxisMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .appSelectionFeedback(trigger: storedCalendarAxisMode)
            .appInteractiveListRow()

            Picker(selection: Binding(
                get: { viewModel.settingsSnapshot.scheduleDisplayMode },
                set: { viewModel.setScheduleDisplayMode($0) }
            )) {
                ForEach(ScheduleDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Text("课程显示方式")
                    .foregroundStyle(.tint)
            }
            .appSelectionFeedback(trigger: viewModel.settingsSnapshot.scheduleDisplayMode)
            .appInteractiveListRow()
            Picker(selection: Binding(
                get: { viewModel.settingsSnapshot.scheduleCardContentMode },
                set: { viewModel.setScheduleCardContentMode($0) }
            )) {
                ForEach(ScheduleCardContentMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Text("显示内容")
                    .foregroundStyle(.tint)
            }
            .appSelectionFeedback(trigger: viewModel.settingsSnapshot.scheduleCardContentMode)
            .appInteractiveListRow()
            Toggle("显示周六", isOn: Binding(get: { viewModel.settingsSnapshot.showSaturday }, set: viewModel.setShowSaturday))
                .appSelectionFeedback(trigger: viewModel.settingsSnapshot.showSaturday)
            .appInteractiveListRow()
            Toggle("显示周日", isOn: Binding(get: { viewModel.settingsSnapshot.showSunday }, set: viewModel.setShowSunday))
                .appSelectionFeedback(trigger: viewModel.settingsSnapshot.showSunday)
            .appInteractiveListRow()
            Toggle("显示考试安排", isOn: Binding(get: { viewModel.settingsSnapshot.showExamInfo }, set: viewModel.setShowExamInfo))
                .appSelectionFeedback(trigger: viewModel.settingsSnapshot.showExamInfo)
            .appInteractiveListRow()
            Toggle("显示灵动岛提醒（实验性）", isOn: Binding(
                get: { viewModel.settingsSnapshot.showCourseLiveActivityReminder },
                set: { enabled in
                    if enabled {
                        isShowingLiveActivityExperimentalWarning = true
                    } else {
                        viewModel.setShowCourseLiveActivityReminder(false)
                    }
                }
            ))
            .appSelectionFeedback(trigger: viewModel.settingsSnapshot.showCourseLiveActivityReminder)
            .appInteractiveListRow()
            Button {
                guard viewModel.settingsSnapshot.showCourseLiveActivityReminder else { return }
                isShowingLiveActivityLeadMinutesPicker = true
            } label: {
                HStack(spacing: AppDesignSystem.Spacing.regular) {
                    Text("提前显示阈值")
                        .foregroundStyle(.tint)
                    Spacer()
                    Text("\(normalizedLeadMinutes) 分钟")
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.settingsSnapshot.showCourseLiveActivityReminder)
            .opacity(viewModel.settingsSnapshot.showCourseLiveActivityReminder
                ? AppDesignSystem.Opacity.full
                : AppDesignSystem.Schedule.reminderDisabledOpacity)
            .appInteractiveListRow()
        } header: {
            AppListSectionHeader("显示设置")
        }
    }

    public var body: some View {
        List {
            dataSettingsSection
            scheduleNamesSection
            displaySettingsSection
            iCloudSyncSection
        }
        .appGroupedListStyle()
        .task {
            await viewModel.loadIfNeeded()
            if viewModel.settingsSnapshot.courseLiveActivityLeadMinutes != normalizedLeadMinutes {
                viewModel.setCourseLiveActivityLeadMinutes(normalizedLeadMinutes)
            }
        }
        .sheet(isPresented: $isShowingTimeTableEditor) {
            TimeTableEditorSheet(
                text: $timeTableText,
                onSubmit: {
                    do {
                        try viewModel.setTimeTable(from: timeTableText)
                        isShowingTimeTableEditor = false
                    } catch {
                        viewModel.notice = ScheduleNotice.userInput(title: "设置失败", message: error.localizedDescription)
                    }
                }
            )
        }
        .sheet(isPresented: $isShowingSemesterStartDatePicker) {
            if let firstDay = viewModel.settingsSnapshot.firstDay {
                NavigationStack {
                    ScheduleSemesterStartDatePickerPage(
                        date: firstDay,
                        schoolDate: viewModel.settingsSnapshot.schoolFirstDay,
                        onSubmit: viewModel.setSemesterStartDate
                    )
                }
            }
        }
        .sheet(isPresented: $isShowingLiveActivityLeadMinutesPicker) {
            NavigationStack {
                CourseLiveActivityLeadMinutesPickerPage(
                    value: Binding(
                        get: { normalizedLeadMinutes },
                        set: viewModel.setCourseLiveActivityLeadMinutes
                    )
                )
            }
        }
        .sheet(item: $exportedScheduleCode) { payload in
            ScheduleExportCodeSheet(code: payload.code)
        }
        .sheet(item: $importSheetPresentation) { _ in
            ScheduleImportCodeSheet(
                initialText: "",
                appStoreURL: appStoreURL,
                onImport: { text in
                    try importScheduleCode(text)
                }
            )
        }
        .sheet(item: $renamingScheduleTarget) { target in
            ScheduleRenameSheet(
                title: target.title,
                initialName: target.currentName
            ) { newName in
                switch target.kind {
                case .primary:
                    try viewModel.renamePrimarySchedule(to: newName)
                case let .shared(id):
                    try viewModel.renameSharedSchedule(id: id, to: newName)
                }
            }
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
            AppSMSVerificationSheet(
                maskedPhone: challenge.maskedPhone,
                isSubmitting: viewModel.isSubmittingSMSCode,
                errorMessage: viewModel.smsVerificationError,
                submitTitle: "验证并同步课表",
                onCancel: viewModel.dismissSMSChallenge,
                onSubmit: { code in
                    await viewModel.submitSMSCode(code)
                }
            )
        }
        .alert("当前课表为空", isPresented: $isShowingEmptyScheduleExportConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确定") {
                exportScheduleCode(allowEmptyCourseData: true)
            }
        } message: {
            Text("当前课表为空，仍要分享？")
        }
        .alert("实验性功能提醒", isPresented: $isShowingLiveActivityExperimentalWarning) {
            Button("取消", role: .cancel) {}
            Button("继续打开") {
                viewModel.setShowCourseLiveActivityReminder(true)
            }
        } message: {
            Text("灵动岛提醒使用多重保护逻辑，并遵循系统唤醒条件；部分课程提醒可能延后或缺失。继续打开表示你已了解这项限制。")
        }
        .alert("导入当前学期到系统日历？", isPresented: $isShowingSystemCalendarImportConfirmation) {
            Button("导入并替换本学期旧事件") {
                importCurrentTermToSystemCalendar()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("导入会创建“BIT101 课表”日历；重复导入会替换本学期中带 BIT101 标记的事件。")
        }
        .alert("删除 BIT101 导入的日历事件？", isPresented: $isShowingSystemCalendarDeleteConfirmation) {
            Button("删除", role: .destructive) {
                deleteImportedSystemCalendarEvents()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除操作会移除带 BIT101 标记的事件，保留你自己创建的日程。")
        }
        .alert("导入分享课表提示", isPresented: $isShowingSharedScheduleImportGuide) {
            Button("知道了") {
                hasSeenSharedScheduleImportGuide = true
                if shouldOpenImportSheetAfterGuide {
                    importSheetPresentation = ImportSheetPresentation()
                }
                shouldOpenImportSheetAfterGuide = false
            }
            Button("取消", role: .cancel) {
                shouldOpenImportSheetAfterGuide = false
            }
        } message: {
            Text("单击课表名称可改名，左滑可删除；在日程界面上下滑可循环切换课表；每个小组件使用自己的课表作为数据源。")
        }
    }

    private func importCurrentTermToSystemCalendar() {
        isUpdatingSystemCalendar = true
        Task {
            defer { isUpdatingSystemCalendar = false }
            do {
                let count = try await viewModel.importCurrentTermToSystemCalendar()
                viewModel.notice = ScheduleNotice.informational(
                    title: "导入成功",
                    message: "已向“BIT101 课表”日历写入 \(count) 节课程。"
                )
            } catch {
                if let calendarError = error as? ScheduleSystemCalendarError {
                    viewModel.notice = ScheduleNotice.userInput(
                        title: "导入失败",
                        message: calendarError.localizedDescription,
                        recoveryAction: calendarError.requiresCalendarSettings ? .openAppSettings : nil
                    )
                } else {
                    viewModel.notice = ScheduleNotice(
                        title: "导入失败",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func deleteImportedSystemCalendarEvents() {
        isUpdatingSystemCalendar = true
        Task {
            defer { isUpdatingSystemCalendar = false }
            do {
                let result = try await viewModel.deleteImportedSystemCalendarEvents()
                switch result {
                case let .changed(count):
                    viewModel.notice = ScheduleNotice.informational(
                        title: "删除成功",
                        message: "已删除 \(count) 条由 BIT101 导入的日历事件。"
                    )
                case .noOp:
                    viewModel.notice = ScheduleNotice.informational(
                        title: "无需删除",
                        message: "系统日历中没有由 BIT101 导入的事件。"
                    )
                }
            } catch {
                if let calendarError = error as? ScheduleSystemCalendarError {
                    viewModel.notice = ScheduleNotice.userInput(
                        title: "删除失败",
                        message: calendarError.localizedDescription,
                        recoveryAction: calendarError.requiresCalendarSettings ? .openAppSettings : nil
                    )
                } else {
                    viewModel.notice = ScheduleNotice(
                        title: "删除失败",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    /// 生成一份可复制的压缩课表编码。
    ///
    /// 当前编码格式为：
    /// `BIT101SCH3:<base64(lzfse(json(compactPayload)))>`
    ///
    /// V3 导出课程排布骨架与学分，导入端复用本机的学期、首周和时间表。
    private func exportScheduleCode(allowEmptyCourseData: Bool = false) {
        guard allowEmptyCourseData || viewModel.settingsSnapshot.hasCourses else {
            isShowingEmptyScheduleExportConfirmation = true
            return
        }

        do {
            let code = try viewModel.exportScheduleCode()
            exportedScheduleCode = ExportedScheduleCode(code: code)
        } catch {
            viewModel.notice = ScheduleNotice(title: "导出失败", message: error.localizedDescription)
        }
    }

    /// 导入前展示一次使用提示。
    private func presentImportGuideIfNeeded(openImportAfterGuide: Bool) {
        shouldOpenImportSheetAfterGuide = openImportAfterGuide

        if !hasSeenSharedScheduleImportGuide {
            isShowingSharedScheduleImportGuide = true
        } else if openImportAfterGuide {
            importSheetPresentation = ImportSheetPresentation()
        }
    }

    /// 解析并导入一份压缩编码的课表。
    ///
    /// 当前支持两套格式：
    /// - `BIT101SCH2:<base64(lzfse(json(compactPayload)))>`：V2 精简数组载荷
    /// - `BIT101SCH3:<base64(lzfse(json(compactPayload)))>`：V3 精简数组载荷，额外包含学分
    ///
    /// 导入端根据版本前缀选择解析器，UI 使用同一导入窗口。
    private func importScheduleCode(_ text: String) throws {
        try viewModel.importScheduleCode(text)
        viewModel.notice = ScheduleNotice.informational(title: "导入成功", message: "分享课表已导入。考试、DDL 与自定义日程保持当前内容。")
    }
}

#endif
