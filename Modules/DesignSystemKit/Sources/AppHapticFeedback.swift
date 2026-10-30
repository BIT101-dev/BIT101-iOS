#if os(iOS)
//
//  AppHapticFeedback.swift
//  BIT101-iOS
//

import SwiftUI
import UIKit

/// `View` 通过统一入口请求离散选择和操作动作的系统触感；系统根据设备能力和设置决定是否输出。
extension View {
    public func appSelectionFeedback<Trigger: Equatable>(trigger: Trigger) -> some View {
        onChange(of: trigger) { _, _ in UISelectionFeedbackGenerator().selectionChanged() }
    }

    public func appImpactFeedback<Trigger: Equatable>(trigger: Trigger) -> some View {
        onChange(of: trigger) { _, _ in UIImpactFeedbackGenerator().impactOccurred() }
    }
}
#endif
