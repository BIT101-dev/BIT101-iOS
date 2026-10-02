import ScoreDomain
#if os(iOS)
import ClientCore
import DesignSystemKit
import MediaKit
import SwiftUI
import UIKit

public struct ScoreListPage: View {
    @ObservedObject var viewModel: ScoreViewModel
    let onSearchCourse: (String) -> Void
    let transcriptService: any TrustedTranscriptServicing

    public init(viewModel: ScoreViewModel, transcriptService: any TrustedTranscriptServicing, onSearchCourse: @escaping (String) -> Void) {
        self.viewModel = viewModel
        self.transcriptService = transcriptService
        self.onSearchCourse = onSearchCourse
    }

    public var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                AppLoadingState(title: "正在查询成绩")
                    .background(AppDesignSystem.Palette.Background.grouped)
            case let .failed(message):
                AppFailureState(
                    title: "加载失败",
                    systemImage: "exclamationmark.triangle",
                    message: message,
                    retryTitle: "重新查询",
                    allowsDiagnostics: viewModel.allowsDiagnostics,
                    onRetry: {
                        Task { await viewModel.refresh() }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppDesignSystem.Palette.Background.grouped)
            case .loaded:
                List {
                    Section {
                        AppRefreshStatusRow(
                            isRefreshing: viewModel.isSyncing,
                            refreshingText: viewModel.syncStatusText,
                            lastUpdatedText: viewModel.lastUpdatedText,
                            actionTitle: viewModel.rows.isEmpty ? "查询成绩" : "刷新",
                            onRefresh: {
                                Task { await viewModel.refresh() }
                            },
                            actionAccessibilityIdentifier: "score.query"
                        )
                    }

                    Section {
                        NavigationLink {
                            TrustedTranscriptPage(service: transcriptService)
                        } label: {
                            Text("申请可信成绩单")
                        }
                        .disabled(viewModel.isSyncing)
                        .appInteractiveListRow()
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
                        .appInteractiveListRow()

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
                        .appInteractiveListRow()

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
                        .appInteractiveListRow()
                    }

                    Section("统计") {
                        LabeledContent("已出分", value: "\(viewModel.summary.selectedCourseCount)")
                        if let pendingCourseCount = viewModel.pendingCourseCount {
                            LabeledContent("未出分", value: "\(pendingCourseCount)")
                        }
                        LabeledContent("总学分", value: formatScoreDecimal(viewModel.summary.totalCredit))
                        LabeledContent("加权平均分", value: formatOptionalScore(viewModel.summary.weightedAverageScore))
                        LabeledContent("加权 GPA", value: formatOptionalScore(viewModel.summary.weightedAverageGPA))
                    }

                    Section("成绩列表") {
                        if viewModel.visibleRows.isEmpty {
                            AppEmptyState(
                                title: "暂无成绩",
                                systemImage: "chart.bar.doc.horizontal",
                                message: "当前筛选条件下暂无成绩。"
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(Array(viewModel.visibleRows.enumerated()), id: \.offset) { _, row in
                                NavigationLink {
                                    ScoreDetailView(
                                        row: row,
                                        onSearchCourse: onSearchCourse
                                    )
                                } label: {
                                    ScoreListRowCard(row: row)
                                }
                                .buttonStyle(.plain)
                                .appInteractiveListRow()
                            }
                        }
                    }

                    if let pendingCourses = viewModel.pendingCourses, !pendingCourses.isEmpty {
                        Section("未出分") {
                            ForEach(pendingCourses) { course in
                                NavigationLink {
                                    PendingScoreDetailView(course: course)
                                } label: {
                                    ScoreListRowCard(course: course)
                                }
                                .buttonStyle(.plain)
                                .appInteractiveListRow()
                            }
                        }
                    }
                }
                .appGroupedListStyle()
                .background(AppDesignSystem.Palette.Background.grouped)
            }
        }
        .task {
            await viewModel.restoreCachedDataIfNeeded()
        }
        .diagnosticAlert(item: $viewModel.alert)
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
                submitTitle: "验证并查询成绩",
                onCancel: viewModel.dismissSMSChallenge,
                onSubmit: { code in
                    await viewModel.submitSMSCode(code)
                }
            )
        }
    }

    /// 该方法根据当前筛选状态生成摘要文本。
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
    @StateObject private var viewModel: TrustedTranscriptViewModel
    @State private var imageViewer: ImagePreviewRequest?

    init(service: any TrustedTranscriptServicing) {
        _viewModel = StateObject(wrappedValue: TrustedTranscriptViewModel(service: service))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                AppLoadingState(title: "正在向学校申请可信成绩单")
            case let .failed(message):
                AppFailureState(
                    title: "申请失败",
                    systemImage: "exclamationmark.triangle",
                    message: message,
                    allowsDiagnostics: viewModel.allowsDiagnostics,
                    onRetry: {
                        Task { await viewModel.apply() }
                    }
                )
            case .loaded:
                if viewModel.images.isEmpty {
                    AppEmptyState(
                        title: "暂无可信成绩单",
                        systemImage: "doc.text",
                        message: "学校暂未返回成绩单图片。"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                            LazyVStack(spacing: AppDesignSystem.Spacing.content) {
                                ForEach(Array(viewModel.images.enumerated()), id: \.offset) { index, image in
                                    Button {
                                        imageViewer = ImagePreviewRequest(localImages: viewModel.images, initialIndex: index)
                                    } label: {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFit()
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("可信成绩单第\(index + 1)页")
                                    .accessibilityValue("共\(viewModel.images.count)页")
                                    .accessibilityHint("双击查看大图")
                                }
                            }
                            .padding(AppDesignSystem.Spacing.section)
                    }
                    .background(AppDesignSystem.Palette.Background.secondary)
                }
            }
        }
        .navigationTitle("可信成绩单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .background(AppDesignSystem.Palette.Background.grouped)
        .systemImagePreview(item: $imageViewer)
        .task {
            // 页面从成绩页进入后立即申请可信成绩单，入口直接执行申请操作。
            await viewModel.applyIfNeeded()
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
                submitTitle: "验证并申请成绩单",
                onCancel: viewModel.dismissSMSChallenge,
                onSubmit: { code in
                    await viewModel.submitSMSCode(code)
                }
            )
        }
    }
}

