//
//  SettingsAppearanceViews.swift
//  BIT101-iOS
//
//  Split from SettingsRootView.swift.
//

import SwiftUI

struct PagesSettingsPage: View {
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var pageOrder = AppTab.allCases
    @State private var homeTab: AppTab = .schedule
    @State private var hiddenTabs: Set<AppTab> = []
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            Section {
                Text("按住右侧拖动可以调整顺序；勾选默认项表示启动时默认页面；隐藏会从底部导航栏移除，“我的”页面不能隐藏。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(pageOrder) { tab in
                    HStack {
                        Text(tab.title)
                        Spacer()
                        Toggle("显示", isOn: Binding(
                            get: { !hiddenTabs.contains(tab) || tab == .mine },
                            set: { visible in
                                if tab != .mine {
                                    if visible { hiddenTabs.remove(tab) } else { hiddenTabs.insert(tab) }
                                    if hiddenTabs.contains(homeTab) {
                                        homeTab = pageOrder.first(where: { !hiddenTabs.contains($0) || $0 == .mine }) ?? .schedule
                                    }
                                    persist()
                                }
                            }
                        ))
                        .labelsHidden()
                        Button {
                            homeTab = tab
                            persist()
                        } label: {
                            Image(systemName: homeTab == tab ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(homeTab == tab ? AppDesignSystem.Palette.accent : .secondary)
                                .frame(
                                    width: AppDesignSystem.Size.control.touchTarget,
                                    height: AppDesignSystem.Size.control.touchTarget
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .appSelectionFeedback(trigger: homeTab)
                    }
                }
                .onMove { from, to in
                    pageOrder.move(fromOffsets: from, toOffset: to)
                    persist()
                }
            } header: {
                Text("页面编辑")
            }
        }
        .appGroupedListStyle()
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "完成" : "编辑") {
                    withAnimation(.easeInOut) {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
            }
        }
        .task { syncFromStore() }
    }

    /// 把当前全局设置同步到本页可编辑状态。
    private func syncFromStore() {
        pageOrder = settings.pageOrder
        homeTab = settings.homeTab
        hiddenTabs = Set(settings.hiddenTabs)
    }

    /// 把当前页面编辑结果一次性写回设置仓库。
    private func persist() {
        settings.setPageOrder(pageOrder)
        settings.setHiddenTabs(Array(hiddenTabs))
        settings.setHomeTab(homeTab)
    }
}

/// 外观设置页。
///
/// 目前只保留外观模式和自动旋转两项全局开关。
struct ThemeSettingsPage: View {
    @ObservedObject private var settings = AppSettingsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("外观模式", selection: Binding(
                    get: { settings.themeMode },
                    set: settings.setThemeMode
                )) {
                    ForEach(AppThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .appSelectionFeedback(trigger: settings.themeMode)

                Toggle("自动旋转", isOn: Binding(
                    get: { settings.autoRotate },
                    set: settings.setAutoRotate
                ))
                .appSelectionFeedback(trigger: settings.autoRotate)
            }
        }
    }
}

/// 课程表设置页。
///
/// 这里既承载“数据同步入口”，也承载“课表显示项”和“灵动岛提醒”相关配置。
