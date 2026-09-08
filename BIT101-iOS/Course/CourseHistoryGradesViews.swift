//
//  CourseHistoryGradesViews.swift
//  BIT101-iOS
//
import Charts
import SwiftUI

struct CourseHistoryGradesSheet: View {
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
                    AppLoadingState(title: "正在加载历史成绩")

                case let .failed(message):
                    AppFailureState(
                        title: "加载历史成绩失败",
                        systemImage: "chart.line.uptrend.xyaxis",
                        message: message,
                        onRetry: {
                            Task {
                                await onRetry()
                            }
                        }
                    )

                case .loaded:
                    if grades.isEmpty {
                        AppEmptyState(
                            title: "暂无历史成绩",
                            systemImage: "chart.line.uptrend.xyaxis",
                            message: "当前课程还没有可展示的历史成绩统计。"
                        )
                    } else {
                        List {
                            Section {
                                CourseHistoryGradesChart(
                                    grades: grades,
                                    hidesMakeupOutliers: hidesMakeupOutliers
                                )
                                    .listRowInsets(EdgeInsets(
                                        top: AppDesignSystem.Spacing.container,
                                        leading: AppDesignSystem.Spacing.container,
                                        bottom: AppDesignSystem.Spacing.container,
                                        trailing: AppDesignSystem.Spacing.container
                                    ))
                            }

                            Section {
                                Toggle("智能屏蔽补考学期", isOn: $hidesMakeupOutliers)
                                    .appSelectionFeedback(trigger: hidesMakeupOutliers)
                            }

                            Section {
                                ForEach(grades) { grade in
                                    CourseHistoryGradeRow(grade: grade)
                                }
                            }
                        }
                        .appGroupedListStyle()
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

    /// 松手时 Charts 会把选择值写回 nil；忽略这次清空，保留用户最后停留的学期。
    private var chartSelection: Binding<String?> {
        Binding(
            get: { selectedTerm },
            set: { newValue in
                if let newValue {
                    selectedTerm = newValue
                }
            }
        )
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
                        normalizedValue: avgScore / 100
                    )
                )
            }
            if let maxScore = grade.maxScore {
                points.append(
                    CourseHistoryGradeChartPoint(
                        term: grade.term,
                        series: "最高分",
                        normalizedValue: maxScore / 100
                    )
                )
            }
            if let studentNum = grade.studentNum {
                points.append(
                    CourseHistoryGradeChartPoint(
                        term: grade.term,
                        series: "学习人数",
                        normalizedValue: Double(studentNum) / Double(maxStudentNum)
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
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
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
                        .foregroundStyle(AppDesignSystem.Palette.danger.opacity(0.9))
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
            .chartXSelection(value: chartSelection)
            .frame(height: AppDesignSystem.Size.content.chartHeight)

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

    /// 用学习人数筛出疑似补考学期。
    ///
    /// 至少有 3 个有效学习人数且上四分位数不低于 8 时，低于 max(3, Q3 × 0.25) 的学期会被视为异常值。
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

    var id: String {
        "\(term)-\(series)"
    }
}

private struct CourseHistorySelectedLegend: View {
    let grade: CourseHistoryGrade

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tight) {
            Text(grade.term)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: AppDesignSystem.Spacing.control) {
                Text("平均分 \(courseHistoryScoreText(grade.avgScore))")
                Text("最高分 \(courseHistoryScoreText(grade.maxScore))")
                Text("学习人数 \(courseHistoryStudentText(grade.studentNum))")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AppDesignSystem.Spacing.micro)
    }
}

private struct CourseHistoryGradeRow: View {
    let grade: CourseHistoryGrade

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.control) {
            Text(grade.term)
                .font(.headline)

            HStack(spacing: AppDesignSystem.Spacing.control) {
                CourseHistoryMetric(title: "平均分", value: courseHistoryScoreText(grade.avgScore), tint: AppDesignSystem.Palette.highlight)
                CourseHistoryMetric(title: "最高分", value: courseHistoryScoreText(grade.maxScore), tint: AppDesignSystem.Palette.scoreTab)
                CourseHistoryMetric(title: "学习人数", value: courseHistoryStudentText(grade.studentNum), tint: AppDesignSystem.Palette.info)
            }
        }
        .padding(.vertical, AppDesignSystem.Spacing.tiny)
    }
}

private struct CourseHistoryMetric: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppDesignSystem.Spacing.control)
        .background(tint.opacity(0.10), in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.badge))
    }
}

private func courseHistoryScoreText(_ value: Double?) -> String {
    guard let value else { return "-" }
    if value.rounded() == value {
        return String(format: "%.0f", value)
    }
    return String(format: "%.1f", value)
}

private func courseHistoryStudentText(_ value: Int?) -> String {
    guard let value else { return "-" }
    return "\(value)"
}
