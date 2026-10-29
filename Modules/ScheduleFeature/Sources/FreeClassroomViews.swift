#if os(iOS)
import ScheduleDomain
import DesignSystemKit
import SwiftUI

/// 空教室查询页。
///
/// 校区与教学楼选择自动加载，当天结果支持本地节次筛选与手动刷新。
struct FreeClassroomTabView: View {
    @Environment(\.scheduleCurrentDate) private var currentDate
    @ObservedObject var viewModel: ScheduleClassroomViewModel

    var body: some View {
        let availabilities = viewModel.classroomAvailabilities(at: currentDate)
        AppSidebarLayout {
            List { classroomControls }.appGroupedListStyle()
                .accessibilityIdentifier("classroom.sidebar")
        } content: { usesSidebar in
            List {
                if !usesSidebar { classroomControls }
                if availabilities.isEmpty, !viewModel.isRefreshingPage {
                    Section {
                        AppEmptyState(
                            title: "暂无空教室结果",
                            systemImage: "building.2.crop.circle",
                            message: emptyStateMessage,
                            actionTitle: canClearSectionFilter ? "清除节次筛选" : "刷新空教室",
                            onAction: {
                                if canClearSectionFilter {
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
                        ForEach(availabilities) { classroom in
                            let matchesAllSelectedSections = isExactMatch(for: classroom)
                            HStack(alignment: .firstTextBaseline, spacing: AppDesignSystem.Spacing.content) {
                                Text(classroom.name)
                                    .font(AppDesignSystem.Typography.body)
                                    .foregroundStyle(AppDesignSystem.Foreground.primary)
                                    .lineLimit(1)
                                    .allowsTightening(true)
                                    .minimumScaleFactor(0.8)
                                    .layoutPriority(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(classroom.prettyFreeTimes)
                                    .font(
                                        matchesAllSelectedSections
                                            ? AppDesignSystem.Typography.subheadlineEmphasis
                                            : AppDesignSystem.Typography.subheadline
                                    )
                                    .foregroundStyle(
                                        matchesAllSelectedSections
                                            ? AppDesignSystem.Foreground.primary
                                            : AppDesignSystem.Foreground.secondary
                                    )
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .padding(.vertical, AppDesignSystem.Spacing.tiny)
                        }
                    }
                }
            }
            .accessibilityIdentifier("interaction.FreeClassroomTabView.list")
            .appGroupedListStyle(insetViewport: usesSidebar)
            .scrollContentBackground(.hidden)
            .background(AppDesignSystem.Palette.Background.grouped)
        }
    }

    @ViewBuilder
    private var classroomControls: some View {
        Section { ClassroomRefreshStatusRow(viewModel: viewModel) }

        Section {
            Picker("校区", selection: Binding(
                get: { viewModel.cache.selectedCampusCode },
                set: { newValue in
                    viewModel.selectCampus(code: newValue)
                }
            )) {
                ForEach(viewModel.campuses) { campus in
                    Text(campus.name).tag(campus.code)
                }
            }
            .appSelectionFeedback(trigger: viewModel.cache.selectedCampusCode)
            .appInteractiveListRow()

            Picker("教学楼", selection: Binding(
                get: { viewModel.selectedBuildingID },
                set: { newValue in
                    viewModel.selectBuilding(id: newValue)
                }
            )) {
                ForEach(viewModel.buildings) { building in
                    Text(building.name).tag(building.buildingCode)
                }
            }
            .appSelectionFeedback(trigger: viewModel.selectedBuildingID)
            .appInteractiveListRow()

            NavigationLink {
                ScheduleSectionSelectionPage(
                    timeTable: viewModel.cache.timeTable,
                    title: "节次筛选", selectAllTitle: "全选", showsCompletionButton: false,
                    selectedSections: Binding(
                        get: { viewModel.cache.selectedClassroomSectionIDs },
                        set: { viewModel.setSelectedClassroomSectionIDs($0) }
                    )
                )
            } label: {
                LabeledContent("节次筛选", value: viewModel.classroomSectionFilterSummary)
            }
            .appInteractiveListRow()
        }

    }

    private var hasSectionFilter: Bool {
        !viewModel.cache.selectedClassroomSectionIDs.isEmpty
    }

    private var canClearSectionFilter: Bool {
        hasSectionFilter && viewModel.classroomLastUpdatedAt != nil
            && !viewModel.hasExpiredClassroomData(at: currentDate)
    }

    private var emptyStateMessage: String {
        if viewModel.hasExpiredClassroomData(at: currentDate) { return "查询日期已变化，请刷新当前教学楼。" }
        return canClearSectionFilter ? "当前筛选条件下没有空教室。" : "先选定校区和教学楼，再刷新一次。"
    }

    private func isExactMatch(for classroom: ClassroomAvailability) -> Bool {
        switch ClassroomAvailabilityCalculator.sectionMatch(
            freeSections: classroom.freeSections,
            selectedSections: viewModel.cache.selectedClassroomSectionIDs,
            timeTable: viewModel.cache.timeTable
        ) {
        case .full:
            return true
        case .partial, .none:
            return false
        }
    }
}

struct ClassroomRefreshStatusRow: View {
    @ObservedObject var viewModel: ScheduleClassroomViewModel
    var body: some View {
        AppRefreshStatusRow(isRefreshing: viewModel.isRefreshingPage, refreshingText: viewModel.pageRefreshText,
            lastUpdatedText: viewModel.classroomLastUpdatedText, actionTitle: "刷新",
            onRefresh: { Task { await viewModel.refreshClassroomPage() } })
    }
}

#endif
