import CoreGraphics
import Network
import XCTest
import os

extension UIAutomationTestCase {
    @MainActor @discardableResult
    func toggle(_ title: String) -> String {
        let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", title))
            .firstMatch
        reveal(control, description: title)
        let initial = control.value as? String
        let nativeSwitch = control.switches.firstMatch
        if nativeSwitch.exists { nativeSwitch.tap() } else { control.tap() }
        reveal(control, description: title)
        assertUI(
            waitUntil(
                NSPredicate { _, _ in control.value as? String != nil }, on: control, timeout: 5),
            "开关操作后应恢复当前设置项的可读数值：\(title)。")
        guard let value = control.value as? String else {
            assertUI(false, "开关操作后应保留当前设置页和可读数值：\(title)。")
            return ""
        }
        var updated = value
        if updated == initial {
            assertUI(
                waitUntil(
                    NSPredicate(format: "value != %@", initial ?? ""), on: control, timeout: 5),
                "开关应改变状态：\(title)")
            updated = control.value as? String ?? ""
        }
        return updated
    }

    @MainActor
    func choose(_ title: String, option: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        reveal(row, description: title)
        row.tap()
        let choice = app.buttons.matching(NSPredicate(format: "label == %@", option)).firstMatch
        guard choice.appears(timeout: 5) else {
            assertUI(false, "选择菜单应展示选项：\(option)。")
            return
        }
        choice.tap()
        if row.label.hasSuffix(option) || row.value as? String == option { return }
        assertUI(
            waitUntil(
                NSPredicate(format: "label ENDSWITH %@ OR value == %@", option, option), on: row,
                timeout: 5), "选择应更新\(title)为\(option)。")
    }

    @MainActor
    func replaceText(_ text: String, in field: UIElement) {
        if text.hasSuffix("\n") {
            replaceTextWithKeyboard(text, in: field)
            return
        }
        if UIElement.usesNativeInteraction { reveal(field, description: "输入字段") }
        assertUI(field.appears(timeout: 5), "输入操作应等待字段出现。")
        if UIElement.usesNativeInteraction { field.tapBriefly() }
        enterText(text, in: field)
        let secure = field.elementType == .secureTextField
        waitForValue(secure ? String(repeating: "•", count: text.count) : text, of: field)
    }

    @MainActor
    private func enterText(_ text: String, in field: UIElement) {
        let response = field.insertText(text)
        if response == "native" {
            field.press(forDuration: 0.01)
            assertUI(app.buttons["keyboard.dismiss"].appears(timeout: 5), "输入控件应完成键盘附件安装。")
            guard let current = try? field.snapshot() else {
                assertUI(false, "输入字段应提供当前布局。")
                return
            }
            let result = UITestControlClient.request(
                [
                    "command": "input", "text": text,
                    "x": String(Double(current.frame.midX)),
                    "y": String(Double(current.frame.midY)),
                ], timeout: 5)
            assertUI(result == "entered", "文本应通过实际输入控件更新：\(result ?? "empty")。")
        } else {
            assertUI(response == "entered", "文本应通过实际输入控件更新：\(response ?? "empty")。")
        }
    }

