import DesignSystemKit
import SwiftUI
import UIKit

@MainActor
private enum AppKeyboard {
    static let accessories = NSMapTable<UIResponder, UIToolbar>.weakToStrongObjects()
    static func dismiss() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.endEditing(true) }
        }
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
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WindowObserverView {
        context.coordinator.interactionEvidence = interactionEvidence
        let view = WindowObserverView()
        view.isUserInteractionEnabled = false
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: WindowObserverView, context: Context) {
        context.coordinator.interactionEvidence = interactionEvidence
        context.coordinator.attach(to: uiView.window)
    }

    static func dismantleUIView(_ uiView: WindowObserverView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var interactionEvidence: ((String, String) -> Void)?
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
                self?.interactionEvidence?("interaction.KeyboardBackgroundTapInstaller.background-tap", "tap")
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
            let toolbar: UIToolbar
            if let installed = AppKeyboard.accessories.object(forKey: input) {
                toolbar = installed
            } else if let existing = existingAccessory as? UIToolbar,
                      existing.items?.contains(where: { $0.accessibilityIdentifier == "keyboard.dismiss" }) == true {
                toolbar = existing
            } else {
                toolbar = UIToolbar()
                let doneButton = UIButton(type: .system)
                doneButton.setTitle("✓ 完成", for: .normal)
                doneButton.accessibilityIdentifier = "keyboard.dismiss"
                doneButton.addAction(UIAction { _ in AppKeyboard.dismiss() }, for: .touchUpInside)
                doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: AppDesignSystem.Size.Control.touchTarget).isActive = true
                doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: AppDesignSystem.Size.Control.touchTarget).isActive = true
                let doneItem = UIBarButtonItem(customView: doneButton)
                doneItem.accessibilityIdentifier = "keyboard.dismiss"
                toolbar.items = [
                    UIBarButtonItem(systemItem: .flexibleSpace),
                    doneItem,
                ]
                toolbar.sizeToFit()
            }
            AppKeyboard.accessories.setObject(toolbar, forKey: input)
            guard existingAccessory !== toolbar else { return }
            let needsReload = toolbar.window == nil

            if let textField = input as? UITextField {
                textField.inputAccessoryView = toolbar
                if needsReload { textField.reloadInputViews() }
            } else if let textView = input as? UITextView {
                textView.inputAccessoryView = toolbar
                if needsReload { textView.reloadInputViews() }
            }
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
