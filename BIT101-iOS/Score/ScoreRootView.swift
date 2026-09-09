import SwiftUI

private enum ScoreSurface: String, CaseIterable, Identifiable, Hashable {
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

/// 成绩与课程合并主页。
///
/// 页面提供“成绩 / 课程”的顶部切换。
struct ScoreRootView: View {
    @StateObject private var scoreViewModel = SchoolDataViewModelStore.shared.scoreViewModel
    @StateObject private var courseViewModel = CourseListViewModel()
    @State private var selectedSurface: ScoreSurface = .score
    @Binding private var requestedCourse: CourseNavigationRequest?

    init(requestedCourse: Binding<CourseNavigationRequest?> = .constant(nil)) {
        _requestedCourse = requestedCourse
    }

    var body: some View {
        ZStack {
            switch selectedSurface {
            case .score:
                ScoreListPage(
                    viewModel: scoreViewModel,
                    onSearchCourse: openCourseSearch
                )
                    .simultaneousGesture(surfaceSwitchGesture)
                    .transition(.opacity)
            case .course:
                CoursePageContent(viewModel: courseViewModel)
                    .simultaneousGesture(surfaceSwitchGesture)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: selectedSurface)
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            AppTopSegmentedPicker(title: "成绩内容", selection: surfaceSelection) {
                ForEach(ScoreSurface.allCases) { surface in
                    Text(surface.title).tag(surface)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $requestedCourse) { request in
            if let preparedCourse = request.preparedCourse {
                CourseDetailView(initialCourse: preparedCourse)
                    .id(preparedCourse.id)
            } else {
                CourseEvaluationDestination(request: request)
            }
        }
        .task(id: requestedCourse?.id) {
            guard let requestedCourse else { return }
            selectedSurface = .course
            prepareCourseSurface(requestedCourse)
        }
    }

    /// 成绩记录缺少教师字段时，页面进入课程搜索页，由用户选择具体教师。
    private func openCourseSearch(_ courseName: String) {
        selectedSurface = .course
        requestedCourse = nil
        Task {
            await courseViewModel.search(for: courseName)
        }
    }

    private func prepareCourseSurface(_ request: CourseNavigationRequest) {
        guard let query = request.searchQuery,
              let results = request.searchResults
        else { return }
        courseViewModel.applyPreparedSearch(query: query, items: results)
    }

    /// 页面使用受控绑定切换顶部 segmented 分区。
    ///
    /// 点击和滑动切换都调用同一条分区切换路径并播放动画。
    private var surfaceSelection: Binding<ScoreSurface> {
        Binding(
            get: { selectedSurface },
            set: { newSurface in
                switchSurface(to: newSurface)
            }
        )
    }

    /// 该手势使用左右轻扫切换分区。
    private var surfaceSwitchGesture: some Gesture {
        makeHorizontalSwitchGesture(onStep: switchSurface)
    }

    /// 该方法按步长将当前分区切换到相邻分区。
    private func switchSurface(step: Int) {
        let allSurfaces = ScoreSurface.allCases
        guard let currentIndex = allSurfaces.firstIndex(of: selectedSurface) else { return }

        let nextIndex = currentIndex + step
        guard allSurfaces.indices.contains(nextIndex) else { return }

        switchSurface(to: allSurfaces[nextIndex])
    }

    /// 该方法切换指定分区并播放渐变动画。
    private func switchSurface(to surface: ScoreSurface) {
        guard surface != selectedSurface else { return }

        withAnimation(.easeInOut) {
            selectedSurface = surface
        }
    }
}

/// 成绩列表页面。
///
/// 页面展示筛选、统计和成绩列表。
private struct ScoreListPage: View {
    @ObservedObject var viewModel: ScoreViewModel
    let onSearchCourse: (String) -> Void

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                AppLoadingState(title: "正在查询成绩")
                    .background(AppDesignSystem.Palette.groupedBackground)
            case let .failed(message):
                AppFailureState(
                    title: "加载失败",
                    systemImage: "exclamationmark.triangle",
                    message: message,
                    retryTitle: "重新查询",
                    onRetry: {
                        Task { await viewModel.refresh() }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppDesignSystem.Palette.groupedBackground)
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
                            }
                        )
                    }

