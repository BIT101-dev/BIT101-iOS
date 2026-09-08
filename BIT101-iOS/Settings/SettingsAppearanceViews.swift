//
//  SettingsAppearanceViews.swift
//  BIT101-iOS
//
//  Split from SettingsRootView.swift.
//

import SwiftUI

/// 外观设置页。
///
/// 目前包含外观模式和自动旋转两项全局设置。
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
