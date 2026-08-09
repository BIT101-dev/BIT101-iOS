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

    @StateObject private var viewModel = ScheduleViewModel()
    @State private var isShowingTimeTableEditor = false
    @State private var timeTableText = ""
    @State private var isShowingCustomSchedules = false
    @State private var isShowingLiveActivityLeadMinutesPicker = false
    @State private var isShowingFirstDayEditor = false
    @State private var firstDayDraft = Date()
    @State private var isShowingEmptyScheduleExportConfirmation = false
    @State private var isShowingSharedScheduleImportGuide = false
    @State private var isShowingLiveActivityExperimentalWarning = false
    @State private var shouldOpenImportSheetAfterGuide = false
    @State private var exportedScheduleCode: ExportedScheduleCode?
    @State private var importDraft: ScheduleImportDraft?
    @State private var renamingScheduleTarget: RenamingScheduleTarget?

    private var normalizedLeadMinutes: Int {
        min(max(viewModel.cache.courseLiveActivityLeadMinutes, 1), 60)
    }

    var body: some View {
        List {
            Section("数据设置") {
                NavigationLink {
                    ScheduleTermPickerPage(viewModel: viewModel)
                } label: {
                    LabeledContent("当前学期", value: viewModel.cache.currentTerm.isEmpty ? "未设置" : viewModel.cache.currentTerm)
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
                Toggle("显示周六", isOn: Binding(get: { viewModel.cache.showSaturday }, set: viewModel.setShowSaturday))
                Toggle("显示周日", isOn: Binding(get: { viewModel.cache.showSunday }, set: viewModel.setShowSunday))
                Toggle("显示课程卡片边框", isOn: Binding(get: { viewModel.cache.showBorder }, set: viewModel.setShowBorder))
                Toggle("高亮今日", isOn: Binding(get: { viewModel.cache.showHighlightToday }, set: viewModel.setShowHighlightToday))
                Toggle("显示节次分割线", isOn: Binding(get: { viewModel.cache.showDivider }, set: viewModel.setShowDivider))
                Toggle("显示当前时间线", isOn: Binding(get: { viewModel.cache.showCurrentTime }, set: viewModel.setShowCurrentTime))
                Toggle("显示考试安排", isOn: Binding(get: { viewModel.cache.showExamInfo }, set: viewModel.setShowExamInfo))
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

            Section("iCloud 同步") {
                Toggle("iCloud 实时同步", isOn: Binding(
                    get: { viewModel.cache.iCloudSyncEnabled },
                    set: { enabled in
                        viewModel.setICloudSyncEnabled(enabled)
                    }
                ))
            }

            if appSettings.hasSeenSharedScheduleImportGuide {
                Section("帮助") {
                    Button("重新观看提示") {
                        presentImportGuideIfNeeded(openImportAfterGuide: false, forceShow: true)
                    }
                }
            }
        }
        .task {
            await viewModel.loadIfNeeded()
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
        .alert(item: $viewModel.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    /// 生成一份可复制的压缩课表编码。
    ///
    /// 当前编码格式为：
    /// `BIT101SCH2:<base64(lzfse(json(compactPayload)))>`
    ///
    /// V2 只导出课程排布骨架，导入端复用本机的学期、首周和时间表；V1 导入仍保留兼容旧分享码。
    private func exportScheduleCode(allowEmptyCourseData: Bool = false) {
        let payload = ScheduleExportCompactPayloadV2(cache: viewModel.cache)
        guard allowEmptyCourseData || !payload.isEmpty else {
            isShowingEmptyScheduleExportConfirmation = true
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let jsonData = try encoder.encode(payload)
            guard let compressedData = try (jsonData as NSData).compressed(using: .lzfse) as Data? else {
                throw NSError(domain: "BIT101.ScheduleExport", code: -1, userInfo: [NSLocalizedDescriptionKey: "课表压缩失败。"])
            }
            let code = "BIT101SCH2:\(compressedData.base64EncodedString())"
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "BIT101.ScheduleImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "请输入或粘贴课表编码。"])
        }

        let supportedPrefixes = ["BIT101SCH1:", "BIT101SCH2:", "BIT101SCH3:"]
        if !supportedPrefixes.contains(where: { trimmed.hasPrefix($0) }),
           let colonIndex = trimmed.firstIndex(of: ":"),
           trimmed.hasPrefix("BIT101SCH") {
            let versionToken = trimmed[trimmed.index(trimmed.startIndex, offsetBy: "BIT101SCH".count) ..< colonIndex]
            if let version = Int(versionToken), version > 3 {
                throw NSError(domain: "BIT101.ScheduleImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "对方版本更高，请更新版本后再导入。"])
            }
        }

        guard let prefix = supportedPrefixes.first(where: { trimmed.hasPrefix($0) }) else {
            throw NSError(domain: "BIT101.ScheduleImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "课表编码格式不正确。"])
        }

        let body = String(trimmed.dropFirst(prefix.count))
        guard let compressedData = Data(base64Encoded: body) else {
            throw NSError(domain: "BIT101.ScheduleImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "课表编码无法解码。"])
        }

        guard let jsonData = try (compressedData as NSData).decompressed(using: .lzfse) as Data? else {
            throw NSError(domain: "BIT101.ScheduleImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "课表编码解压失败。"])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: ScheduleExportPayload
        switch prefix {
        case "BIT101SCH1:":
            payload = try decoder.decode(ScheduleExportPayload.self, from: jsonData)
        case "BIT101SCH2:":
            let compactPayload = try decoder.decode(ScheduleExportCompactPayloadV2.self, from: jsonData)
            payload = compactPayload.expandedPayload(using: viewModel.cache)
        case "BIT101SCH3:":
            let compactPayload = try decoder.decode(ScheduleExportCompactPayloadV3.self, from: jsonData)
            payload = compactPayload.expandedPayload(using: viewModel.cache)
        default:
            throw NSError(domain: "BIT101.ScheduleImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "课表编码格式不正确。"])
        }
        try viewModel.importSharedSchedule(payload)
        viewModel.notice = ScheduleNotice(title: "导入成功", message: "分享的课表已导入。考试、DDL 与自定义日程不会随导入覆盖。")
    }
}

/// 课表学期选择页。
///
/// 这里只展示学校接口实际返回的学期，不在本地追加、推算或生成任何选项。
/// 真正切换只有在课程、考试和首周全部获取成功后才落盘。
private struct ScheduleTermPickerPage: View {
    @ObservedObject var viewModel: ScheduleViewModel

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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .disabled(viewModel.isSyncingCourses || viewModel.isLoadingTerms || viewModel.cache.currentTerm == term)
                    }
                }
            }

        }
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
            } footer: {
                Text("起始日期固定为周一。选择其他日期时会自动调整到该日期所在周的周一。切换学期或重新同步时，App 会从学校校历接口重新获取。")
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
private struct ScheduleExportCodeSheet: View {
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
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
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
private struct ScheduleImportCodeSheet: View {
    let initialText: String
    let onImport: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var localAlert: AppAlert?

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
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

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
            .alert(item: $localAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
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
            .alert(item: $localAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
            }
        }
    }
}

/// DDL 设置页。
///
/// 这页只负责 DDL 同步和显示窗口配置，不再混入新增/编辑入口。
