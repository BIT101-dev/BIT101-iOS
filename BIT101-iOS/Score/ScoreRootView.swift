import Combine
import SwiftUI
import UIKit

/// 原生成绩页状态机。
///
private enum ScoreSurface: String, CaseIterable, Identifiable {
    case score
    case course

    var id: String { rawValue }

    var title: String {
        switch self {
        case .score:
            return "成绩"
        case .course:
            return "课程"
        }
    }
}

/// 原生成绩与课程合并主页。
///
/// 负责承载“成绩 / 课程”的顶部切换。
struct ScoreRootView: View {
    @StateObject private var scoreViewModel = SchoolDataRefreshCoordinator.shared.scoreViewModel
    @StateObject private var courseViewModel = CourseListViewModel()
    @State private var selectedSurface: ScoreSurface = .score

    var body: some View {
        ZStack {
            switch selectedSurface {
            case .score:
                ScoreListPage(viewModel: scoreViewModel)
                    .simultaneousGesture(surfaceSwitchGesture)
                    .transition(.opacity)
            case .course:
                CoursePageContent(viewModel: courseViewModel)
                    .simultaneousGesture(surfaceSwitchGesture)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedSurface)
        .safeAreaInset(edge: .top) {
            Picker("成绩内容", selection: surfaceSelection) {
                ForEach(ScoreSurface.allCases) { surface in
                    Text(surface.title).tag(surface)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Color(.systemGroupedBackground))
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// 顶部 segmented 的受控绑定。
    ///
    /// 统一把点击切换和滑动切换都收束到同一条动画路径里。
    private var surfaceSelection: Binding<ScoreSurface> {
        Binding(
            get: { selectedSurface },
            set: { newSurface in
                switchSurface(to: newSurface)
            }
        )
    }

    /// 当前页的左右轻扫切换手势。
    private var surfaceSwitchGesture: some Gesture {
        makeHorizontalSwitchGesture(onStep: switchSurface)
    }

    /// 把当前分区切到相邻页。
    private func switchSurface(step: Int) {
        let allSurfaces = ScoreSurface.allCases
        guard let currentIndex = allSurfaces.firstIndex(of: selectedSurface) else { return }

        let nextIndex = currentIndex + step
        guard allSurfaces.indices.contains(nextIndex) else { return }

        switchSurface(to: allSurfaces[nextIndex])
    }

    /// 切换到指定分区，并统一施加渐变动画。
    private func switchSurface(to surface: ScoreSurface) {
        guard surface != selectedSurface else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            selectedSurface = surface
        }
    }
}

/// 成绩列表子页。
///
/// 保留原有“筛选 -> 统计 -> 列表”结构，只是被合并页托管。
private struct ScoreListPage: View {
    @ObservedObject var viewModel: ScoreViewModel

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView("正在查询成绩")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            case let .failed(message):
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重新查询") {
                        Task { await viewModel.refresh() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
            case .loaded:
                List {
                    Section {
                        HStack(spacing: 10) {
                            if viewModel.isSyncing {
                                ProgressView()
                                Text(viewModel.syncStatusText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                Text(viewModel.lastUpdatedText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section {
                        NavigationLink {
                            TrustedTranscriptPage()
                        } label: {
                            Label("申请可信成绩单", systemImage: "doc.text.image")
                        }
                        .disabled(viewModel.isSyncing)
                    }

                    Section {
                        NavigationLink {
                            ScoreFilterPage(
                                title: "学期筛选",
                                options: viewModel.availableTerms,
                                selectedValues: Binding(
                                    get: { viewModel.selectedTerms },
                                    set: { viewModel.setSelectedTerms($0) }
                                ),
                                onToggleAll: viewModel.toggleAllTerms
                            )
                        } label: {
                            LabeledContent("学期", value: selectionDescription(selected: viewModel.selectedTerms, all: viewModel.availableTerms))
                        }

                        NavigationLink {
                            ScoreFilterPage(
                                title: "种类筛选",
                                options: viewModel.availableCourseTypes,
                                selectedValues: Binding(
                                    get: { viewModel.selectedCourseTypes },
                                    set: { viewModel.setSelectedCourseTypes($0) }
                                ),
                                onToggleAll: viewModel.toggleAllCourseTypes
                            )
                        } label: {
                            LabeledContent("种类", value: selectionDescription(selected: viewModel.selectedCourseTypes, all: viewModel.availableCourseTypes))
                        }

                        NavigationLink {
                            ScoreSortPage(
                                sortIndex: Binding(
                                    get: { viewModel.sortIndex },
                                    set: { viewModel.setSortIndex($0) }
                                ),
                                sortOrder: Binding(
                                    get: { viewModel.sortOrder },
                                    set: { viewModel.setSortOrder($0) }
                                ),
                                onToggleOrder: viewModel.toggleSortOrder
                            )
                        } label: {
                            LabeledContent("排序", value: viewModel.sortDescription)
                        }
                    }

                    Section("统计") {
                        ScoreSummaryRow(title: "已出分", value: "\(viewModel.summary.selectedCourseCount)")
                        if let pendingCourseCount = viewModel.pendingCourseCount {
                            ScoreSummaryRow(title: "未出分", value: "\(pendingCourseCount)")
                        }
                        ScoreSummaryRow(title: "总学分", value: format(decimal: viewModel.summary.totalCredit))
                        ScoreSummaryRow(title: "加权平均分", value: format(optionalDecimal: viewModel.summary.weightedAverageScore))
                        ScoreSummaryRow(title: "加权 GPA", value: format(optionalDecimal: viewModel.summary.weightedAverageGPA))
                    }

                    Section("成绩列表") {
                        if viewModel.visibleRows.isEmpty {
                            ContentUnavailableView(
                                "暂无成绩",
                                systemImage: "chart.bar.doc.horizontal",
                                description: Text("请调整学期或种类筛选条件。")
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(viewModel.visibleRows) { row in
                                NavigationLink {
                                    ScoreDetailView(row: row)
                                } label: {
                                    ScoreRowCard(row: row)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let pendingCourses = viewModel.pendingCourses, !pendingCourses.isEmpty {
                        Section("未出分") {
                            ForEach(pendingCourses) { course in
                                NavigationLink {
                                    PendingScoreDetailView(course: course)
                                } label: {
                                    PendingScoreRowCard(course: course)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .background(Color(.systemGroupedBackground))
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
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
            ScoreSMSVerificationSheet(
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

    /// 统一格式化可选小数，没有值时显示占位符。
    private func format(optionalDecimal value: Double?) -> String {
        guard let value else { return "-" }
        return format(decimal: value)
    }

    /// 统一格式化成绩统计里的数值。
    private func format(decimal value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    /// 根据当前筛选状态生成一行摘要文本。
    private func selectionDescription(selected: Set<String>, all: [String]) -> String {
        guard !all.isEmpty else { return "-" }
        if selected.count == all.count {
            return "全部"
        }
        if selected.isEmpty {
            return "未选择"
        }
        let ordered = all.filter { selected.contains($0) }
        if ordered.count <= 2 {
            return ordered.joined(separator: "、")
        }
        return "\(ordered.prefix(2).joined(separator: "、")) 等 \(ordered.count) 项"
    }
}

/// 学校可信成绩单申请与预览页。
private struct TrustedTranscriptPage: View {
    @StateObject private var viewModel = TrustedTranscriptViewModel()
    @State private var imageViewer: GalleryImageViewerState?

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView("正在向学校申请可信成绩单")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("申请失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") {
                        Task { await viewModel.apply() }
                    }
                }
            case .loaded:
                if !viewModel.images.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(Array(viewModel.images.enumerated()), id: \.offset) { index, image in
                                Button {
                                    imageViewer = GalleryImageViewerState(
                                        localImages: viewModel.images,
                                        initialIndex: index
                                    )
                                } label: {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                    .background(Color(.secondarySystemBackground))
                }
            }
        }
        .navigationTitle("可信成绩单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .background(Color(.systemGroupedBackground))
        .task {
            // 从成绩页点进来就立即申请，不再增加一次确认操作。
            await viewModel.apply()
        }
        .gallerySystemImagePreview(item: $imageViewer)
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
            ScoreSMSVerificationSheet(
                challenge: challenge,
                isSubmitting: viewModel.isSubmittingSMSCode,
                errorMessage: viewModel.smsVerificationError,
                submitTitle: "验证并申请成绩单",
                onCancel: viewModel.dismissSMSChallenge,
                onSubmit: { code in
                    await viewModel.submitSMSCode(code)
                }
            )
        }
    }
}

/// 成绩页的原生短信验证码面板。
///
/// `.textContentType(.oneTimeCode)` 会让 iOS 从“来自信息”的验证码建议中自动填入，
/// 同时保留数字键盘供用户手动输入。
private struct ScoreSMSVerificationSheet: View {
    let challenge: BITLoginAuthenticationChallenge
    let isSubmitting: Bool
    let errorMessage: String?
    var submitTitle = "验证并查询成绩"
    let onCancel: () -> Void
    let onSubmit: (String) async -> Void

    @State private var code = ""
    @FocusState private var isCodeFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("短信验证码", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .font(.title2.monospacedDigit())
                        .focused($isCodeFieldFocused)
                        .disabled(isSubmitting)
                        .onChange(of: code) { _, newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(8))
                            if digits != newValue {
                                code = digits
                            }
                        }
                } header: {
                    Text("输入验证码")
                } footer: {
                    Text(verificationHint)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await onSubmit(code) }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                                    .padding(.trailing, 6)
                                Text("正在验证")
                            } else {
                                Text(submitTitle)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting || !(4 ... 8).contains(code.count))
                }
            }
            .navigationTitle("短信验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .disabled(isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .onAppear {
                isCodeFieldFocused = true
            }
        }
        .presentationDetents([.medium])
    }

    private var verificationHint: String {
        if let maskedPhone = challenge.maskedPhone, !maskedPhone.isEmpty {
            return "学校统一身份认证要求二次验证，验证码已发送至 \(maskedPhone)。可点击键盘上方建议自动填充。"
        }
        return "学校统一身份认证要求二次验证，验证码已发送至绑定手机。可点击键盘上方建议自动填充。"
    }
}

/// 统计区单行展示。
///
/// 只是一个轻量包装，让统计 section 的几行 `LabeledContent` 看起来更统一。
private struct ScoreSummaryRow: View {
    let title: String
    let value: String

    /// 统计项的单行展示。
    var body: some View {
        LabeledContent(title, value: value)
    }
}

/// 成绩卡片。
///
/// 列表页使用更紧凑的两行布局，详情页再看完整字段。
private struct ScoreRowCard: View {
    let row: ScoreRow

    /// 列表态成绩卡片的紧凑布局。
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScoreFixedColumnRow(
                items: [
                    ScoreFixedColumnItem(
                        text: row.courseName.isEmpty ? "未命名课程" : row.courseName,
                        ratio: 0.55,
                        font: .headline,
                        color: .primary,
                    ),
                    ScoreFixedColumnItem(
                        text: formattedCredit,
                        ratio: 0.15,
                        font: .caption,
                        color: .secondary,
                    ),
                    ScoreFixedColumnItem(
                        text: row.term.isEmpty ? "-" : row.term,
                        ratio: 0.3,
                        font: .caption,
                        color: .secondary,
                        alignment: .trailing
                    ),
                ],
                height: 22
            )

            ScoreFixedColumnRow(
                items: [
                    ScoreFixedColumnItem(
                        text: "成绩 \(row.score.isEmpty ? "-" : row.score)",
                        ratio: 0.25,
                        font: .subheadline.weight(.semibold),
                        color: .primary
                    ),
                    ScoreFixedColumnItem(
                        text: "均分 \(formattedAverageScore)",
                        ratio: 0.45,
                        font: .subheadline.weight(.semibold),
                        color: .primary,
                    ),
                    ScoreFixedColumnItem(
                        text: row.courseType.isEmpty ? "-" : row.courseType,
                        ratio: 0.3,
                        font: .caption,
                        color: .secondary,
                        alignment: .trailing
                    ),
                ],
                height: 20
            )
        }
        .padding(.vertical, 4)
    }

    /// 学分字段在列表里的展示格式。
    private var formattedCredit: String {
        let trimmed = row.creditText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        return "\(trimmed)分"
    }

    /// 均分字段统一保留两位小数。
    private var formattedAverageScore: String {
        let trimmed = row.averageScore.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        guard let value = Double(trimmed) else { return trimmed }
        return value.formatted(.number.precision(.fractionLength(2)))
    }
}

/// “未出分”分区中的课程占位卡片。
///
/// 列宽和已出分课程保持一致，但在列表层级上单独归入“未出分”分区。
private struct PendingScoreRowCard: View {
    let course: CourseRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScoreFixedColumnRow(
                items: [
                    ScoreFixedColumnItem(
                        text: course.name.isEmpty ? "未命名课程" : course.name,
                        ratio: 0.55,
                        font: .headline,
                        color: .primary
                    ),
                    ScoreFixedColumnItem(
                        text: course.credit > 0 ? "\(course.credit)分" : "-",
                        ratio: 0.15,
                        font: .caption,
                        color: .secondary
                    ),
                    ScoreFixedColumnItem(
                        text: course.term.isEmpty ? "-" : course.term,
                        ratio: 0.3,
                        font: .caption,
                        color: .secondary,
                        alignment: .trailing
                    ),
                ],
                height: 22
            )

            ScoreFixedColumnRow(
                items: [
                    ScoreFixedColumnItem(
                        text: "成绩 -",
                        ratio: 0.25,
                        font: .subheadline.weight(.semibold),
                        color: .primary
                    ),
                    ScoreFixedColumnItem(
                        text: "均分 -",
                        ratio: 0.45,
                        font: .subheadline.weight(.semibold),
                        color: .primary
                    ),
                    ScoreFixedColumnItem(
                        text: course.type.isEmpty ? "-" : course.type,
                        ratio: 0.3,
                        font: .caption,
                        color: .secondary,
                        alignment: .trailing
                    ),
                ],
                height: 20
            )
        }
        .padding(.vertical, 4)
    }
}

/// 未出分课程详情页。
///
/// 数据来自对应学期的课表缓存，因此展示课表能够确认的课程信息；成绩和均分在
/// 教务系统发布前统一显示为横杠。
private struct PendingScoreDetailView: View {
    let course: CourseRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(course.name.isEmpty ? "未命名课程" : course.name)
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 18) {
                        Text("成绩 -")
                        Text("均分 -")
                        Text(course.credit > 0 ? "学分 \(course.credit)" : "学分 -")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        ScoreDetailMetaRow(title: "课程号", value: course.number)
                        ScoreDetailMetaRow(title: "学期", value: course.term)
                        ScoreDetailMetaRow(title: "课程性质", value: course.type)
                    }
                    .font(.subheadline)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("课程信息")
                        .font(.headline)
                    ScoreDetailMetaRow(title: "教师", value: course.teacher)
                    ScoreDetailMetaRow(title: "教室", value: course.classroom)
                    ScoreDetailMetaRow(title: "校区", value: course.campus)
                    ScoreDetailMetaRow(title: "上课时间", value: scheduleText)
                    ScoreDetailMetaRow(title: "教学周", value: weeksText)
                    ScoreDetailMetaRow(title: "学时", value: course.hour > 0 ? "\(course.hour)" : "-")
                    if !course.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ScoreDetailMetaRow(title: "备注", value: course.description)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("成绩详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var scheduleText: String {
        guard (1...7).contains(course.weekday), course.startSection > 0 else { return "-" }
        let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
        let section = course.endSection > course.startSection
            ? "第\(course.startSection)-\(course.endSection)节"
            : "第\(course.startSection)节"
        return "星期\(weekdays[course.weekday - 1]) \(section)"
    }

    private var weeksText: String {
        guard !course.weeks.isEmpty else { return "-" }
        return ScheduleCourseEditor.formatWeeks(course.weeks)
            .replacingOccurrences(of: ",", with: "、")
    }
}

/// 成绩详情页。
///
/// 由列表直接 push 进入，使用平铺信息流替代旧的抽屉式详情。
private struct ScoreDetailView: View {
    let row: ScoreRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summarySection
                Divider()
                detailSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("成绩详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.courseName.isEmpty ? "未命名课程" : row.courseName)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 18) {
                Text("成绩 \(row.score.isEmpty ? "-" : row.score)")
                Text("均分 \(formattedAverageScore)")
                Text(formattedCredit)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ScoreDetailMetaRow(title: "课程号", value: row.courseNumber)
                ScoreDetailMetaRow(title: "学期", value: row.term)
                ScoreDetailMetaRow(title: "课程性质", value: row.courseType)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("详细信息")
                .font(.headline)

            if remainingFields.isEmpty {
                Text("暂无更多信息")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(remainingFields.enumerated()), id: \.offset) { index, field in
                        VStack(spacing: 0) {
                            ScoreDetailFieldRow(field: field)

                            if index != remainingFields.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var remainingFields: [ScoreField] {
        let hiddenKeys: Set<String> = ["课程名称", "成绩", "平均分", "学分", "课程编号", "开课学期", "课程性质"]
        return row.values.filter { field in
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && !hiddenKeys.contains(field.key)
        }
    }

    private var formattedCredit: String {
        let trimmed = row.creditText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "学分 -" }
        return "学分 \(trimmed)"
    }

    private var formattedAverageScore: String {
        let trimmed = row.averageScore.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        guard let value = Double(trimmed) else { return trimmed }
        return value.formatted(.number.precision(.fractionLength(2)))
    }
}

private struct ScoreDetailMetaRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title, value: value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "-" : value)
    }
}

private struct ScoreDetailFieldRow: View {
    let field: ScoreField

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(field.key)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)

            Text(field.value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }
}

/// 成绩卡片里的单列定义。
///
/// 用固定比例列把两行信息对齐，避免不同长度课程名把后面的字段全部挤歪。
private struct ScoreFixedColumnItem {
    let text: String
    let ratio: CGFloat
    let font: Font
    let color: Color
    var alignment: Alignment = .leading
}

/// 按固定比例切分宽度的一行文本。
private struct ScoreFixedColumnRow: View {
    let items: [ScoreFixedColumnItem]
    let height: CGFloat

    /// 按比例切分宽度的一整行内容。
    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Text(item.text)
                        .font(item.font)
                        .foregroundStyle(item.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .monospacedDigit()
                        .frame(
                            width: totalWidth * item.ratio,
                            height: height,
                            alignment: item.alignment
                        )
                }
            }
        }
        .frame(height: height)
    }
}
