import ScheduleFeature
import DesignSystemKit
import SwiftUI

/// 应用偏好与云同步状态适配到日程设置页。
struct AppCalendarSettingsPage: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var preferenceCloudSync: ExperimentalPreferenceCloudSync

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
        }
    }
}
