import SwiftUI

/// 空教室查询页。
///
/// 页面引导用户按“选校区 -> 手动刷新教学楼 -> 再选楼”的顺序操作，减少无效点击。
struct FreeClassroomTabView: View {
    @ObservedObject var viewModel: ScheduleViewModel

    private var isClassroomRefreshing: Bool {
        viewModel.shouldShowInitialClassroomSpinner
            || viewModel.isLoadingClassroomMeta
            || viewModel.isLoadingClassrooms
    }

    private var classroomLoadingText: String {
        if viewModel.shouldShowInitialClassroomSpinner {
            return "正在加载空教室信息"
        }
        if viewModel.isLoadingClassroomMeta {
            return "正在更新教学楼列表"
        }
        return "正在刷新当前教学楼"
    }

    var body: some View {
        List {
            Section {
                AppRefreshStatusRow(
                    isRefreshing: isClassroomRefreshing,
                    refreshingText: classroomLoadingText,
                    lastUpdatedText: viewModel.classroomLastUpdatedText,
                    actionTitle: "刷新",
                    onRefresh: {
                        Task { await viewModel.refreshClassroomPage() }
                    }
                )
            }

            Section {
                Picker("校区", selection: Binding(
                    get: { viewModel.cache.selectedCampusCode },
                    set: { newValue in
                        Task {
                            await viewModel.selectCampus(code: newValue)
                        }
                    }
                )) {
                    ForEach(viewModel.campuses) { campus in
                        Text(campus.name).tag(campus.code)
                    }
                }
                .appSelectionFeedback(trigger: viewModel.cache.selectedCampusCode)

                Picker("教学楼", selection: Binding(
                    get: { viewModel.selectedBuildingID },
                    set: { newValue in
                        Task {
                            await viewModel.selectBuilding(id: newValue)
                        }
                    }
                )) {
                    ForEach(viewModel.buildings) { building in
                        Text(building.name).tag(building.buildingCode)
                    }
                }
                .appSelectionFeedback(trigger: viewModel.selectedBuildingID)

                NavigationLink {
                    ClassroomSectionFilterPage(
                        timeTable: viewModel.cache.timeTable,
                        selectedSectionIDs: Binding(
                            get: { viewModel.cache.selectedClassroomSectionIDs },
                            set: { viewModel.setSelectedClassroomSectionIDs($0) }
                        )
                    )
                } label: {
                    LabeledContent("节次筛选", value: viewModel.classroomSectionFilterSummary)
                }
            }

            if viewModel.classroomAvailabilities.isEmpty, !isClassroomRefreshing {
                Section {
                    AppEmptyState(
                        title: "暂无空教室结果",
                        systemImage: "building.2.crop.circle",
                        message: "先选定校区和教学楼，再刷新一次。",
                        actionTitle: "刷新空教室",
                        onAction: {
                            Task { await viewModel.refreshClassroomPage() }
                        }
                    )
                    .frame(maxWidth: .infinity)
                }
            } else {
                Section {
                    // ViewModel 已完成排序和筛选，列表在此展示可用教室结果。
                    ForEach(viewModel.classroomAvailabilities) { classroom in
                        HStack(spacing: AppDesignSystem.Spacing.content) {
                            Text(classroom.name)
                                .font(.headline)
                            Spacer()
                            Text(classroom.prettyFreeTimes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, AppDesignSystem.Spacing.tiny)
                    }
                }
            }
        }
        .appGroupedListStyle()
    }
}

/// 空教室节次筛选页。
///
/// 空选表示“当前空闲”，选择任一节次则按“命中任一节次空闲”筛选结果。
struct ClassroomSectionFilterPage: View {
    let timeTable: [TimeSlot]
    @Binding var selectedSectionIDs: [Int]

    var body: some View {
        List {
            Section {
                Button(toggleAllTitle) {
                    toggleAll()
                }
            }

            Section {
                ForEach(timeTable) { slot in
                    let isSelected = selectedSectionIDs.contains(slot.id)
                    Button {
                        toggle(slot.id)
                    } label: {
                        HStack(spacing: AppDesignSystem.Spacing.control) {
                            Text("第\(slot.id)节")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? AppDesignSystem.Palette.accent : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .appGroupedListStyle()
        .appSelectionFeedback(trigger: selectedSectionIDs)
        .navigationTitle("节次筛选")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 切换单个节次是否被选中。
    private func toggle(_ sectionID: Int) {
        var next = selectedSectionIDs
        if let index = next.firstIndex(of: sectionID) {
            next.remove(at: index)
        } else {
            next.append(sectionID)
        }
        selectedSectionIDs = next.sorted()
    }

    /// 在“全选”和“全不选”之间切换。
    private func toggleAll() {
        if areAllSectionsSelected {
            selectedSectionIDs = []
        } else {
            selectedSectionIDs = timeTable.map(\.id)
        }
    }

    /// 顶部总开关文案。
    private var toggleAllTitle: String {
        areAllSectionsSelected ? "全不选" : "全选"
    }

    private var areAllSectionsSelected: Bool {
        selectedSectionIDs.count == timeTable.count
    }
}
