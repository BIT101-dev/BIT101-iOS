import SwiftUI

private struct ScoreSelectionRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.control) {
            Text(title)
                .font(AppDesignSystem.Typography.body)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AppDesignSystem.Palette.accent : .secondary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "已选" : "未选")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 学期和课程种类复用的多选筛选页。
struct ScoreFilterPage: View {
    let title: String
    let options: [String]
    @Binding var selectedValues: Set<String>
    let onToggleAll: () -> Void

    var body: some View {
        List {
            Section {
                Button(toggleAllTitle) {
                    onToggleAll()
                }
                .disabled(options.isEmpty)
                .accessibilityValue("已选 \(selectedValues.intersection(Set(options)).count) 项，共 \(options.count) 项")
            }

            Section {
                if options.isEmpty {
                    Text("暂无可筛选项")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(options, id: \.self) { option in
                        Button {
                            toggle(option)
                        } label: {
                            ScoreSelectionRow(
                                title: option,
                                isSelected: selectedValues.contains(option)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .appGroupedListStyle()
        .appSelectionFeedback(trigger: selectedValues)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ option: String) {
        var next = selectedValues
        if next.contains(option) {
            next.remove(option)
        } else {
            next.insert(option)
        }
        selectedValues = next
    }

    private var toggleAllTitle: String {
        allOptionsSelected ? "全不选" : "全选"
    }

    private var allOptionsSelected: Bool {
        !options.isEmpty && Set(options).isSubset(of: selectedValues)
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
                        ScoreSelectionRow(
                            title: index.title,
                            isSelected: sortIndex == index
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Button {
                    onToggleOrder()
                } label: {
                    HStack(spacing: AppDesignSystem.Spacing.control) {
                        Text(sortOrder.title)
                            .font(AppDesignSystem.Typography.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("切换")
                            .font(AppDesignSystem.Typography.subheadline)
                            .foregroundStyle(AppDesignSystem.Palette.accent)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("排序方向")
                .accessibilityValue(sortOrder.title)
                .accessibilityHint("双击切换排序方向")
            } header: {
                AppListSectionHeader("排序方向")
            }
        }
        .appGroupedListStyle()
        .appSelectionFeedback(trigger: sortIndex)
        .appSelectionFeedback(trigger: sortOrder)
        .navigationTitle("成绩排序")
        .navigationBarTitleDisplayMode(.inline)
    }
}
