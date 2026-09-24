//
//  CourseHistoryGradesViews.swift
//  BIT101-iOS
//
import Charts
import SwiftUI

struct CourseHistoryGradesChart: View {
    let grades: [CourseHistoryGrade]
    let courseNumber: String
    let hidesMakeupOutliers: Bool
    @State private var selectedTerm: String?

    private var sortedGrades: [CourseHistoryGrade] {
        grades.sorted {
            $0.term.localizedStandardCompare($1.term) == .orderedAscending
        }
    }

    private var chartGrades: [CourseHistoryGrade] {
        guard hidesMakeupOutliers else { return sortedGrades }
        let hiddenTerms = CourseHistoryMakeupPolicy.hiddenTerms(
            in: sortedGrades,
            courseNumber: courseNumber
        )
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

    private var chartAccessibilityValue: String {
        guard let selectedGrade else { return "暂无可用数据" }
        return [
            selectedGrade.term,
            "平均分 " + courseHistoryScoreText(selectedGrade.avgScore),
            "最高分 " + courseHistoryScoreText(selectedGrade.maxScore),
            "学习人数 " + courseHistoryStudentText(selectedGrade.studentNum),
        ].joined(separator: "，")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
            Chart {
                ForEach(chartPoints) { point in
                    LineMark(
                        x: .value("学期", point.term),
                        y: .value("", point.normalizedValue)
                    )
                    .foregroundStyle(by: .value("指标", point.series))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("学期", point.term),
                        y: .value("", point.normalizedValue)
                    )
                    .foregroundStyle(by: .value("指标", point.series))
                }

                if let selectedGrade {
                    RuleMark(x: .value("选中学期", selectedGrade.term))
                        .foregroundStyle(AppDesignSystem.Palette.Status.danger.opacity(AppDesignSystem.Course.historyWarningOpacity))
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
            .frame(height: AppDesignSystem.Course.historyChartHeight)
            .accessibilityLabel("历史成绩图")
            .accessibilityValue(chartAccessibilityValue)
            .accessibilityHint("滑动图表可查看不同学期")

            if let selectedGrade {
                CourseHistorySelectedLegend(grade: selectedGrade)
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
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
            Text(grade.term)
                .font(AppDesignSystem.Typography.captionEmphasis)
                .foregroundStyle(AppDesignSystem.Foreground.secondary)

            HStack(spacing: AppDesignSystem.Spacing.regular) {
                Text("平均分 \(courseHistoryScoreText(grade.avgScore))")
                Text("最高分 \(courseHistoryScoreText(grade.maxScore))")
                Text("学习人数 \(courseHistoryStudentText(grade.studentNum))")
            }
            .font(AppDesignSystem.Typography.body)
            .foregroundStyle(AppDesignSystem.Foreground.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AppDesignSystem.Spacing.micro)
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
