import SwiftUI

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
            }

            Section {
                ForEach(options, id: \.self) { option in
                    Button {
                        toggle(option)
                    } label: {
                        HStack {
                            Text(option)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selectedValues.contains(option) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedValues.contains(option) ? Color.accentColor : .secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
        selectedValues.count == options.count ? "全不选" : "全选"
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
                        HStack {
                            Text(index.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: sortIndex == index ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(sortIndex == index ? Color.accentColor : .secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Button {
                    onToggleOrder()
                } label: {
                    HStack {
                        Label(sortOrder.title, systemImage: sortOrder.systemImage)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("切换")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            } header: {
                Text("排序方向")
            } footer: {
                Text("升序表示小的在上，降序表示大的在上。")
            }
        }
        .navigationTitle("成绩排序")
        .navigationBarTitleDisplayMode(.inline)
    }
}
