import SwiftUI

/// 空教室查询页。
///
/// 交互上尽量保持“选校区 -> 自动拉默认楼 -> 再选楼”的顺序，减少无效点击。
struct FreeClassroomTabView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @State private var isManuallyRefreshing = false

    private var shouldShowClassroomLoadingState: Bool {
        !isManuallyRefreshing && (
            viewModel.shouldShowInitialClassroomSpinner ||
            viewModel.isLoadingClassroomMeta ||
            viewModel.isLoadingClassrooms
        )
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
            Section("筛选") {
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

            if viewModel.classroomAvailabilities.isEmpty, shouldShowClassroomLoadingState {
                Section {
                    ContentUnavailableView {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.regular)
                            Text(classroomLoadingText)
                                .font(.headline)
                        }
                    } description: {
                        Text("请稍候")
                    }
                    .frame(maxWidth: .infinity)
                }
            } else if viewModel.classroomAvailabilities.isEmpty {
                Section {
                    ContentUnavailableView(
                        "暂无空教室结果",
                        systemImage: "building.2.crop.circle",
                        description: Text("先选定校区和教学楼，再刷新一次。")
                    )
                    .frame(maxWidth: .infinity)
                }
            } else {
                Section {
                    // 这里展示的是已经过 ViewModel 排序和筛选后的可用教室结果。
                    ForEach(viewModel.classroomAvailabilities) { classroom in
                        HStack(spacing: 12) {
                            Text(classroom.name)
                                .font(.headline)
                            Spacer()
                            Text(classroom.prettyFreeTimes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            isManuallyRefreshing = true
            defer {
                isManuallyRefreshing = false
            }
            await viewModel.refreshClassroomPage()
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
        List {
            Section {
                Button(toggleAllTitle) {
                    toggleAll()
                }
            }

            Section {
                ForEach(timeTable) { slot in
                    Button {
                        toggle(slot.id)
                    } label: {
                            HStack {
                                Text("第\(slot.id)节")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selectedSectionIDs.contains(slot.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedSectionIDs.contains(slot.id) ? Color.accentColor : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("不选任何节次时，默认按“当前空闲”展示；选择具体节次后，会显示在所选任一节次内有空闲的教室。")
            }
        }
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
        if selectedSectionIDs.count == timeTable.count {
            selectedSectionIDs = []
        } else {
            selectedSectionIDs = timeTable.map(\.id)
        }
    }

    /// 顶部总开关文案。
    private var toggleAllTitle: String {
        selectedSectionIDs.count == timeTable.count ? "全不选" : "全选"
    }
}
