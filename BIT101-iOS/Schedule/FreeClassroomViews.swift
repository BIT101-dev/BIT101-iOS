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
                        message: emptyStateMessage,
                        actionTitle: hasSectionFilter ? "清除节次筛选" : "刷新空教室",
                        onAction: {
                            if hasSectionFilter {
                                viewModel.setSelectedClassroomSectionIDs([])
                            } else {
                                Task { await viewModel.refreshClassroomPage() }
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)
                }
            } else {
                Section {
                    // ViewModel 已完成排序和筛选，列表在此展示可用教室结果。
                    ForEach(viewModel.classroomAvailabilities) { classroom in
                        HStack(alignment: .top, spacing: AppDesignSystem.Spacing.content) {
                            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.micro) {
                                Text(classroom.name)
                                    .font(AppDesignSystem.Typography.headline)
                                Text(classroom.statusText)
                                    .font(AppDesignSystem.Typography.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: AppDesignSystem.Spacing.micro) {
                                Text(classroom.prettyFreeTimes)
                                    .font(AppDesignSystem.Typography.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                if !classroom.detailText.isEmpty {
                                    Text(classroom.detailText)
                                        .font(AppDesignSystem.Typography.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, AppDesignSystem.Spacing.tiny)
                        .listRowBackground(classroomBackground(for: classroom))
                    }
                }
            }
        }
        .appGroupedListStyle()
    }

    private var hasSectionFilter: Bool {
        !viewModel.cache.selectedClassroomSectionIDs.isEmpty
    }

    private var emptyStateMessage: String {
        hasSectionFilter ? "当前筛选条件下没有空教室。" : "先选定校区和教学楼，再刷新一次。"
    }

    private func classroomBackground(for classroom: ClassroomAvailability) -> Color {
        switch ClassroomAvailabilityCalculator.sectionMatch(
            freeSections: classroom.freeSections,
            selectedSections: viewModel.cache.selectedClassroomSectionIDs,
            timeTable: viewModel.cache.timeTable
        ) {
        case .full:
            return AppDesignSystem.Palette.accentSurface
        case .partial:
            return AppDesignSystem.Palette.accentSubtleSurface
        case .none:
            return AppDesignSystem.Palette.systemBackground
        }
    }
}

/// 空教室节次筛选页。
///
/// 空选表示“当前空闲”，选择任一节次则按“命中任一节次空闲”筛选结果。
struct ClassroomSectionFilterPage: View {
    let timeTable: [TimeSlot]
    @Binding var selectedSectionIDs: [Int]

    var body: some View {
        AppMultiSelectionList(
            title: "节次筛选",
            items: timeTable.map(\.id),
            itemTitle: { "第\($0)节" },
            selectAllTitle: "全选",
            showsCompletionButton: false,
            selectedItems: $selectedSectionIDs
        )
    }
}