/// 成绩列表行卡片。
///
/// 已出分和未出分课程共用两行列布局，初始化器提供各自的显示字段。
private struct ScoreListRowCard: View {
    let courseName: String
    let creditText: String
    let termText: String
    let scoreText: String
    let averageScoreText: String
    let courseTypeText: String

    private init(
        courseName: String,
        creditText: String,
        termText: String,
        scoreText: String,
        averageScoreText: String,
        courseTypeText: String
    ) {
        self.courseName = courseName
        self.creditText = creditText
        self.termText = termText
        self.scoreText = scoreText
        self.averageScoreText = averageScoreText
        self.courseTypeText = courseTypeText
    }

    init(row: ScoreRow) {
        let courseName = Self.trimmed(row.courseName)
        let credit = Self.trimmed(row.creditText)
        let term = Self.trimmed(row.term)
        let score = Self.trimmed(row.score)
        let courseType = Self.trimmed(row.courseType)
        self.init(
            courseName: courseName.isEmpty ? "未命名课程" : courseName,
            creditText: credit.isEmpty ? "-" : "\(credit)学分",
            termText: term.isEmpty ? "-" : term,
            scoreText: score.isEmpty ? "-" : score,
            averageScoreText: formatScoreText(row.averageScore),
            courseTypeText: courseType.isEmpty ? "-" : courseType
        )
    }

