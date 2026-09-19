//
//  SettingsScheduleViews.swift
//  BIT101-iOS
//

import SwiftUI

struct CalendarSettingsPage: View {
    @ObservedObject private var appSettings = AppSettingsStore.shared
    @ObservedObject private var preferenceCloudSync = ExperimentalPreferenceCloudSync.shared

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

    @StateObject private var viewModel = SchoolDataViewModelStore.shared.scheduleViewModel
    @State private var isShowingTimeTableEditor = false
    @State private var timeTableText = ""
    @State private var isShowingCustomSchedules = false
    @State private var isShowingLiveActivityLeadMinutesPicker = false
    @State private var isShowingFirstDayEditor = false
    @State private var firstDayDraft = Date()
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
        min(max(viewModel.cache.courseLiveActivityLeadMinutes, 1), 60)
    }

    private var iCloudSyncSection: some View {
        Section {
            Toggle("iCloud 多端同步", isOn: Binding(
                get: { viewModel.cache.iCloudSyncEnabled },
                set: { viewModel.setICloudSyncEnabled($0) }
            ))
            .appSelectionFeedback(trigger: viewModel.cache.iCloudSyncEnabled)
            Toggle("同步设置与使用偏好（实验性）", isOn: Binding(
                get: { preferenceCloudSync.isEnabled },
                set: { preferenceCloudSync.setEnabled($0) }
            ))
            .appSelectionFeedback(trigger: preferenceCloudSync.isEnabled)
        } header: {
            Text("iCloud 同步")
        }
    }

    private var dataSettingsSection: some View {
        Section("数据设置") {
            NavigationLink {
                ScheduleTermPickerPage(viewModel: viewModel)
            } label: {
                LabeledContent {
                    Text(viewModel.cache.currentTerm.isEmpty ? "未设置" : viewModel.cache.currentTerm)
                        .foregroundStyle(.tint)
                } label: {
                    Text("当前学期")
                        .foregroundStyle(.tint)
                }
            }
            Button {
                firstDayDraft = viewModel.cache.firstDay ?? Date()
                isShowingFirstDayEditor = true
            } label: {
                LabeledContent("学期起始日期", value: viewModel.firstDayDescription)
                    .foregroundStyle(.primary)
            }

            Button {
                Task { await viewModel.syncSelectedTerm() }
            } label: {
                HStack(spacing: AppDesignSystem.Spacing.control) {
                    Text("重新同步课表与考试")
                    Spacer()
                    if viewModel.isSyncingCourses {
                        ProgressView()
                    }
                }
            }
            .disabled(viewModel.isSyncingCourses || viewModel.isLoadingTerms)

            Button("时间表") {
                timeTableText = viewModel.cache.timeTable.map { "\($0.start), \($0.end)" }.joined(separator: "\n")
                isShowingTimeTableEditor = true
            }

            Button("自定义日程") {
                isShowingCustomSchedules = true
            }

            Button("分享课表") {
                exportScheduleCode()
            }

            Button("导入课表") {
                presentImportGuideIfNeeded(openImportAfterGuide: true)
            }

            Button("导入到系统日历") {
                isShowingSystemCalendarImportConfirmation = true
            }
            .disabled(isUpdatingSystemCalendar)

            Button("删除已导入的日历", role: .destructive) {
                isShowingSystemCalendarDeleteConfirmation = true
            }
            .disabled(isUpdatingSystemCalendar)
        }
    }

    private var scheduleNamesSection: some View {
        Section("课表名称") {
            Button {
                renamingScheduleTarget = RenamingScheduleTarget(
                    kind: .primary,
                    currentName: viewModel.cache.primaryScheduleTitle,
                    title: "重命名课表"
                )
            } label: {
                LabeledContent("我的课表", value: viewModel.cache.primaryScheduleTitle)
            }

            ForEach(viewModel.cache.sharedSchedules) { schedule in
                Button {
                    renamingScheduleTarget = RenamingScheduleTarget(
                        kind: .shared(schedule.id),
                        currentName: schedule.title,
                        title: "重命名分享课表"
                    )
                } label: {
                    LabeledContent("分享课表", value: schedule.title)
                }
            }
            .onDelete { offsets in
                let schedules = viewModel.cache.sharedSchedules
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
            Picker(selection: Binding(
                get: { viewModel.cache.scheduleDisplayMode },
                set: { viewModel.setScheduleDisplayMode($0) }
            )) {
                ForEach(ScheduleDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Text("课程显示方式")
                    .foregroundStyle(.tint)
            }
            .appSelectionFeedback(trigger: viewModel.cache.scheduleDisplayMode)
            Toggle("显示周六", isOn: Binding(get: { viewModel.cache.showSaturday }, set: viewModel.setShowSaturday))
                .appSelectionFeedback(trigger: viewModel.cache.showSaturday)
            Toggle("显示周日", isOn: Binding(get: { viewModel.cache.showSunday }, set: viewModel.setShowSunday))
                .appSelectionFeedback(trigger: viewModel.cache.showSunday)
            Toggle("显示课程卡片边框", isOn: Binding(get: { viewModel.cache.showBorder }, set: viewModel.setShowBorder))
                .appSelectionFeedback(trigger: viewModel.cache.showBorder)
            Toggle("高亮今日", isOn: Binding(get: { viewModel.cache.showHighlightToday }, set: viewModel.setShowHighlightToday))
                .appSelectionFeedback(trigger: viewModel.cache.showHighlightToday)
            Toggle("显示节次分割线", isOn: Binding(get: { viewModel.cache.showDivider }, set: viewModel.setShowDivider))
                .appSelectionFeedback(trigger: viewModel.cache.showDivider)
            Toggle("显示当前时间线", isOn: Binding(get: { viewModel.cache.showCurrentTime }, set: viewModel.setShowCurrentTime))
                .appSelectionFeedback(trigger: viewModel.cache.showCurrentTime)
            Toggle("显示考试安排", isOn: Binding(get: { viewModel.cache.showExamInfo }, set: viewModel.setShowExamInfo))
                .appSelectionFeedback(trigger: viewModel.cache.showExamInfo)
            Toggle("显示灵动岛提醒（实验性）", isOn: Binding(
                get: { viewModel.cache.showCourseLiveActivityReminder },
                set: { enabled in
                    if enabled {
                        isShowingLiveActivityExperimentalWarning = true
                    } else {
                        viewModel.setShowCourseLiveActivityReminder(false)
                    }
                }
            ))
            .appSelectionFeedback(trigger: viewModel.cache.showCourseLiveActivityReminder)
            Button {
                guard viewModel.cache.showCourseLiveActivityReminder else { return }
                isShowingLiveActivityLeadMinutesPicker = true
            } label: {
                HStack(spacing: AppDesignSystem.Spacing.control) {
                    Text("提前显示阈值")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(normalizedLeadMinutes) 分钟")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.cache.showCourseLiveActivityReminder)
            .opacity(viewModel.cache.showCourseLiveActivityReminder ? 1 : 0.45)
        } header: {
            Text("显示设置")
        }
    }

    @ViewBuilder
    private var helpSection: some View {
        if appSettings.hasSeenSharedScheduleImportGuide {
            Section("帮助") {
                Button("重新观看提示") {
                    presentImportGuideIfNeeded(openImportAfterGuide: false, forceShow: true)
                }
            }
        }
    }

    var body: some View {
        List {
            dataSettingsSection
            scheduleNamesSection
            displaySettingsSection
            iCloudSyncSection
            helpSection
        }
        .appGroupedListStyle()
        .diagnosticAlert(item: $viewModel.notice)
        .task {
            viewModel.loadIfNeeded()
            if viewModel.cache.courseLiveActivityLeadMinutes != normalizedLeadMinutes {
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
        .sheet(isPresented: $isShowingCustomSchedules) {
            CustomScheduleListSheet(viewModel: viewModel)
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
        .sheet(isPresented: $isShowingFirstDayEditor) {
            NavigationStack {
                ScheduleFirstDayEditorPage(date: $firstDayDraft) {
                    viewModel.setFirstDay(firstDayDraft)
                    isShowingFirstDayEditor = false
                }
            }
        }
        .sheet(item: $exportedScheduleCode) { payload in
            ScheduleExportCodeSheet(code: payload.code)
        }
        .sheet(item: $importSheetPresentation) { _ in
            ScheduleImportCodeSheet(
                initialText: "",
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
                challenge: challenge,
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
                appSettings.markSharedScheduleImportGuideSeen()
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
                let count = try await ScheduleSystemCalendarManager.shared.importCurrentTerm(from: viewModel.cache)
                viewModel.notice = ScheduleNotice.informational(
                    title: "导入成功",
                    message: "已向“BIT101 课表”日历写入 \(count) 节课程。"
                )
            } catch {
                if let calendarError = error as? ScheduleSystemCalendarError {
                    viewModel.notice = ScheduleNotice.userInput(
                        title: "导入失败",
                        message: calendarError.localizedDescription,
                        shouldOpenSettings: calendarError.shouldOpenSettings
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
                let result = try await ScheduleSystemCalendarManager.shared.deleteAllImportedEvents()
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
                        shouldOpenSettings: calendarError.shouldOpenSettings
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
        guard allowEmptyCourseData || !viewModel.cache.courses.isEmpty else {
            isShowingEmptyScheduleExportConfirmation = true
            return
        }

        do {
            let code = try ScheduleShareCodeCodec.encodeLatest(cache: viewModel.cache)
            exportedScheduleCode = ExportedScheduleCode(code: code)
        } catch {
            viewModel.notice = ScheduleNotice(title: "导出失败", message: error.localizedDescription)
        }
    }

    /// 导入前展示一次使用提示；用户确认后，设置页显示“重新观看提示”入口。
    private func presentImportGuideIfNeeded(openImportAfterGuide: Bool, forceShow: Bool = false) {
        shouldOpenImportSheetAfterGuide = openImportAfterGuide

        if forceShow || !appSettings.hasSeenSharedScheduleImportGuide {
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
        let payload = try ScheduleShareCodeCodec.decode(text, using: viewModel.cache)
        try viewModel.importSharedSchedule(payload)
        viewModel.notice = ScheduleNotice.informational(title: "导入成功", message: "分享课表已导入。考试、DDL 与自定义日程保持当前内容。")
    }
}
