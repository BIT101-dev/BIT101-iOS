import CoreGraphics
import Network
import XCTest
import os

extension UIAutomationTestCase {
    @MainActor
    func signIn(_ application: UIElement, studentID inputStudentID: String = "ui-test-student") {
        let studentID = application.textFields["login.student-id"]
        let password = application.secureTextFields["login.password"]
        let submit = application.buttons["login.submit"]
        assertUI(studentID.appears(timeout: 10), "测试启动后应展示登录页。")

        replaceTextWithKeyboard(inputStudentID + "\n", in: studentID)
        replaceTextWithKeyboard("ui-test-password", in: password)
        assertUI(submit.isEnabled, "完整填写账号信息后，登录按钮应启用。")
        password.typeText("\n")
        dismissCredentialSavePrompt(in: application)
        assertUI(
            application.mainTab("日程").appears(timeout: 10),
            "登录后应进入日程页。"
        )
        let scheduleTab = application.mainTab("日程")
        if !scheduleTab.isSelected { scheduleTab.tapBriefly() }
        let courses = application.segmentedControls.buttons["课表"]
        if courses.exists && !courses.isSelected { courses.tapBriefly() }
        let scheduleReady = application.buttons["schedule.add-content"]
        assertUI(
            waitUntil(
                NSPredicate { _, _ in scheduleReady.exists && scheduleReady.isHittable },
                on: application, timeout: 10), "日程首屏应完成加载并提供编辑入口。")
    }

    @MainActor
    func dismissCredentialSavePrompt(in application: UIElement) {
        let prompt = application.sheets["保存密码？"]
        guard prompt.exists else { return }
        let nonSavingActions = ["取消", "不保存", "稍后", "暂不", "以后", "以后再说", "稍后再说", "关闭"]
        let buttons = prompt.buttons.allElementsBoundByIndex
        guard let dismissAction = buttons.first(where: { nonSavingActions.contains($0.label) })
        else {
            let labels = buttons.map(\.label).joined(separator: "、")
            assertUI(false, "系统密码提示应提供安全关闭操作。按钮：\(labels)")
            return
        }
        dismissAction.tapBriefly()
        assertUI(!prompt.exists, "合成测试凭据的系统保存提示应自动收起。")
    }

}
