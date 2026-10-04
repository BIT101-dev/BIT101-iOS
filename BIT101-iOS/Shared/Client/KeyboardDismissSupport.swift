import DesignSystemKit
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

/// 修饰器为视图安装键盘完成按钮，并为窗口安装键盘收起手势。
private struct KeyboardDismissSupportModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(KeyboardBackgroundTapInstaller().frame(width: AppDesignSystem.Spacing.none, height: AppDesignSystem.Spacing.none))
    }
}

extension View {
    func appKeyboardDismissSupport() -> some View {
        modifier(KeyboardDismissSupportModifier())
    }
}

/// 安装器为当前窗口安装键盘附件和保留页面操作的键盘收起手势。
@MainActor
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

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(didTapBackground))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesEnded = false
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
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardDidShow),
                name: UIResponder.keyboardDidShowNotification,
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
            if let newWindow, let input = Self.focusedInput(in: newWindow) {
                scheduleAccessory(on: input)
            }
        }

        func detach() {
            window?.removeGestureRecognizer(recognizer)
            window = nil
        }

        @objc private func didTapBackground() {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, Self.focusedInput(in: window) != nil else { return }
                AppKeyboard.dismiss()
            }
        }

        @objc private func textInputDidBeginEditing(_ notification: Notification) {
            if let textField = notification.object as? UITextField {
                guard textField.window === window else { return }
                scheduleAccessory(on: textField)
            } else if let textView = notification.object as? UITextView {
                guard textView.window === window else { return }
                scheduleAccessory(on: textView)
            }
        }

        @objc private func keyboardDidShow() {
            guard let window, let input = Self.focusedInput(in: window) else { return }
            scheduleAccessory(on: input)
        }

        private func scheduleAccessory(on input: UIResponder & UITextInput) {
            DispatchQueue.main.async { [weak self, weak input] in
                guard let self, let input, input.isFirstResponder,
                      (input as? UIView)?.window === self.window else { return }
                self.installAccessory(on: input)
            }
        }

        private static func focusedInput(in view: UIView) -> (UIResponder & UITextInput)? {
            if view.isFirstResponder, let input = view as? (UIResponder & UITextInput) { return input }
            for child in view.subviews {
                if let input = focusedInput(in: child) { return input }
            }
            return nil
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
            if let toolbar = existingAccessory as? UIToolbar,
               toolbar.items?.contains(where: { $0.accessibilityIdentifier == "keyboard.dismiss" }) == true { return }

            let toolbar = UIToolbar()
            let doneButton = UIBarButtonItem(
                title: "✓ 完成",
                style: .done,
                target: self,
                action: #selector(donePressed)
            )
            doneButton.accessibilityIdentifier = "keyboard.dismiss"
            toolbar.items = [
                UIBarButtonItem(systemItem: .flexibleSpace),
                doneButton,
            ]
            toolbar.sizeToFit()

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
            guard let view = touch.view else { return false }
            return acceptsBackgroundTouch(in: view)
        }

        func acceptsBackgroundTouch(in target: UIView) -> Bool {
            guard let window, Self.focusedInput(in: window) != nil,
                  var controller = window.rootViewController else { return false }
            while let presented = controller.presentedViewController { controller = presented }
            guard target.isDescendant(of: controller.view) else { return false }
            var view: UIView? = target
            while let current = view {
                if current is UIControl || current is UITextField || current is UITextView || current is UIInputView {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
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
