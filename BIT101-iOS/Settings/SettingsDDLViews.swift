//
//  SettingsDDLViews.swift
//  BIT101-iOS
//
//  Split from SettingsRootView.swift.
//

import SwiftUI

struct DDLSettingsPage: View {
    @StateObject private var viewModel = SchoolDataRefreshCoordinator.shared.scheduleViewModel
    @State private var pickerRoute: DDLSettingsNumberPickerRoute?

    var body: some View {
        List {
            Section("数据设置") {
                Button {
                    Task { await viewModel.refreshLexueCalendarURL() }
                } label: {
                    DDLSettingsActionRow(
                        title: "重新获取订阅链接"
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSyncingDDL)

                Button {
                    Task { await viewModel.syncDDL() }
                } label: {
                    DDLSettingsActionRow(
                        title: "重新拉取乐学日程"
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSyncingDDL)
            }

            Section("显示设置") {
                Button {
                    pickerRoute = .beforeDay
                } label: {
                    DDLSettingsActionRow(
                        title: "变色天数",
                        value: "\(viewModel.beforeDay) 天"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    pickerRoute = .afterDay
                } label: {
                    DDLSettingsActionRow(
                        title: "滞留天数",
                        value: "\(viewModel.afterDay) 天"
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .task { await viewModel.loadIfNeeded() }
        .sheet(item: $pickerRoute) { route in
            switch route {
            case .beforeDay:
                DDLSettingsNumberPickerSheet(
                    title: "变色天数",
                    initialValue: viewModel.beforeDay
                ) { value in
                    viewModel.setDDLBeforeDay(value)
                }
            case .afterDay:
                DDLSettingsNumberPickerSheet(
                    title: "滞留天数",
                    initialValue: viewModel.afterDay
                ) { value in
                    viewModel.setDDLAfterDay(value)
                }
            }
        }
    }
}

/// DDL 设置页里可弹出编辑抽屉的数值项。
private enum DDLSettingsNumberPickerRoute: String, Identifiable {
    case beforeDay
    case afterDay

    var id: String { rawValue }
}

/// DDL 设置页按钮行。
private struct DDLSettingsActionRow: View {
    let title: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(Color.accentColor)

            Spacer(minLength: 0)

            if let value {
                Text(value)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}

/// DDL 设置页数值选择抽屉。
private struct DDLSettingsNumberPickerSheet: View {
    let title: String
    let initialValue: Int
    let onSubmit: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: Int

    init(title: String, initialValue: Int, onSubmit: @escaping (Int) -> Void) {
        self.title = title
        self.initialValue = initialValue
        self.onSubmit = onSubmit
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            VStack {
                Picker(title, selection: $value) {
                    ForEach(0 ... 30, id: \.self) { day in
                        Text("\(day) 天")
                            .tag(day)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSubmit(value)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(240)])
        .presentationDragIndicator(.visible)
    }
}

/// 画廊设置页。
///
/// 集中管理本地黑名单、隐藏帖子、社区规则状态以及相关联系信息。
