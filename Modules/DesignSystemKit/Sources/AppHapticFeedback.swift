#if os(iOS)
import SwiftUI
import UIKit

/// 用户选择操作成功完成后统一发出一次系统触感。
@MainActor
public enum AppHapticFeedback {
    static var selectionFeedback: () -> Void = {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    public static func selection(_ change: () -> Bool) {
        if change() { selectionFeedback() }
    }
}

extension Binding where Value: Equatable {
    @MainActor public func appSelectionAction() -> Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { newValue in
                AppHapticFeedback.selection {
                    let previous = wrappedValue
                    guard previous != newValue else { return false }
                    wrappedValue = newValue
                    return previous != wrappedValue
                }
            })
    }
}

/// `View` 通过统一入口请求离散选择和操作动作的系统触感；系统根据设备能力和设置决定是否输出。
extension View {
    public func appSelectionFeedback<Trigger: Equatable>(trigger: Trigger) -> some View {
        modifier(
            AppHapticFeedbackModifier(trigger: trigger) {
                UISelectionFeedbackGenerator().selectionChanged()
            })
    }

    public func appImpactFeedback<Trigger: Equatable>(trigger: Trigger) -> some View {
        modifier(
            AppHapticFeedbackModifier(trigger: trigger) {
                UIImpactFeedbackGenerator().impactOccurred()
            })
    }
}

struct AppHapticFeedbackModifier<Trigger: Equatable>: ViewModifier {
    @Environment(\.appPageIsVisible) private var isVisible
    let trigger: Trigger
    let feedback: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: trigger) { _, _ in
            if isVisible { feedback() }
        }
    }
}
#endif
