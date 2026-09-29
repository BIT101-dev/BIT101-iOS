import XCTest

nonisolated final class LoginAndScheduleUITests: XCTestCase {
    @MainActor private var app: XCUIApplication!
    private let runIdentifier = "ui"

    @MainActor
    func testLoginFormTracksRequiredCredentialsAndOpensSchedule() throws {
        app = launchApp(resetStorage: true)

        let studentID = app.textFields["login.student-id"]
        let password = app.secureTextFields["login.password"]
        let submit = app.buttons["login.submit"]

        assertUI(studentID.waitForExistence(timeout: 10), "登录页应展示学号输入框。")
        assertUI(password.exists, "登录页应展示密码输入框。")
        assertUI(!submit.isEnabled, "凭据完整前登录按钮应保持禁用。")

        studentID.tap()
        studentID.typeText("ui-test-student\n")
        assertUI(!submit.isEnabled, "仅输入学号时登录按钮应保持禁用。")

        password.typeText("ui-test-password")
        assertUI(submit.isEnabled, "完整填写账号信息后，登录按钮应启用。")
        password.typeText("\n")
        dismissCredentialSavePrompt(in: app)
        let scheduleTab = app.tabBars.buttons["app.tab.schedule"]
        assertUI(scheduleTab.waitForExistence(timeout: 10), "登录后应进入日程页。")
        assertUI(scheduleTab.isSelected, "日程 Tab 应处于选中状态。")
    }

    @MainActor
    func testLongPressOpensScheduleContextMenuAndImportSheet() throws {
        app = launchApp(resetStorage: true)
        signIn(app)

        let contextArea = app.descendants(matching: .any)
            .matching(identifier: "schedule.blank-context-menu")
            .firstMatch
        assertUI(contextArea.waitForExistence(timeout: 10), "日程页面应展示可操作的空白课表区域。")
        contextArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)

        let shareAction = app.descendants(matching: .any)
            .matching(identifier: "schedule.menu.share")
            .firstMatch
        let importAction = app.descendants(matching: .any)
            .matching(identifier: "schedule.menu.import")
            .firstMatch
        assertUI(
            shareAction.waitForExistence(timeout: 5),
            "长按课表区域后应展示分享操作。\(focusedAccessibilitySnapshot(app, matching: ["分享", "导入", "课表", "menu"]))"
        )
        assertUI(importAction.exists, "长按课表区域后应展示导入操作。")

        importAction.tap()
        assertUI(app.navigationBars["导入课表"].waitForExistence(timeout: 5), "点按导入后应打开导入课表面板。")
        assertUI(app.textViews["schedule.import.code"].exists, "导入面板应展示课表编码编辑区。")
    }

    @MainActor
    func testManualSchedulePersistsAcrossAppRelaunch() throws {
        app = launchApp(resetStorage: true)
        signIn(app)

        addCustomSchedule("自动化测试日程", in: app)

        app.terminate()
        app = launchApp(resetStorage: false)
        let savedSchedule = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "自动化测试日程"))
            .firstMatch
        assertUI(
            savedSchedule.waitForExistence(timeout: 10),
            "重新启动后应恢复已保存的自定义日程。\(focusedAccessibilitySnapshot(app, matching: ["自动化测试日程", "课表"]))"
        )
    }

    @MainActor
    func testCustomSchedulesAreIsolatedBetweenAccounts() throws {
        app = launchApp(resetStorage: true)
        signIn(app, studentID: "ui-test-account-a")
        addCustomSchedule("A 账户专属日程", in: app)

        app.tabBars.buttons["app.tab.mine"].tap()
        let accountRoute = app.buttons["settings.route.account"]
        assertUI(accountRoute.waitForExistence(timeout: 10), "我的页面应展示账号设置入口。")
        accountRoute.tap()

        let logout = app.buttons["settings.account.logout"]
        assertUI(logout.waitForExistence(timeout: 5), "账号设置应展示退出操作。")
        logout.tap()

        let studentID = app.textFields["login.student-id"]
        let password = app.secureTextFields["login.password"]
        assertUI(studentID.waitForExistence(timeout: 10), "退出后应返回登录表单。")
        studentID.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        studentID.typeText("-account-b\n")
        password.typeText("ui-test-password")
        assertUI(app.buttons["login.submit"].isEnabled, "账号 B 登录前应完成表单输入。")
        password.typeText("\n")
        dismissCredentialSavePrompt(in: app)
        assertUI(app.tabBars.buttons["app.tab.schedule"].waitForExistence(timeout: 10), "账号 B 登录后应进入日程页。")
        let scheduleReady = app.descendants(matching: .any)
            .matching(identifier: "schedule.blank-context-menu")
            .firstMatch
        assertUI(scheduleReady.waitForExistence(timeout: 10), "账号 B 的课表缓存应完成加载。")
        let accountASchedule = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "自定义日程，A 账户专属日程"))
            .firstMatch
        assertUI(!accountASchedule.exists, "账号 B 的课表应隔离账号 A 的日程。")
    }

    @MainActor
    private func addCustomSchedule(_ titleText: String, in application: XCUIApplication) {
        let addContent = application.buttons["schedule.add-content"]
        assertUI(addContent.waitForExistence(timeout: 10), "课表页应展示添加内容入口。")
        assertUI(
            addContent.isHittable,
            "添加入口应处于可点击位置。frame=\(addContent.frame); \(focusedAccessibilitySnapshot(application, matching: ["Window", "Alert", "Sheet", "Menu", "添加", "课表", "保存", "密码", "之后", "稍后", "现在"]))"
        )
        addContent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let addSchedule = application.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "添加日程"))
            .firstMatch
        assertUI(
            addSchedule.waitForExistence(timeout: 5),
            "添加菜单应展示自定义日程操作。\(focusedAccessibilitySnapshot(application, matching: ["添加", "日程"]))"
        )
        addSchedule.tap()

        let title = application.textFields["schedule.custom.title"]
        assertUI(title.waitForExistence(timeout: 5), "自定义日程面板应展示标题输入框。")
        title.tap()
        title.typeText("\(titleText)\n")

        let save = application.buttons["schedule.custom.save"]
        assertUI(save.waitForExistence(timeout: 5), "自定义日程面板应展示保存操作。")
        save.tap()
        let savedSchedule = application.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", titleText))
            .firstMatch
        assertUI(
            savedSchedule.waitForExistence(timeout: 10),
            "保存后课表应展示新建的自定义日程。\(focusedAccessibilitySnapshot(application, matching: [titleText, "保存", "确定", "日程", "课表"]))"
        )
    }

    @MainActor
    func testTestSessionSurvivesAppRelaunch() throws {
        app = launchApp(resetStorage: true)
        signIn(app)
        app.terminate()

        app = launchApp(resetStorage: false)
        let scheduleTab = app.tabBars.buttons["app.tab.schedule"]
        assertUI(scheduleTab.waitForExistence(timeout: 10), "重新启动后应恢复测试登录会话。")
        assertUI(!app.buttons["login.submit"].exists, "会话恢复后应进入 App 主界面。")
    }

    @MainActor
    func testMainTabsNavigateWithOfflineServices() throws {
        app = launchApp(resetStorage: true)
        signIn(app)

        for identifier in ["app.tab.schedule", "app.tab.home", "app.tab.gallery", "app.tab.mine"] {
            let tab = app.tabBars.buttons[identifier]
            assertUI(tab.waitForExistence(timeout: 10), "App 主 Tab 应可交互：\(identifier)")
            tab.tap()
            assertUI(
                tab.isSelected,
                "点按后应选中对应的 App Tab：\(identifier)。\(focusedAccessibilitySnapshot(app, matching: ["登录", "我的", "个人", "账号", "失败"]))"
            )
            if identifier == "app.tab.gallery" {
                let offlineAlert = app.alerts["加载话廊失败"]
                assertUI(offlineAlert.waitForExistence(timeout: 10), "离线话廊请求应展示可关闭的失败提示。")
                let close = offlineAlert.buttons["知道了"]
                assertUI(close.exists, "话廊失败提示应提供关闭操作。")
                close.tap()
            }
        }
    }

    @MainActor
    func testScoreChallengeContinuesAfterSMSVerification() throws {
        app = launchApp(resetStorage: true)
        signIn(app)

        let scheduleTab = app.tabBars.buttons["app.tab.schedule"]
        scheduleTab.tap()
        assertUI(scheduleTab.isSelected, "日程 Tab 应完成首屏聚焦。")
        let scoreTab = app.tabBars.buttons["app.tab.home"]
        scoreTab.tap()
        assertUI(
            scoreTab.isSelected,
            "成绩 Tab 应在点按后选中。\(focusedAccessibilitySnapshot(app, matching: ["成绩", "日程", "查询", "刷新", "Selected"]))"
        )
        let queryScores = app.buttons["score.query"]
        assertUI(
            queryScores.waitForExistence(timeout: 10),
            "成绩页应展示查询操作。\(focusedAccessibilitySnapshot(app, matching: ["成绩", "查询", "刷新", "短信", "失败", "错误"]))"
        )
        queryScores.tap()

        let verificationCode = app.textFields["verification.code"]
        assertUI(
            verificationCode.waitForExistence(timeout: 10),
            "成绩查询遇到二次验证时应展示验证码输入框。\(focusedAccessibilitySnapshot(app, matching: ["验证", "短信", "成绩", "查询", "失败", "错误"]))"
        )
        verificationCode.typeText("123456")
        app.staticTexts["输入验证码"].tap()

        let verify = app.buttons["验证并查询成绩"]
        assertUI(verify.waitForExistence(timeout: 5), "短信验证面板应展示继续查询操作。")
        verify.tap()
        assertUI(app.staticTexts["自动化测试课程"].waitForExistence(timeout: 10), "短信验证后成绩列表应展示测试课程。")
    }

    @MainActor
    private func signIn(_ application: XCUIApplication, studentID inputStudentID: String = "ui-test-student") {
        let studentID = application.textFields["login.student-id"]
        let password = application.secureTextFields["login.password"]
        let submit = application.buttons["login.submit"]
        assertUI(studentID.waitForExistence(timeout: 10), "测试启动后应展示登录页。")

        studentID.tap()
        studentID.typeText("\(inputStudentID)\n")
        password.typeText("ui-test-password")
        assertUI(submit.isEnabled, "完整填写账号信息后，登录按钮应启用。")
        password.typeText("\n")
        dismissCredentialSavePrompt(in: application)
        assertUI(
            application.tabBars.buttons["app.tab.schedule"].waitForExistence(timeout: 10),
            "登录后应进入日程页。"
        )
        let scheduleReady = application.descendants(matching: .any)
            .matching(identifier: "schedule.blank-context-menu")
            .firstMatch
        assertUI(scheduleReady.waitForExistence(timeout: 10), "日程缓存与课表网格应完成首屏加载。")
    }

    @MainActor
    private func dismissCredentialSavePrompt(in application: XCUIApplication) {
        let prompt = application.sheets["保存密码？"]
        guard prompt.waitForExistence(timeout: 3) else { return }
        let nonSavingActions = ["取消", "不保存", "稍后", "暂不", "以后", "以后再说", "稍后再说", "关闭"]
        let buttons = prompt.buttons.allElementsBoundByIndex
        guard let dismissAction = buttons.first(where: { nonSavingActions.contains($0.label) }) else {
            let labels = buttons.map(\.label).joined(separator: "、")
            assertUI(false, "系统密码提示应提供安全关闭操作。按钮：\(labels)")
            return
        }
        dismissAction.tap()
        assertUI(!prompt.exists, "合成测试凭据的系统保存提示应自动收起。")
    }

    @MainActor
    private func assertUI(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !condition() else { return }
        if let application = app {
            let hierarchy = XCTAttachment(string: application.debugDescription)
            hierarchy.name = "失败时的界面元素树"
            add(hierarchy)
            if application.state == .runningForeground {
                let screenshot = XCTAttachment(screenshot: application.screenshot())
                screenshot.name = "失败时的界面截图"
                add(screenshot)
            }
        }
        XCTFail(message(), file: file, line: line)
    }

    @MainActor
    private func focusedAccessibilitySnapshot(
        _ application: XCUIApplication,
        matching terms: [String]
    ) -> String {
        let matches = application.debugDescription
            .split(separator: "\n")
            .filter { line in terms.contains(where: { line.contains($0) }) }
            .prefix(24)
        return matches.isEmpty ? "界面元素树中未检索到目标文案。" : matches.joined(separator: " | ")
    }

    @MainActor
    private func launchApp(resetStorage: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing"]
        application.launchEnvironment["BIT101_UI_TESTING"] = "1"
        application.launchEnvironment["BIT101_UI_TEST_RUN_ID"] = runIdentifier
        application.launchEnvironment["BIT101_UI_TEST_RESET_STORAGE"] = resetStorage ? "1" : "0"
        application.launch()
        return application
    }
}
