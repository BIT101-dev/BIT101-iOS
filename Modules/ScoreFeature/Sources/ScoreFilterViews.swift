import ScoreDomain
#if os(iOS)
import DesignSystemKit
import SwiftUI

/// 学期筛选使用公共多选列表，筛选集合由成绩模型维护。
struct ScoreFilterPage: View {
    let title: String
    let options: [String]
    @Binding var selectedValues: Set<String>
    let onToggleAll: () -> Void

    var body: some View {
        AppMultiSelectionList(title: title, items: options, itemTitle: { $0 }, selectAllTitle: "全选",
            showsCompletionButton: false, selectedItems: Binding(
                get: { options.filter { selectedValues.contains($0) } },
                set: { selectedValues = Set($0) }
            ), onToggleAll: onToggleAll)
    }
}

/// 只改变列表展示顺序的成绩排序页。
struct ScoreSortPage: View {
    @Binding var sortIndex: ScoreSortIndex
    @Binding var sortOrder: ScoreSortOrder
    let onToggleOrder: () -> Void

    var body: some View {
        List {
            Section("排序索引") {
                ForEach(ScoreSortIndex.allCases) { index in
                    Button {
                        sortIndex = index
                    } label: {
                        AppSelectionRow(
                            title: index.title,
                            isSelected: sortIndex == index
                        )
                    }
                    .buttonStyle(.plain)
                    .appInteractiveListRow()
                        .accessibilityIdentifier("ui.score-sort-page.index")
                }
            }

            Section {
                Button {
                    onToggleOrder()
                } label: {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Text(sortOrder.title)
                            .font(AppDesignSystem.Typography.subheadline)
                        Spacer()
                        Text("切换")
                            .font(AppDesignSystem.Typography.subheadline)
                            .foregroundStyle(AppDesignSystem.Course.accent)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("排序方向")
                .accessibilityValue(sortOrder.title)
                .accessibilityHint("双击切换排序方向")
                .appInteractiveListRow()
            } header: {
                AppListSectionHeader("排序方向")
            }
        }
        .accessibilityIdentifier("interaction.ScoreSortPage.list")
        .appGroupedListStyle()
        .appSelectionFeedback(trigger: sortIndex)
        .appSelectionFeedback(trigger: sortOrder)
        .navigationTitle("成绩排序")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#endif