    @MainActor
    func fillVerificationCode(_ text: String, in field: UIElement) {
        guard prepareInput(field) != nil else { return }
        if UIElement.usesNativeInteraction {
            UIElement.beforeNativeTap?()
            field.native.tap()
            UITestSnapshotReader.invalidate()
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in
                        UITestControlClient.request(["command": "keyboard-state"]) == "active"
                    }, on: app), "验证码输入应取得键盘焦点。")
        }
        enterText(text, in: field)
    }

    @MainActor
    func replaceTextWithKeyboard(_ text: String, in field: UIElement) {
        guard let state = prepareInput(field) else { return }
        enterWithKeyboard(text, in: field, state: state)
        assertEnteredText(text, in: field, state: state)
    }

    @MainActor
    private func prepareInput(_ field: UIElement) -> (any XCUIElementSnapshot)? {
        assertUI(field.appears(timeout: 5), "输入操作应等待字段出现。")
        guard let state = try? field.snapshot() else {
            assertUI(false, "输入字段应提供可读的界面状态。")
            return nil
        }
        return state
    }

    @MainActor
    private func enterWithKeyboard(
        _ text: String, in field: UIElement, state: any XCUIElementSnapshot
    ) {
        let value = state.value as? String ?? ""
        let empty = value.isEmpty || value == state.placeholderValue
        UIElement.beforeNativeTap?()
        field.native.tap()
        UITestSnapshotReader.invalidate()
        let keyboard = app.keyboards.firstMatch
        if !keyboard.exists {
            let nextKeyboard = UIElement(app.native.buttons["下一个键盘"])
            if nextKeyboard.exists { nextKeyboard.tapBriefly() }
            assertUI(keyboard.appears(timeout: 5), "文本输入应使用系统键盘。")
        }
        dismissKeyboardIntroduction()
        assertUI(app.buttons["keyboard.dismiss"].appears(timeout: 5), "系统输入应等待键盘附件完成安装。")
        if !empty {
            let selected = UITestControlClient.request(["command": "select-input"])
            assertUI(selected == "selected", "系统键盘替换应先选中输入框的完整文本。")
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            waitForValue("", of: field)
        }
        field.typeText(text)
    }

    @MainActor
    private func assertEnteredText(
        _ text: String, in field: UIElement, state: any XCUIElementSnapshot
    ) {
        let expected =
            state.elementType == .secureTextField
            ? String(repeating: "•", count: text.count)
            : text.trimmingCharacters(in: .newlines)
        if field.value as? String == expected { return }
        assertUI(
            waitUntil(NSPredicate(format: "value == %@", expected), on: field, timeout: 5),
            "输入应完整替换文本，当前值：\(String(describing: field.value))。")
    }

    @MainActor
    func dismissKeyboard() {
        guard UITestControlClient.request(["command": "keyboard-state"]) != "hidden" else { return }
        if UIElement.usesNativeInteraction {
            dismissKeyboardIntroduction()
            let done = app.buttons["keyboard.dismiss"]
            assertUI(done.appears(timeout: 5), "系统键盘应呈现完成按钮。")
            let keyboard = app.native.keyboards.firstMatch
            let positioned = NSPredicate { _, _ in
                let bounds = self.app.native.windows.firstMatch.frame
                return bounds.contains(done.native.frame)
            }
            assertUI(
                waitUntil(positioned, on: done, timeout: 5),
                """
                完成按钮应完整显示在窗口内：按钮 \(done.native.frame)，窗口 \(app.native.windows.firstMatch.frame)\
                ，键盘 \(keyboard.exists ? keyboard.frame : .null)。
                """
            )
            done.native.tap()
            UITestSnapshotReader.invalidate()
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in
                        UITestControlClient.request(["command": "keyboard-state"]) == "hidden"
                    },
                    on: app, timeout: 5), "原生完成按钮应关闭当前键盘。")
            return
        }
        let deadline = Date().addingTimeInterval(2)
        var result = UITestControlClient.request(["command": "finish-input"], timeout: 5)
        while result == "input toolbar missing" && Date() < deadline {
            UITestSnapshotReader.poll()
            result = UITestControlClient.request(["command": "finish-input"], timeout: 5)
        }
        assertUI(result == "finished", "键盘完成按钮应执行实际目标动作：\(result ?? "empty")。")
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    UITestControlClient.request(["command": "keyboard-state"]) == "hidden"
                }, on: app),
            "完成输入后键盘应收起。")
    }

    @MainActor
    private func dismissKeyboardIntroduction() {
        let introduction = app.native.otherElements["UIContinuousPathIntroductionView"]
        guard introduction.exists else { return }
        let proceed = introduction.buttons.firstMatch
        assertUI(proceed.waitForExistence(timeout: 5), "系统键盘介绍应提供继续操作。")
        proceed.tap()
        UITestSnapshotReader.invalidate()
        assertUI(UIElement(introduction).disappears(timeout: 5), "继续后应恢复系统键盘。")
    }

}
