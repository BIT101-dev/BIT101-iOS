#if os(iOS)
import DesignSystemKit

import SwiftUI

public struct DDLSettingsPage: View {
    @ObservedObject private var viewModel: ScheduleDDLViewModel
    @ObservedObject private var repository: ScheduleRepository
    @State private var pickerRoute: DDLSettingsNumberPickerRoute?

    public init(viewModel: ScheduleDDLViewModel) {
        self.viewModel = viewModel
        self.repository = viewModel.repository
    }

    public var body: some View {
        List {
            if repository.hasPersistenceConflict {
                Section { SchedulePersistenceConflictView(repository: repository) }
            } else if repository.hasReadFailure || repository.requiresRecoveryConfirmation {
                Section { ScheduleCacheRecoveryView(repository: repository) }
            }
            Section("课程中心") {
                Button("刷新学校日程") {
                    Task { await viewModel.syncDDL() }
                }
                .disabled(viewModel.isSyncingDDL || !repository.acceptsEdits)
                .accessibilityIdentifier("ddl.refresh")
                .appInteractiveListRow()
            }

            Section("乐学订阅") {
                Button {
                    Task { await viewModel.refreshLexueCalendarURL() }
                } label: {
                    DDLSettingsActionRow(
                        title: "重新获取订阅链接"
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSyncingDDL || !repository.acceptsEdits)
                .appInteractiveListRow()
                    .accessibilityIdentifier("ui.ddl-settings-page.refresh-subscription")
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
                .appInteractiveListRow()
                    .accessibilityIdentifier("ui.ddl-settings-page.before-day")

                Button {
                    pickerRoute = .afterDay
                } label: {
                    DDLSettingsActionRow(
                        title: "滞留天数",
                        value: "\(viewModel.afterDay) 天"
                    )
                }
                .buttonStyle(.plain)
                .appInteractiveListRow()
                    .accessibilityIdentifier("ui.ddl-settings-page.after-day")
            }
            .disabled(!repository.acceptsEdits)
        }
        .accessibilityIdentifier("interaction.DDLSettingsPage.list")
        .appGroupedListStyle()
        .task { await viewModel.loadIfNeeded() }
        .scheduleSchoolVerification(viewModel: viewModel)
        .sheet(item: $pickerRoute) { route in
            switch route {
            case .beforeDay:
                DDLSettingsNumberPickerSheet(
                    title: "变色天数",
                    initialValue: viewModel.beforeDay, repository: repository
                ) { value in
                    viewModel.setDDLBeforeDay(value)
                }
            case .afterDay:
                DDLSettingsNumberPickerSheet(
                    title: "滞留天数",
                    initialValue: viewModel.afterDay, repository: repository
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

            Spacer(minLength: AppDesignSystem.Spacing.none)

            if let value {
                Text(value)
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
}

/// DDL 设置页的数值选择弹窗。
private struct DDLSettingsNumberPickerSheet: View {
    let title: String
    let onSubmit: (Int) -> Bool
    @ObservedObject private var repository: ScheduleRepository

    @Environment(\.dismiss) private var dismiss
    @State private var value: Int

    init(title: String, initialValue: Int, repository: ScheduleRepository, onSubmit: @escaping (Int) -> Bool) {
        self.title = title
        self.repository = repository
        self.onSubmit = onSubmit
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            VStack {
                if repository.hasPersistenceConflict {
                    SchedulePersistenceConflictView(repository: repository)
                } else if repository.hasReadFailure || repository.requiresRecoveryConfirmation {
                    ScheduleCacheRecoveryView(repository: repository)
                }
                Picker(title, selection: $value) {
                    ForEach(0 ... 30, id: \.self) { day in
                        Text("\(day) 天")
                            .tag(day)
                    }
                }
                .disabled(!repository.acceptsEdits)
                .pickerStyle(.wheel)
                .labelsHidden()
                .accessibilityLabel(title)
                .appSelectionFeedback(trigger: value)
                    .accessibilityIdentifier("ui.ddl-settings-number-picker-sheet.value")
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                        .accessibilityIdentifier("ui.ddl-settings-number-picker-sheet.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if onSubmit(value) { dismiss() }
                    }
                        .disabled(!repository.acceptsEdits)
                        .accessibilityIdentifier("ui.ddl-settings-number-picker-sheet.done")
                }
            }
        }
        .presentationDetents([.height(AppDesignSystem.Schedule.ddlNumericPickerHeight)])
        .presentationDragIndicator(.visible)
    }
}

#endif