                    Section {
                        NavigationLink {
                            TrustedTranscriptPage()
                        } label: {
                            Text("申请可信成绩单")
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
                                message: "请调整学期或种类筛选条件。"
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(viewModel.visibleRows) { row in
                                NavigationLink {
                                    ScoreDetailView(
                                        row: row,
                                        onSearchCourse: onSearchCourse
                                    )
                                } label: {
                                    ScoreListRowCard(row: row)
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
                                    ScoreListRowCard(course: course)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .appGroupedListStyle()
                .background(AppDesignSystem.Palette.groupedBackground)
            }
        }
        .task {
            viewModel.restoreCachedDataIfNeeded()
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
                challenge: challenge,
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
    @StateObject private var viewModel = TrustedTranscriptViewModel()
    @State private var imageViewer: GalleryImageViewerState?

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
                    .background(AppDesignSystem.Palette.secondaryBackground)
                }
            }
        }
        .navigationTitle("可信成绩单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .background(AppDesignSystem.Palette.groupedBackground)
        .task {
            // 页面从成绩页进入后立即申请可信成绩单，入口直接执行申请操作。
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
            AppSMSVerificationSheet(
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
        let credit = row.creditText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            courseName: row.courseName.isEmpty ? "未命名课程" : row.courseName,
            creditText: credit.isEmpty ? "-" : "\(credit)分",
            termText: row.term.isEmpty ? "-" : row.term,
            scoreText: row.score.isEmpty ? "-" : row.score,
            averageScoreText: formatScoreText(row.averageScore),
            courseTypeText: row.courseType.isEmpty ? "-" : row.courseType
        )
    }

    init(course: CourseRecord) {
        self.init(
            courseName: course.name.isEmpty ? "未命名课程" : course.name,
            creditText: course.credit > 0 ? "\(course.credit)分" : "-",
            termText: course.term.isEmpty ? "-" : course.term,
            scoreText: "-",
            averageScoreText: "-",
            courseTypeText: course.type.isEmpty ? "-" : course.type
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tight) {
            AppFixedColumnRow(
                items: [
                    AppFixedColumnItem(
                        text: courseName,
                        ratio: 0.55,
                        font: .headline,
                        color: .primary,
                    ),
                    AppFixedColumnItem(
                        text: creditText,
                        ratio: 0.15,
                        font: .caption,
                        color: .secondary,
                    ),
                    AppFixedColumnItem(
                        text: termText,
                        ratio: 0.3,
                        font: .caption,
                        color: .secondary,
                        alignment: .trailing
                    ),
                ],
                height: AppDesignSystem.Size.compactRow.primaryHeight
            )

            AppFixedColumnRow(
                items: [
                    AppFixedColumnItem(
                        text: "成绩 \(scoreText)",
                        ratio: 0.25,
                        font: .subheadline.weight(.semibold),
                        color: .primary
                    ),
                    AppFixedColumnItem(
                        text: "均分 \(averageScoreText)",
                        ratio: 0.45,
                        font: .subheadline.weight(.semibold),
                        color: .primary,
                    ),
                    AppFixedColumnItem(
                        text: courseTypeText,
                        ratio: 0.3,
                        font: .caption,
                        color: .secondary,
                        alignment: .trailing
                    ),
                ],
                height: AppDesignSystem.Size.compactRow.secondaryHeight
            )
        }
        .padding(.vertical, AppDesignSystem.Spacing.tiny)
    }
}

/// 未出分课程详情页。
///
/// 页面依据对应学期课表缓存展示课程信息；教务系统发布成绩前，成绩和均分显示为横杠。
private struct PendingScoreDetailView: View {
    let course: CourseRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.prominent) {
                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
                    Text(course.name.isEmpty ? "未命名课程" : course.name)
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: AppDesignSystem.Spacing.prominent) {
                        Text("成绩 -")
                        Text("均分 -")
                        Text(course.credit > 0 ? "学分 \(course.credit)" : "学分 -")
                    }
                    .font(AppDesignSystem.Typography.body)
                    .foregroundStyle(.secondary)

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
            .padding(.horizontal, AppDesignSystem.Spacing.prominent)
            .padding(.top, AppDesignSystem.Spacing.prominent)
            .padding(.bottom, AppDesignSystem.Spacing.prominent)
        }
        .background(AppDesignSystem.Palette.groupedBackground)
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

private struct ScoreDetailMetaRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(
            title,
            value: value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "-" : value
        )
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
                Text(row.courseName.isEmpty ? "未命名课程" : row.courseName)
                LabeledContent("成绩", value: row.score.isEmpty ? "-" : row.score)
                LabeledContent("平均分", value: formattedAverageScore)
                LabeledContent("学分", value: formattedCreditValue)
            }

            Section("课程评价") {
                courseEvaluationLink
            }

            Section("课程信息") {
                LabeledContent("课程号", value: row.courseNumber)
                LabeledContent("学期", value: row.term)
                LabeledContent("课程性质", value: row.courseType)
            }

            Section("详细信息") {
                if remainingFields.isEmpty {
                    Text("暂无更多信息")
                } else {
                    ForEach(Array(remainingFields.enumerated()), id: \.offset) { _, field in
                        LabeledContent(field.key, value: field.value)
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
