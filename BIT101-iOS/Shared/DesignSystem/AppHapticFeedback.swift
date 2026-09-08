//
//  AppHapticFeedback.swift
//  BIT101-iOS
//

import SwiftUI

/// `View` 通过统一入口请求离散选择和操作动作的系统触感；系统根据设备能力和设置决定是否输出。
extension View {
    func appSelectionFeedback<Trigger: Equatable>(trigger: Trigger) -> some View {
        sensoryFeedback(.selection, trigger: trigger)
    }

    func appImpactFeedback<Trigger: Equatable>(trigger: Trigger) -> some View {
        sensoryFeedback(.impact, trigger: trigger)
    }
}