    init(course: ScoreCourseSummary) {
        let courseName = Self.trimmed(course.name)
        let term = Self.trimmed(course.term)
        let courseType = Self.trimmed(course.type)
        self.init(
            courseName: courseName.isEmpty ? "未命名课程" : courseName,
            creditText: course.creditText != "-" ? "\(course.creditText)学分" : "-",
            termText: term.isEmpty ? "-" : term,
            scoreText: "-",
            averageScoreText: "-",
            courseTypeText: courseType.isEmpty ? "-" : courseType
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
            AppFixedColumnRow(
                items: [
                    AppFixedColumnItem(
                        text: courseName,
                        ratio: 0.55,
                        font: AppDesignSystem.Typography.title,
                        color: AppDesignSystem.Foreground.primaryColor,
                    ),
                    AppFixedColumnItem(
                        text: creditText,
                        ratio: 0.15,
                        font: AppDesignSystem.Typography.caption,
                        color: AppDesignSystem.Foreground.secondaryColor,
                    ),
                    AppFixedColumnItem(
                        text: termText,
                        ratio: 0.3,
                        font: AppDesignSystem.Typography.caption,
                        color: AppDesignSystem.Foreground.secondaryColor,
                        alignment: .trailing
                    ),
                ],
                height: AppDesignSystem.Size.CompactRow.primaryHeight
            )

            AppFixedColumnRow(
                items: [
                    AppFixedColumnItem(
                        text: "成绩 \(scoreText)",
                        ratio: 0.25,
                        font: AppDesignSystem.Typography.subheadlineEmphasis,
                        color: AppDesignSystem.Foreground.primaryColor
                    ),
                    AppFixedColumnItem(
                        text: "均分 \(averageScoreText)",
                        ratio: 0.45,
                        font: AppDesignSystem.Typography.subheadlineEmphasis,
                        color: AppDesignSystem.Foreground.primaryColor,
                    ),
                    AppFixedColumnItem(
                        text: courseTypeText,
                        ratio: 0.3,
                        font: AppDesignSystem.Typography.caption,
                        color: AppDesignSystem.Foreground.secondaryColor,
                        alignment: .trailing
                    ),
                ],
                height: AppDesignSystem.Size.CompactRow.secondaryHeight
            )
        }
        .padding(.vertical, AppDesignSystem.Spacing.tiny)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        "\(courseName)，\(creditText)，\(termText)，成绩 \(scoreText)，均分 \(averageScoreText)，\(courseTypeText)"
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 未出分课程详情页。
///
/// 页面依据对应学期课表缓存展示课程信息；教务系统发布成绩前，成绩和均分显示为横杠。
private struct PendingScoreDetailView: View {
    let course: ScoreCourseSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.section) {
                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
                    let courseName = course.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(courseName.isEmpty ? "未命名课程" : courseName)
                        .font(AppDesignSystem.Typography.titleEmphasis)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: AppDesignSystem.Spacing.section) {
                        Text("成绩 -")
                        Text("均分 -")
                        Text(course.creditText != "-" ? "学分 \(course.creditText)" : "学分 -")
                    }
                    .font(AppDesignSystem.Typography.body)
                    .foregroundStyle(AppDesignSystem.Foreground.secondary)

                    VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                        ScoreDetailMetaRow(title: "课程号", value: course.number)
                        ScoreDetailMetaRow(title: "学期", value: course.term)
                        ScoreDetailMetaRow(title: "课程性质", value: course.type)
                    }
                    .font(AppDesignSystem.Typography.body)
                }

                Divider()

                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                    Text("课程信息")
                        .font(AppDesignSystem.Typography.title)
                    ScoreDetailMetaRow(title: "教师", value: course.teacher)
                    ScoreDetailMetaRow(title: "教室", value: course.classroom)
                    ScoreDetailMetaRow(title: "校区", value: course.campus)
                    ScoreDetailMetaRow(title: "上课时间", value: course.scheduleText)
                    ScoreDetailMetaRow(title: "教学周", value: course.weeksText)
                    ScoreDetailMetaRow(title: "学时", value: course.hourText)
                    if !course.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ScoreDetailMetaRow(title: "备注", value: course.description)
                    }
                }
            }
            .padding(.horizontal, AppDesignSystem.Spacing.section)
            .padding(.top, AppDesignSystem.Spacing.section)
            .padding(.bottom, AppDesignSystem.Spacing.section)
        }
        .background(AppDesignSystem.Palette.Background.grouped)
        .navigationTitle("成绩详情")
        .navigationBarTitleDisplayMode(.inline)
    }

}

private struct ScoreDetailMetaRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(
            title,
            value: displayValue
        )
    }

    private var displayValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "-" : trimmed
    }
}

/// 成绩详情页。
///
/// 页面以分组列表展示成绩、课程评价、课程信息和其它字段。
private struct ScoreDetailView: View {
    let row: ScoreRow
    let onSearchCourse: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                let courseName = row.courseName.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(courseName.isEmpty ? "未命名课程" : courseName)
                    .font(AppDesignSystem.Typography.title)
                LabeledContent("成绩", value: displayValue(row.score))
                LabeledContent("平均分", value: formattedAverageScore)
                LabeledContent("学分", value: formattedCreditValue)
            }

            Section("课程评价") {
                courseEvaluationLink
            }

            Section("课程信息") {
                LabeledContent("课程号", value: displayValue(row.courseNumber))
                LabeledContent("学期", value: displayValue(row.term))
                LabeledContent("课程性质", value: displayValue(row.courseType))
            }

            Section("详细信息") {
                if remainingFields.isEmpty {
                    Text("暂无更多信息")
                } else {
                    ForEach(Array(remainingFields.enumerated()), id: \.offset) { _, field in
                        LabeledContent(field.key, value: displayValue(field.value))
                    }
                }
            }
        }
        .appGroupedListStyle()
        .navigationTitle("成绩详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var courseEvaluationLink: some View {
        Button {
            dismiss()
            onSearchCourse(row.courseName)
        } label: {
            AppCourseEvaluationRow()
        }
        .buttonStyle(.plain)
        .appInteractiveListRow()
    }

    private var remainingFields: [ScoreField] {
        let hiddenKeys: Set<String> = ["课程名称", "成绩", "平均分", "学分", "课程编号", "开课学期", "课程性质"]
        return row.values.filter { field in
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && !hiddenKeys.contains(field.key)
        }
    }

    private var formattedCreditValue: String {
        let trimmed = row.creditText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "-" : trimmed
    }

    private var formattedAverageScore: String {
        formatScoreText(row.averageScore)
    }

    private func displayValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "-" : trimmed
    }
}

private func formatScoreDecimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(2)))
}

private func formatOptionalScore(_ value: Double?) -> String {
    guard let value else { return "-" }
    return formatScoreDecimal(value)
}

private func formatScoreText(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "-" }
    guard let value = Double(trimmed) else { return trimmed }
    return formatScoreDecimal(value)
}

#endif
