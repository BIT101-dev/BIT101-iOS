import SwiftUI

struct ScheduleTermPickerPage: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @State private var selectionFeedbackToken = 0

    var body: some View {
        List {
            Section("选择学期") {
                if !viewModel.hasLoadedAvailableTerms {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    ForEach(viewModel.availableTerms, id: \.self) { term in
                        Button {
                            selectionFeedbackToken &+= 1
                            Task { await viewModel.syncCourses(term: term) }
                        } label: {
                            HStack(spacing: AppDesignSystem.Spacing.regular) {
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

/// 手动覆盖当前学期第一周日期的页面。
struct ScheduleFirstDayEditorPage: View {
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
struct CourseLiveActivityLeadMinutesPickerPage: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var value: Int
    @State private var draftValue: Int

    init(value: Binding<Int>) {
        _value = value
        _draftValue = State(initialValue: value.wrappedValue)
    }

    /// 使用原生 wheel picker 提供 1...60 分钟的阈值选择。
    var body: some View {
        Picker("提前显示阈值", selection: $draftValue) {
            ForEach(1 ... 60, id: \.self) { minute in
                Text("\(minute) 分钟")
                    .tag(minute)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .appSelectionFeedback(trigger: draftValue)
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
                    value = draftValue
                    dismiss()
                }
            }
        }
    }
}

/// 导出的课表压缩编码预览页。
///
/// 文本区域显示完整编码，用户可复制、分享或手动导入。
struct ScheduleExportCodeSheet: View {
    let code: String

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: AppDesignSystem.Spacing.section) {
                ScrollView {
                    Text(code)
                        .font(AppDesignSystem.Typography.footnoteMonospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppDesignSystem.Spacing.content)
                        .background(AppDesignSystem.Palette.secondaryGroupedBackground, in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))
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
            .padding(AppDesignSystem.Spacing.section)
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
/// 导入窗口提供两种入口：
/// - 手动粘贴/编辑编码
/// - 从剪贴板读取编码
struct ScheduleImportCodeSheet: View {
    let onImport: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var text: String
    @State private var localAlert: AppAlert?
    @State private var unsupportedFormatVersion: Int?

    init(initialText: String, onImport: @escaping (String) throws -> Void) {
        self.onImport = onImport
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: AppDesignSystem.Spacing.section) {
                TextEditor(text: $text)
                    .font(AppDesignSystem.Typography.footnoteMonospaced)
                    .frame(minHeight: AppDesignSystem.Schedule.settingsPanelMinimumHeight)
                    .padding(AppDesignSystem.Spacing.regular)
                    .background(AppDesignSystem.Palette.secondaryGroupedBackground, in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))
                    .accessibilityLabel("课表编码")

                HStack(spacing: AppDesignSystem.Spacing.content) {
                    Button {
                        guard let clipboard = UIPasteboard.general.string,
                              !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            localAlert = AppAlert.userInput(
                                title: "粘贴失败",
                                message: "剪贴板中没有可用的课表编码。"
                            )
                            return
                        }
                        text = clipboard
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
                                localAlert = AppAlert.userInput(title: "导入失败", message: error.localizedDescription)
                            }
                        } catch {
                            localAlert = AppAlert.userInput(title: "导入失败", message: error.localizedDescription)
                        }
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(AppDesignSystem.Spacing.section)
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
/// 主课表和分享课表共用这个重命名编辑器。
struct ScheduleRenameSheet: View {
    let title: String
    let onSubmit: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var localAlert: AppAlert?

    init(title: String, initialName: String, onSubmit: @escaping (String) throws -> Void) {
        self.title = title
        self.onSubmit = onSubmit
        _text = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("", text: $text, prompt: AppInputPrompt.text("课表名称"))
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
                            localAlert = AppAlert.userInput(title: "保存失败", message: error.localizedDescription)
                        }
                    }
                }
            }
            .diagnosticAlert(item: $localAlert)
        }
    }
}
