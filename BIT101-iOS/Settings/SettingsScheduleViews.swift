import ScheduleFeature
import DesignSystemKit
import SwiftUI

/// 应用偏好与云同步状态适配到日程设置页。
struct AppCalendarSettingsPage: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @ObservedObject var scheduleCloudSync: ScheduleCloudSyncPresentation
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var preferenceCloudSync: ExperimentalPreferenceCloudSync
    @State private var cleanupScope: ExperimentalPreferenceCloudSync.RecordCleanupScope?
    @State private var cleanupFeedback: String?

    var body: some View {
        CalendarSettingsPage(
            viewModel: viewModel,
            hasSeenSharedScheduleImportGuide: Binding(
                get: { settings.hasSeenSharedScheduleImportGuide },
                set: { seen in
                    if seen { settings.markSharedScheduleImportGuideSeen() }
                }
            ),
            appStoreURL: BIT101AppStore.url
        ) {
            if viewModel.settingsSnapshot.iCloudSyncEnabled {
                Text(scheduleCloudSync.message)
                    .font(AppDesignSystem.Typography.footnote)
                    .foregroundStyle(AppDesignSystem.Foreground.secondary)
                    .accessibilityIdentifier("settings.schedule.cloud-status")
            }
            Toggle("同步设置与使用偏好（实验性）", isOn: Binding(
                get: { preferenceCloudSync.isEnabled },
                set: { preferenceCloudSync.setEnabled($0) }
            ))
            .appSelectionFeedback(trigger: preferenceCloudSync.isEnabled)
            if let syncIssue = preferenceCloudSync.syncIssue {
                Text(syncIssue)
                    .font(AppDesignSystem.Typography.footnote)
                    .foregroundStyle(AppDesignSystem.Foreground.secondary)
                    .accessibilityLabel("iCloud 同步状态：\(syncIssue)")
            }
            Button("清理当前账号的云端偏好记录", role: .destructive) { cleanupScope = .currentAccount }
                .appInteractiveListRow(isDestructive: true)
            Button("清理其他账号的云端偏好记录", role: .destructive) { cleanupScope = .otherAccounts }
                .appInteractiveListRow(isDestructive: true)
        }
        .alert("清理云端偏好记录", isPresented: Binding(
            get: { cleanupScope != nil }, set: { if !$0 { cleanupScope = nil } }
        ), presenting: cleanupScope) { scope in
            Button("清理", role: .destructive) {
                cleanupFeedback = preferenceCloudSync.removeCloudRecords(in: scope)
                    ? "云端清理已提交，本机偏好同步已关闭。本机设置、成绩缓存和已读状态继续保留。"
                    : preferenceCloudSync.syncIssue
            }
            Button("取消", role: .cancel) { cleanupScope = nil }
        } message: { scope in
            Text("将关闭本机偏好同步，并删除\(scope == .currentAccount ? "当前学校账号" : "其他学校账号")在此 iCloud 账号中的设置、成绩筛选、成绩缓存和已读记录。本机数据继续保留，其他开启同步的设备可再次上传其本机数据。")
        }
        .alert("云端记录清理", isPresented: Binding(
            get: { cleanupFeedback != nil }, set: { if !$0 { cleanupFeedback = nil } }
        )) {
            Button("好") { cleanupFeedback = nil }
        } message: {
            Text(cleanupFeedback ?? "")
        }
    }
}
