//
//  CourseDetailView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-02.
//

import Charts
import SwiftUI

/// 课程详情页。
    struct CourseDetailView: View {
    private struct UserRoute: Identifiable, Hashable {
        let userID: Int
        var id: Int { userID }
    }

    let initialCourse: CourseSummary

    @Environment(\.openURL) private var openURL
    @ObservedObject private var settings = AppSettingsStore.shared
    @StateObject private var viewModel: CourseDetailViewModel
    @State private var composerTarget: CourseCommentComposerTarget?
    @State private var imageViewer: GalleryImageViewerState?
    @State private var userRoute: UserRoute?
    @State private var isShowingHistoryGrades = false

    init(initialCourse: CourseSummary) {
        self.initialCourse = initialCourse
        _viewModel = StateObject(wrappedValue: CourseDetailViewModel(initialCourse: initialCourse))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summarySection
                metricsSection
                courseResourcesSection
                Divider()

                CourseCommentsSection(
                    comments: filteredComments,
                    totalCommentCount: viewModel.resolvedCommentNum,
                    status: viewModel.commentState.status,
                    isLoadingMore: viewModel.commentState.isLoadingMore,
                    likingCommentIDs: viewModel.likingCommentIDs,
                    onReply: { target in
                        composerTarget = .comment(mainComment: target.mainComment, targetComment: target.targetComment)
                    },
                    onLikeComment: { comment in
                        Task {
                            await viewModel.likeComment(comment)
                        }
                    },
                    onOpenImage: { index, images in
                        imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                    },
                    onOpenUser: { user in
                        guard user.id > 0 else { return }
                        userRoute = UserRoute(userID: user.id)
                    },
                    onLoadMore: { comment in
                        Task {
                            await viewModel.loadMoreCommentsIfNeeded(currentComment: comment)
                        }
                    }
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("课程详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationDestination(item: $userRoute) { route in
            UserProfileRootView(userID: route.userID)
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .sheet(item: $composerTarget) { target in
            CourseCommentComposerSheet(
                target: target,
                isSubmitting: viewModel.isSubmittingComment
            ) { text, anonymous, rate in
                Task {
                    let success = await viewModel.submitComment(text: text, anonymous: anonymous, rate: rate, target: target)
                    if success {
                        composerTarget = nil
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingHistoryGrades) {
            CourseHistoryGradesSheet(
                grades: viewModel.historyGrades,
                status: viewModel.historyGradeStatus,
                onRetry: {
                    await viewModel.reloadHistoryGrades()
                }
            )
            .task {
                await viewModel.loadHistoryGradesIfNeeded()
            }
        }
        .fullScreenCover(item: $imageViewer) { viewer in
            GalleryImageViewer(viewer: viewer)
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(viewModel.resolvedName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button {
                        composerTarget = .course(courseID: initialCourse.id)
                    } label: {
                        Image(systemName: "bubble.right")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .background(Color.orange.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            await viewModel.likeCourse()
                        }
                    } label: {
                        Group {
                            if viewModel.isLikingCourse {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: viewModel.isCourseLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                                    .font(.headline)
                            }
                        }
                        .foregroundStyle(viewModel.isCourseLiked ? Color.orange : Color.primary)
                        .frame(width: 34, height: 34)
                        .background(Color.orange.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLikingCourse)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("课程号", value: viewModel.resolvedNumber)
                LabeledContent("学分", value: viewModel.resolvedCreditText)
                LabeledContent("教师", value: viewModel.resolvedTeachersName.isEmpty ? "-" : viewModel.resolvedTeachersName)
                LabeledContent("教师号", value: viewModel.resolvedTeachersNumber.isEmpty ? "-" : viewModel.resolvedTeachersNumber)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metricsSection: some View {
        HStack(spacing: 18) {
            Text("\(CourseRatingText.text(from: viewModel.resolvedRate, empty: "暂无评分"))")
            Text("\(viewModel.resolvedLikeNum)赞")
            Text("\(viewModel.resolvedCommentNum)评论")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var courseResourcesSection: some View {
        HStack(spacing: 12) {
            Button {
                if let url = viewModel.sharedMaterialsURL {
                    openURL(url)
                } else {
                    viewModel.alert = AppAlert(title: "无法打开共享资料", message: "课程名称或课程号为空。")
                }
            } label: {
                CourseResourceCard(
                    title: "共享资料",
                    subtitle: "在浏览器打开",
                    systemImage: "folder"
                )
            }
            .buttonStyle(.plain)

            Button {
                isShowingHistoryGrades = true
            } label: {
                CourseResourceCard(
                    title: "历史成绩",
                    subtitle: "查看历年统计",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var filteredComments: [GalleryComment] {
        CommunityModeration.filterVisibleComments(viewModel.commentState.items, snapshot: settings.snapshot)
    }
}

private struct CourseResourceCard: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(Color.orange)
                .frame(width: 34, height: 34)
                .background(Color.orange.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct CourseHistoryGradesSheet: View {
    let grades: [CourseHistoryGrade]
    let status: CourseHistoryGradeLoadStatus
    let onRetry: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hidesMakeupOutliers = true

    var body: some View {
        NavigationStack {
            Group {
                switch status {
                case .idle, .loading:
                    ProgressView("正在加载历史成绩")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case let .failed(message):
                    ContentUnavailableView {
                        Label("加载历史成绩失败", systemImage: "chart.line.uptrend.xyaxis")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") {
                            Task {
                                await onRetry()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                case .loaded:
                    if grades.isEmpty {
                        ContentUnavailableView {
                            Label("暂无历史成绩", systemImage: "chart.line.uptrend.xyaxis")
                        } description: {
                            Text("当前课程还没有可展示的历史成绩统计。")
                        }
                    } else {
                        List {
                            Section {
                                CourseHistoryGradesChart(
                                    grades: grades,
                                    hidesMakeupOutliers: hidesMakeupOutliers
                                )
                                    .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
                            }

                            Section {
                                Toggle("智能屏蔽补考学期", isOn: $hidesMakeupOutliers)
                            }

                            Section {
                                ForEach(grades) { grade in
                                    CourseHistoryGradeRow(grade: grade)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史成绩")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct CourseHistoryGradesChart: View {
    let grades: [CourseHistoryGrade]
    let hidesMakeupOutliers: Bool
    @State private var selectedTerm: String?

    private var sortedGrades: [CourseHistoryGrade] {
        grades.sorted {
            $0.term.localizedStandardCompare($1.term) == .orderedAscending
        }
    }

    private var chartGrades: [CourseHistoryGrade] {
        guard hidesMakeupOutliers else { return sortedGrades }
        let hiddenTerms = makeupOutlierTerms(in: sortedGrades)
        return sortedGrades.filter { !hiddenTerms.contains($0.term) }
    }

    private var selectedGrade: CourseHistoryGrade? {
        guard let selectedTerm else {
            return chartGrades.last
        }
        return chartGrades.first { $0.term == selectedTerm } ?? chartGrades.last
    }

    private var chartPoints: [CourseHistoryGradeChartPoint] {
        let maxStudentNum = max(chartGrades.compactMap(\.studentNum).max() ?? 0, 1)

        return chartGrades.flatMap { grade in
            var points: [CourseHistoryGradeChartPoint] = []
            if let avgScore = grade.avgScore {
                points.append(
                    CourseHistoryGradeChartPoint(
                        term: grade.term,
                        series: "平均分",
                        normalizedValue: avgScore / 100,
                        displayValue: scoreText(avgScore)
                    )
                )
            }
            if let maxScore = grade.maxScore {
                points.append(
                    CourseHistoryGradeChartPoint(
                        term: grade.term,
                        series: "最高分",
                        normalizedValue: maxScore / 100,
                        displayValue: scoreText(maxScore)
                    )
                )
            }
            if let studentNum = grade.studentNum {
                points.append(
                    CourseHistoryGradeChartPoint(
                        term: grade.term,
                        series: "学习人数",
                        normalizedValue: Double(studentNum) / Double(maxStudentNum),
                        displayValue: "\(studentNum)"
                    )
                )
            }
            return points
        }
    }

    private var hiddenMakeupOutlierCount: Int {
        hidesMakeupOutliers ? makeupOutlierTerms(in: sortedGrades).count : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("趋势")
                    .font(.headline)
                Spacer()
                if let selectedGrade {
                    Text(selectedGrade.term)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Chart {
                ForEach(chartPoints) { point in
                    LineMark(
                        x: .value("学期", point.term),
                        y: .value("趋势", point.normalizedValue)
                    )
                    .foregroundStyle(by: .value("指标", point.series))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("学期", point.term),
                        y: .value("趋势", point.normalizedValue)
                    )
                    .foregroundStyle(by: .value("指标", point.series))
                }

                if let selectedGrade {
                    RuleMark(x: .value("选中学期", selectedGrade.term))
                        .foregroundStyle(Color.red.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }
            }
            .chartYScale(domain: 0 ... 1)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: chartGrades.map(\.term)) { value in
                    if let term = value.as(String.self), shouldShowYearLabel(for: term) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(yearText(from: term))
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXSelection(value: $selectedTerm)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    updateSelectedTerm(at: value.location, proxy: proxy, geometry: geometry)
                                }
                        )
                }
            }
            .frame(height: 240)

            if let selectedGrade {
                CourseHistorySelectedLegend(grade: selectedGrade)
            }

            if hiddenMakeupOutlierCount > 0 {
                Text("已从图表中屏蔽 \(hiddenMakeupOutlierCount) 个疑似补考学期。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func scoreText(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func updateSelectedTerm(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        guard frame.contains(location) else { return }

        let localX = location.x - frame.origin.x
        if let term = proxy.value(atX: localX, as: String.self), chartGrades.contains(where: { $0.term == term }) {
            selectedTerm = term
        }
    }

    private func shouldShowYearLabel(for term: String) -> Bool {
        guard let index = chartGrades.firstIndex(where: { $0.term == term }) else { return false }
        guard index > 0 else { return true }
        return yearText(from: chartGrades[index - 1].term) != yearText(from: term)
    }

    private func yearText(from term: String) -> String {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstPart = trimmed.split(separator: "-").first, firstPart.count == 4 {
            return String(firstPart.suffix(2))
        }
        let yearPrefix = String(trimmed.prefix(4))
        guard yearPrefix.count == 4 else { return yearPrefix }
        return String(yearPrefix.suffix(2))
    }

    /// 用学习人数判断疑似补考学期。
    ///
    /// 正常开课人数通常接近课程历史人数分布的上半区，补考 / 重修批次会显著偏低。
    /// 因此直接用上四分位数的一半作为阈值，比传统 IQR 下界更适合“屏蔽所有补考学期”这个业务目标。
    private func makeupOutlierTerms(in grades: [CourseHistoryGrade]) -> Set<String> {
        let samples = grades.compactMap { grade -> (term: String, count: Int)? in
            guard let count = grade.studentNum, count > 0 else { return nil }
            return (grade.term, count)
        }
        guard samples.count >= 3 else { return [] }

        let counts = samples.map(\.count).sorted()
        let q3 = percentile(0.75, values: counts)
        guard q3 >= 8 else { return [] }
        let lowerFence = max(3, q3 * 0.25)

        return Set(samples.compactMap { sample in
            Double(sample.count) < lowerFence ? sample.term : nil
        })
    }

    private func percentile(_ percentile: Double, values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        guard values.count > 1 else { return Double(values[0]) }

        let position = percentile * Double(values.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        guard lowerIndex != upperIndex else {
            return Double(values[lowerIndex])
        }

        let weight = position - Double(lowerIndex)
        return Double(values[lowerIndex]) * (1 - weight) + Double(values[upperIndex]) * weight
    }
}

private struct CourseHistoryGradeChartPoint: Identifiable {
    let term: String
    let series: String
    let normalizedValue: Double
    let displayValue: String

    var id: String {
        "\(term)-\(series)"
    }
}

private struct CourseHistorySelectedLegend: View {
    let grade: CourseHistoryGrade

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(grade.term)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text("平均分 \(scoreText(grade.avgScore))")
                Text("最高分 \(scoreText(grade.maxScore))")
                Text("学习人数 \(studentText(grade.studentNum))")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private func scoreText(_ value: Double?) -> String {
        guard let value else { return "-" }
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func studentText(_ value: Int?) -> String {
        guard let value else { return "-" }
        return "\(value)"
    }
}

private struct CourseHistoryGradeRow: View {
    let grade: CourseHistoryGrade

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(grade.term)
                .font(.headline)

            HStack(spacing: 10) {
                CourseHistoryMetric(title: "平均分", value: scoreText(grade.avgScore), tint: .orange)
                CourseHistoryMetric(title: "最高分", value: scoreText(grade.maxScore), tint: .pink)
                CourseHistoryMetric(title: "学习人数", value: studentText(grade.studentNum), tint: .blue)
            }
        }
        .padding(.vertical, 4)
    }

    private func scoreText(_ value: Double?) -> String {
        guard let value else { return "-" }
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func studentText(_ value: Int?) -> String {
        guard let value else { return "-" }
        return "\(value)"
    }
}

private struct CourseHistoryMetric: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 课程评论区。
///
/// 这里沿用帖子详情的列表式排版，把评论数量、空态和分页加载统一收口在一个组件里。
private struct CourseCommentsSection: View {
    let comments: [GalleryComment]
    let totalCommentCount: Int
    let status: GalleryFeedStatus
    let isLoadingMore: Bool
    let likingCommentIDs: Set<Int>
    let onReply: (CourseCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: (GalleryUser) -> Void
    let onLoadMore: (GalleryComment?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("评论")
                    .font(.headline)

                Text("\(totalCommentCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            switch status {
            case .idle where comments.isEmpty, .loading where comments.isEmpty:
                ProgressView("正在加载评论")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)

            case let .failed(message) where comments.isEmpty:
                ContentUnavailableView {
                    Label("加载评论失败", systemImage: "bubble.right.fill")
                } description: {
                    Text(message)
                }

            default:
                if comments.isEmpty {
                    Text(totalCommentCount == 0 ? "还没有评论" : "评论已根据社区规范隐藏")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                            VStack(spacing: 0) {
                                CourseCommentRow(
                                    comment: comment,
                                    likingCommentIDs: likingCommentIDs,
                                    onReply: onReply,
                                    onLikeComment: onLikeComment,
                                    onOpenImage: onOpenImage,
                                    onOpenUser: onOpenUser
                                )

                                if index != comments.count - 1 {
                                    Divider()
                                        .padding(.leading, 46)
                                }
                            }
                            .onAppear {
                                onLoadMore(comment)
                            }
                        }

                        if isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        }
                    }
                }
            }
        }
    }
}

/// 表示“主评论 + 当前真正回复目标”的成对上下文。
private struct CourseCommentReplyTarget {
    let mainComment: GalleryComment
    let targetComment: GalleryComment
}

private struct CourseCommentRow: View {
    let comment: GalleryComment
    let likingCommentIDs: Set<Int>
    let onReply: (CourseCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: (GalleryUser) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CourseCommentBubble(
                comment: comment,
                isSubComment: false,
                isLiking: likingCommentIDs.contains(comment.id),
                onReply: {
                    onReply(CourseCommentReplyTarget(mainComment: comment, targetComment: comment))
                },
                onLike: {
                    onLikeComment(comment)
                },
                onOpenImage: onOpenImage,
                onOpenUser: {
                    onOpenUser(comment.user)
                }
            )

            if !comment.sub.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(comment.sub.enumerated()), id: \.element.id) { index, subComment in
                        VStack(spacing: 0) {
                            CourseCommentBubble(
                                comment: subComment,
                                isSubComment: true,
                                isLiking: likingCommentIDs.contains(subComment.id),
                                onReply: {
                                    onReply(CourseCommentReplyTarget(mainComment: comment, targetComment: subComment))
                                },
                                onLike: {
                                    onLikeComment(subComment)
                                },
                                onOpenImage: onOpenImage,
                                onOpenUser: {
                                    onOpenUser(subComment.user)
                                }
                            )

                            if index != comment.sub.count - 1 {
                                Divider()
                                    .padding(.leading, 42)
                            }
                        }
                    }
                }
                .padding(.leading, 42)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct CourseCommentBubble: View {
    let comment: GalleryComment
    let isSubComment: Bool
    let isLiking: Bool
    let onReply: () -> Void
    let onLike: () -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if canOpenUserProfile {
                    Button(action: onOpenUser) {
                        CourseCommentAvatarView(
                            imageURL: URL(string: comment.user.avatar.lowUrl.isEmpty ? comment.user.avatar.url : comment.user.avatar.lowUrl),
                            size: isSubComment ? 28 : 34
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    CourseCommentAvatarView(
                        imageURL: URL(string: comment.user.avatar.lowUrl.isEmpty ? comment.user.avatar.url : comment.user.avatar.lowUrl),
                        size: isSubComment ? 28 : 34
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if canOpenUserProfile {
                            Button(action: onOpenUser) {
                                Text(comment.user.nickname)
                                    .font(isSubComment ? .subheadline.weight(.semibold) : .headline)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(comment.user.nickname)
                                .font(isSubComment ? .subheadline.weight(.semibold) : .headline)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Text(relativeTimeText(comment.createTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                if comment.rate > 0 {
                    Label(CourseRatingText.text(from: comment.rate), systemImage: "star.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }

                commentText

                if !comment.images.isEmpty {
                    CourseCommentImagesView(images: comment.images, onOpenImage: onOpenImage)
                }

                HStack(spacing: 10) {
                    Button(action: onReply) {
                        Label("回复", systemImage: "arrowshape.turn.up.left")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button(action: onLike) {
                        Label {
                            Text("\(comment.likeNum)")
                                .font(.caption)
                        } icon: {
                            if isLiking {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: comment.like ? "hand.thumbsup.fill" : "hand.thumbsup")
                            }
                        }
                        .foregroundStyle(comment.like ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
    }

    private var canOpenUserProfile: Bool {
        !comment.anonymous && comment.user.id > 0
    }

    @ViewBuilder
    private var commentText: some View {
        if comment.replyUser.id != 0, !comment.replyUser.nickname.isEmpty {
            (
                Text("回复 @\(comment.replyUser.nickname)：")
                    .foregroundStyle(.secondary) +
                    Text(comment.text)
                    .foregroundStyle(.primary)
            )
            .font(.subheadline)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(comment.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func relativeTimeText(_ string: String) -> String {
        CourseCommentDateDecoder.relativeText(from: string, fallback: "未知时间")
    }
}

private struct CourseCommentAvatarView: View {
    let imageURL: URL?
    let size: CGFloat

    var body: some View {
        CachedRemoteImage(url: imageURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                Circle().fill(Color.orange.opacity(0.15))
                Image(systemName: "person.fill")
                    .foregroundStyle(.orange)
                    .font(.caption.weight(.bold))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct CourseCommentImagesView: View {
    let images: [GalleryImage]
    let onOpenImage: (Int, [GalleryImage]) -> Void

    var body: some View {
        let displayedImages = images.count <= 2 ? images : Array(images.prefix(images.count == 3 ? 3 : 4))

        if displayedImages.count == 1 {
            thumbnailButton(image: displayedImages[0], index: 0, width: 180, maxHeight: 220, aspectRatio: 1)
        } else if displayedImages.count == 2 {
            HStack(spacing: 8) {
                ForEach(Array(displayedImages.enumerated()), id: \.element.id) { index, image in
                    thumbnailButton(image: image, index: index, width: nil, maxHeight: 150, aspectRatio: 1)
                }
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(displayedImages.count, 4)), spacing: 8) {
                ForEach(Array(displayedImages.enumerated()), id: \.element.id) { index, image in
                    thumbnailButton(image: image, index: index, width: nil, maxHeight: 78, aspectRatio: 1)
                }
            }
        }
    }

    private func thumbnailButton(image: GalleryImage, index: Int, width: CGFloat?, maxHeight: CGFloat?, aspectRatio: CGFloat) -> some View {
        Button {
            onOpenImage(index, images)
        } label: {
            CourseCommentThumbnail(
                image: image,
                width: width,
                maxHeight: maxHeight,
                aspectRatio: aspectRatio
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CourseCommentThumbnail: View {
    let image: GalleryImage
    let width: CGFloat?
    let maxHeight: CGFloat?
    let aspectRatio: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: image.lowUrl.isEmpty ? image.url : image.lowUrl)) { phase in
            switch phase {
            case let .success(renderedImage):
                renderedImage
                    .resizable()
                    .scaledToFit()
            default:
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.orange)
                    }
            }
        }
        .frame(maxWidth: width == nil ? .infinity : width)
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 课程评论输入抽屉。
///
/// 课程顶层评论支持 0.5 星颗粒度的评分；回复评论时则退化成纯文本回复。
private struct CourseCommentComposerSheet: View {
    let target: CourseCommentComposerTarget
    let isSubmitting: Bool
    let onSubmit: (String, Bool, Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var anonymous = false
    /// 课程评论评分直接保存为后端原始 10 分制整数，便于支持 0.5 星颗粒度。
    @State private var rating = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField(target.placeholder, text: $text, axis: .vertical)
                        .lineLimit(5, reservesSpace: true)

                    Toggle("匿名评论", isOn: $anonymous)
                }

                if supportsCourseRating {
                    Section("评分") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                ForEach(1 ... 5, id: \.self) { value in
                                    ZStack {
                                        Image(systemName: starSymbol(for: value))
                                            .font(.title3)
                                            .foregroundStyle(Color.orange)
                                            .frame(width: 28, height: 28)

                                        HStack(spacing: 0) {
                                            Button {
                                                setRating(for: value, isHalf: true)
                                            } label: {
                                                Color.clear
                                                    .frame(width: 14, height: 28)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)

                                            Button {
                                                setRating(for: value, isHalf: false)
                                            } label: {
                                                Color.clear
                                                    .frame(width: 14, height: 28)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }

                                Spacer()

                                Text(rating == 0 ? "不评分" : CourseRatingText.text(from: rating, empty: "不评分"))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(rating == 0 ? Color.secondary : Color.orange)
                            }

                            Text("支持半星；点左半颗记 0.5 分，点右半颗记整颗星。提交带评分的课程评论后，当前账号不能重复评价。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSubmitting ? "发送中" : "发送") {
                        onSubmit(text, anonymous, rawRating)
                    }
                    .disabled(isSubmitting)
                }
            }
        }
    }

    private var supportsCourseRating: Bool {
        if case .course = target {
            return true
        }
        return false
    }

    private var rawRating: Int? {
        guard supportsCourseRating, rating > 0 else { return nil }
        return rating
    }

    private func starSymbol(for value: Int) -> String {
        let fullStarThreshold = value * 2
        if rating >= fullStarThreshold {
            return "star.fill"
        }
        if rating == fullStarThreshold - 1 {
            return "star.leadinghalf.filled"
        }
        return "star"
    }

    private func setRating(for value: Int, isHalf: Bool) {
        let nextRating = value * 2 - (isHalf ? 1 : 0)
        rating = rating == nextRating ? 0 : nextRating
    }
}

/// 课程评论时间解析器。
///
/// 评论接口历史上出现过多种日期格式，这里集中兼容，避免视图层自己兜底解析。
private enum CourseCommentDateDecoder {
    private static let formatters: [DateFormatter] = [
        makeFormatter("yyyy-MM-dd HH:mm:ss"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
    ]

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let relativeFormatter = RelativeDateTimeFormatter()

    static func date(from string: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }

        return iso8601Formatter.date(from: string)
    }

    static func relativeText(from string: String, fallback: String) -> String {
        guard let date = date(from: string) else {
            return fallback
        }

        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = format
        return formatter
    }
}
