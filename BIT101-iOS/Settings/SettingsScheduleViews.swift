//
//  SettingsScheduleViews.swift
//  BIT101-iOS
//
//  Split from SettingsRootView.swift.
//

import SwiftUI
import UIKit

struct CalendarSettingsPage: View {
    @ObservedObject private var appSettings = AppSettingsStore.shared
    @ObservedObject private var preferenceCloudSync = ExperimentalPreferenceCloudSync.shared

    private struct ExportedScheduleCode: Identifiable {
        let id = UUID()
        let code: String
    }

    private struct ScheduleImportDraft: Identifiable {
        let id = UUID()
        var text = ""
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
    @State private var importDraft: ScheduleImportDraft?
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

    var body: some View {
        List {
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
                    HStack {
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
                    let ids = offsets.compactMap { index in
                        viewModel.cache.sharedSchedules.indices.contains(index) ? viewModel.cache.sharedSchedules[index].id : nil
                    }
                    ids.forEach(viewModel.deleteSharedSchedule)
                }
            }

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
                    HStack {
                        Text("提前显示阈值")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(normalizedLeadMinutes) 分钟")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .opacity(viewModel.cache.showCourseLiveActivityReminder ? 1 : 0.45)
            } header: {
                Text("显示设置")
            }

            iCloudSyncSection

            if appSettings.hasSeenSharedScheduleImportGuide {
                Section("帮助") {
                    Button("重新观看提示") {
                        presentImportGuideIfNeeded(openImportAfterGuide: false, forceShow: true)
                    }
                }
            }
        }
        .appGroupedListStyle()
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
                        viewModel.notice = ScheduleNotice(title: "设置失败", message: error.localizedDescription)
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
        .sheet(item: $importDraft) { draft in
            ScheduleImportCodeSheet(
                initialText: draft.text,
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
        .alert("你尚未获取课表", isPresented: $isShowingEmptyScheduleExportConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确定") {
                exportScheduleCode(allowEmptyCourseData: true)
            }
        } message: {
            Text("你尚未获取课表，仍要分享？")
        }
        .alert("实验性功能提醒", isPresented: $isShowingLiveActivityExperimentalWarning) {
            Button("取消", role: .cancel) {}
            Button("继续打开") {
                viewModel.setShowCourseLiveActivityReminder(true)
            }
        } message: {
            Text("开发者和 AI 尚未完全摸清楚灵动岛的运作机理和唤醒条件。虽然做了多重兜底，但仍不能保证每节课都能按时通知。继续打开视为已知悉此风险。")
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
        .alert("导入分享课表提示", isPresented: $isShowingSharedScheduleImportGuide) {
            Button("知道了") {
                appSettings.markSharedScheduleImportGuideSeen()
                if shouldOpenImportSheetAfterGuide {
                    importDraft = ScheduleImportDraft()
                }
                shouldOpenImportSheetAfterGuide = false
            }
            Button("取消", role: .cancel) {
                shouldOpenImportSheetAfterGuide = false
            }
        } message: {
            Text("课表可以单击以改名，左滑以删除，在日程界面上下滑可循环切换，所有小组件以自己的课表作为数据源。")
        }
    }

    private func importCurrentTermToSystemCalendar() {
        isUpdatingSystemCalendar = true
        Task {
            defer { isUpdatingSystemCalendar = false }
            do {
                let count = try await ScheduleSystemCalendarManager.shared.importCurrentTerm(from: viewModel.cache)
                viewModel.notice = ScheduleNotice(
                    title: "导入成功",
                    message: "已向“BIT101 课表”日历写入 \(count) 节课程。"
                )
            } catch {
                viewModel.notice = ScheduleNotice(title: "导入失败", message: error.localizedDescription)
            }
        }
    }

    private func deleteImportedSystemCalendarEvents() {
        isUpdatingSystemCalendar = true
        Task {
            defer { isUpdatingSystemCalendar = false }
            do {
                let count = try await ScheduleSystemCalendarManager.shared.deleteAllImportedEvents()
                viewModel.notice = ScheduleNotice(
                    title: "删除成功",
                    message: "已删除 \(count) 条由 BIT101 导入的日历事件。"
                )
            } catch {
                viewModel.notice = ScheduleNotice(title: "删除失败", message: error.localizedDescription)
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

    /// 首次导入前先展示一次使用提示；只有真正看过这条提示后，设置页才会出现“重新观看提示”入口。
    private func presentImportGuideIfNeeded(openImportAfterGuide: Bool, forceShow: Bool = false) {
        shouldOpenImportSheetAfterGuide = openImportAfterGuide

        if forceShow || !appSettings.hasSeenSharedScheduleImportGuide {
            isShowingSharedScheduleImportGuide = true
        } else if openImportAfterGuide {
            importDraft = ScheduleImportDraft()
        }
    }

    /// 解析并导入一份压缩编码的课表。
    ///
    /// 当前支持三套格式：
    /// - `BIT101SCH1:<base64(lzfse(json(payload))))>`：V1 完整 JSON 载荷
    /// - `BIT101SCH2:<base64(lzfse(json(compactPayload))))>`：V2 精简数组载荷
    /// - `BIT101SCH3:<base64(lzfse(json(compactPayload))))>`：V3 精简数组载荷，额外包含学分
    ///
    /// UI 保持不变，只在导入端根据版本前缀切换解析器。
    private func importScheduleCode(_ text: String) throws {
        let payload = try ScheduleShareCodeCodec.decode(text, using: viewModel.cache)
        try viewModel.importSharedSchedule(payload)
        viewModel.notice = ScheduleNotice(title: "导入成功", message: "分享的课表已导入。考试、DDL 与自定义日程不会随导入覆盖。")
    }

}

/// 课表学期选择页。
///
/// 这里只展示学校接口实际返回的学期，不在本地追加、推算或生成任何选项。
/// 学期选择先独立落盘；课表、考试和首周的同步失败只提示错误，不回滚学期选择。
private struct ScheduleTermPickerPage: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @State private var selectionFeedbackToken = 0

    private var displayedTerms: [String] {
        viewModel.availableTerms
    }

    var body: some View {
        List {
            Section("选择学期") {
                if !viewModel.hasLoadedAvailableTerms {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    ForEach(displayedTerms, id: \.self) { term in
                        Button {
                            selectionFeedbackToken &+= 1
                            Task { await viewModel.syncCourses(term: term) }
                        } label: {
                            HStack {
                                Text(term)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if viewModel.isSyncingCourses, viewModel.syncingTerm == term {
                                    ProgressView()
                                } else if viewModel.cache.currentTerm == term {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(viewModel.isSyncingCourses || viewModel.isLoadingTerms || viewModel.cache.currentTerm == term)
                    }
                }
            }

        }
        .appGroupedListStyle()
        .appSelectionFeedback(trigger: selectionFeedbackToken)
        .navigationTitle("切换学期")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadAvailableTerms()
        }
        .refreshable {
            await viewModel.loadAvailableTerms()
        }
    }

}

/// 手动覆盖当前学期第一周日期的兜底页面。
private struct ScheduleFirstDayEditorPage: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var date: Date
    let onSave: () -> Void

    var body: some View {
        Form {
            Section {
                DatePicker(
                    "第一周起始日期",
                    selection: $date,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .onChange(of: date) { _, newValue in
                    let monday = ScheduleDateCodec.monday(containing: newValue)
                    if ScheduleDateCodec.formatDate(monday) != ScheduleDateCodec.formatDate(newValue) {
                        date = monday
                    }
                }
            }
        }
        .navigationTitle("学期起始日期")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            date = ScheduleDateCodec.monday(containing: date)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: onSave)
            }
        }
    }
}

/// 课程提醒提前显示阈值的滚轮选择页。
private struct CourseLiveActivityLeadMinutesPickerPage: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var value: Int

    /// 使用原生 wheel picker 提供 1...60 分钟的阈值选择。
    var body: some View {
        Picker("提前显示阈值", selection: $value) {
            ForEach(1 ... 60, id: \.self) { minute in
                Text("\(minute) 分钟")
                    .tag(minute)
            }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .appSelectionFeedback(trigger: value)
                .navigationTitle("提前显示阈值")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    dismiss()
                }
            }
        }
        .presentationDetents([.height(260)])
    }
}

