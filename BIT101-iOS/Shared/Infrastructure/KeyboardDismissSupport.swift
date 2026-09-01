import SwiftUI
import UIKit

@MainActor
private enum AppKeyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

/// 给整个 App 统一补齐键盘完成按钮和点击空白处收起。
private struct KeyboardDismissSupportModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(KeyboardBackgroundTapInstaller().frame(width: 0, height: 0))
    }
}

extension View {
    func appKeyboardDismissSupport() -> some View {
        modifier(KeyboardDismissSupportModifier())
    }
}

/// 在主窗口统一安装键盘附件和不拦截页面操作的空白点击手势。
struct KeyboardBackgroundTapInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.isUserInteractionEnabled = false
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: WindowObserverView, context: Context) {
        context.coordinator.attach(to: uiView.window)
    }

    static func dismantleUIView(_ uiView: WindowObserverView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private static let accessoryTag = 0x42495431
        private weak var window: UIWindow?
        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(didTapBackground))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textInputDidBeginEditing(_:)),
                name: UITextField.textDidBeginEditingNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textInputDidBeginEditing(_:)),
                name: UITextView.textDidBeginEditingNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to newWindow: UIWindow?) {
            guard window !== newWindow else { return }
            detach()
            window = newWindow
            newWindow?.addGestureRecognizer(recognizer)
        }

        func detach() {
            window?.removeGestureRecognizer(recognizer)
            window = nil
        }

        @objc private func didTapBackground() {
            AppKeyboard.dismiss()
        }

        @objc private func textInputDidBeginEditing(_ notification: Notification) {
            if let textField = notification.object as? UITextField {
                installAccessory(on: textField)
            } else if let textView = notification.object as? UITextView {
                installAccessory(on: textView)
            }
        }

        private func installAccessory(on input: UIResponder & UITextInput) {
            let existingAccessory: UIView?
            if let textField = input as? UITextField {
                existingAccessory = textField.inputAccessoryView
            } else if let textView = input as? UITextView {
                existingAccessory = textView.inputAccessoryView
            } else {
                return
            }
            guard existingAccessory?.tag != Self.accessoryTag else { return }

            let toolbar = UIToolbar()
            toolbar.tag = Self.accessoryTag
            toolbar.sizeToFit()
            toolbar.items = [
                UIBarButtonItem(systemItem: .flexibleSpace),
                UIBarButtonItem(title: "✓ 完成", style: .done, target: self, action: #selector(donePressed))
            ]

            if let textField = input as? UITextField {
                textField.inputAccessoryView = toolbar
                textField.reloadInputViews()
            } else if let textView = input as? UITextView {
                textView.inputAccessoryView = toolbar
                textView.reloadInputViews()
            }
        }

        @objc private func donePressed() {
            AppKeyboard.dismiss()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView {
                    return false
                }
                view = current.superview
            }
            return true
        }
    }
}

final class WindowObserverView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}
