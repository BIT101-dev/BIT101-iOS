//
//  SettingsAppearanceViews.swift
//  BIT101-iOS
//
//  Split from SettingsRootView.swift.
//

import SwiftUI

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