/// 导出的课表压缩编码预览页。
///
/// 这里先让用户看见完整编码，再决定是否复制，方便后续用在聊天、iMessage 或手动导入场景。
struct ScheduleExportCodeSheet: View {
    let code: String

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ScrollView {
                    Text(code)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(AppDesignSystem.Palette.secondaryGroupedBackground, in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.sheet))
                }

                Button {
                    UIPasteboard.general.string = code
                    didCopy = true
                } label: {
                    Label("复制到剪贴板", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("分享课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: code)
                }
            }
            .alert("已复制", isPresented: $didCopy) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("课表已复制到剪贴板。")
            }
        }
    }
}

/// 导入课表压缩编码窗口。
///
/// 这里支持两种动作：
/// - 手动粘贴/编辑编码
/// - 一键从剪贴板读取
struct ScheduleImportCodeSheet: View {
    let initialText: String
    let onImport: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var text: String
    @State private var localAlert: AppAlert?
    @State private var unsupportedFormatVersion: Int?

    init(initialText: String, onImport: @escaping (String) throws -> Void) {
        self.initialText = initialText
        self.onImport = onImport
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $text)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 220)
                    .padding(10)
                    .background(AppDesignSystem.Palette.secondaryGroupedBackground, in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.sheet))

                HStack(spacing: 12) {
                    Button {
                        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                            text = clipboard
                        }
                    } label: {
                        Label("粘贴剪贴板", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        do {
                            try onImport(text)
                            dismiss()
                        } catch let error as ScheduleShareCodeError {
                            if case let .unsupportedNewerFormat(version) = error {
                                unsupportedFormatVersion = version
                            } else {
                                localAlert = AppAlert(title: "导入失败", message: error.localizedDescription)
                            }
                        } catch {
                            localAlert = AppAlert(title: "导入失败", message: error.localizedDescription)
                        }
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("导入课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .diagnosticAlert(item: $localAlert)
            .alert(
                "需要更新 BIT101",
                isPresented: Binding(
                    get: { unsupportedFormatVersion != nil },
                    set: { if !$0 { unsupportedFormatVersion = nil } }
                )
            ) {
                Button("前往 App Store") {
                    openURL(BIT101AppStore.url)
                }
                .keyboardShortcut(.defaultAction)
                Button("取消", role: .cancel) {}
            } message: {
                Text("该课表使用 BIT101SCH\(unsupportedFormatVersion ?? 0) 格式，请更新 BIT101 后再导入。")
            }
        }
    }
}

/// 课表重命名窗口。
///
/// 主课表和分享课表都共用这一套简单编辑器。
private struct ScheduleRenameSheet: View {
    let title: String
    let initialName: String
    let onSubmit: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var localAlert: AppAlert?

    init(title: String, initialName: String, onSubmit: @escaping (String) throws -> Void) {
        self.title = title
        self.initialName = initialName
        self.onSubmit = onSubmit
        _text = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("课表名称", text: $text)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        do {
                            try onSubmit(text)
                            dismiss()
                        } catch {
                            localAlert = AppAlert(title: "保存失败", message: error.localizedDescription)
                        }
                    }
                }
            }
            .diagnosticAlert(item: $localAlert)
        }
    }
}

/// DDL 设置页。
///
/// 这页只负责 DDL 同步和显示窗口配置，不再混入新增/编辑入口。
