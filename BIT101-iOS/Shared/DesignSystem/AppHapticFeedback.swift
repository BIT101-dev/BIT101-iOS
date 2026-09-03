//
//  AppHapticFeedback.swift
//  BIT101-iOS
//

import SwiftUI

/// 为离散选择统一请求系统触感；是否实际输出由系统和设备设置决定。
extension View {
    func appSelectionFeedback<Trigger: Equatable>(trigger: Trigger) -> some View {
        sensoryFeedback(.selection, trigger: trigger)
    }

    func appImpactFeedback<Trigger: Equatable>(trigger: Trigger) -> some View {
        sensoryFeedback(.impact, trigger: trigger)
    }
}
