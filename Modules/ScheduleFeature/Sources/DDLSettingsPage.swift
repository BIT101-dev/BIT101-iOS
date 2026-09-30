#if os(iOS)
import DesignSystemKit

import SwiftUI

public struct DDLSettingsPage: View {
    @ObservedObject private var viewModel: ScheduleDDLViewModel
    @State private var pickerRoute: DDLSettingsNumberPickerRoute?

    public init(viewModel: ScheduleDDLViewModel) { self.viewModel = viewModel }

    public var body: some View {
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
        .appGroupedListStyle()
        .task { await viewModel.loadIfNeeded() }
        .scheduleSchoolVerification(viewModel: viewModel)
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

/// DDL 设置页的数值选择路由。
private enum DDLSettingsNumberPickerRoute: String, Identifiable {
    case beforeDay
    case afterDay

    var id: String { rawValue }
}

/// DDL 设置页的按钮行。
private struct DDLSettingsActionRow: View {
    let title: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.content) {
            Text(title)
                .foregroundStyle(AppDesignSystem.Palette.Accent.primary)

            Spacer(minLength: AppDesignSystem.Spacing.none)

            if let value {
                Text(value)
                    .foregroundStyle(AppDesignSystem.Palette.Accent.primary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// DDL 设置页的数值选择弹窗。
private struct DDLSettingsNumberPickerSheet: View {
    let title: String
    let onSubmit: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: Int

    init(title: String, initialValue: Int, onSubmit: @escaping (Int) -> Void) {
        self.title = title
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
                .accessibilityLabel(title)
                .appSelectionFeedback(trigger: value)
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
        .presentationDetents([.height(AppDesignSystem.Schedule.ddlNumericPickerHeight)])
        .presentationDragIndicator(.visible)
    }
}

#endif
