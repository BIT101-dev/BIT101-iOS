import XCTest

@MainActor
final class LoginAndScheduleUITests: XCTestCase {
    private var app: XCUIApplication!
    private var runIdentifier = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        runIdentifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let app = app ?? XCUIApplication()
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "失败时的界面元素树"
            add(hierarchy)
            if app.state == .runningForeground {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "失败时的界面截图"
                add(screenshot)
            }
        }
        try super.tearDownWithError()
    }

    func testLoginFormTracksRequiredCredentialsAndOpensSchedule() throws {
        app = launchApp(resetStorage: true)

        let studentID = app.textFields["login.student-id"]
        let password = app.secureTextFields["login.password"]
        let submit = app.buttons["login.submit"]

        XCTAssertTrue(studentID.waitForExistence(timeout: 10))
        XCTAssertTrue(password.exists)
        XCTAssertFalse(submit.isEnabled)

        studentID.tap()
        studentID.typeText("ui-test-student")
        XCTAssertFalse(submit.isEnabled)

        password.tap()
        password.typeText("ui-test-password")
        XCTAssertTrue(submit.isEnabled)

        submit.tap()
        let scheduleTab = app.tabBars.buttons["app.tab.schedule"]
        XCTAssertTrue(scheduleTab.waitForExistence(timeout: 10))
        XCTAssertTrue(scheduleTab.isSelected)
    }

    func testLongPressOpensScheduleContextMenuAndImportSheet() throws {
        app = launchApp(resetStorage: true)
        signIn(app)

        let contextArea = app.descendants(matching: .any)
            .matching(identifier: "schedule.blank-context-menu")
            .firstMatch
        XCTAssertTrue(contextArea.waitForExistence(timeout: 10))
        contextArea.press(forDuration: 1)

        let shareAction = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "分享课表"))
            .firstMatch
        let importAction = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "导入课表"))
            .firstMatch
        XCTAssertTrue(shareAction.waitForExistence(timeout: 5))
        XCTAssertTrue(importAction.exists)

        importAction.tap()
        XCTAssertTrue(app.navigationBars["导入课表"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["schedule.import.code"].exists)
    }

    func testTestSessionSurvivesAppRelaunch() throws {
        app = launchApp(resetStorage: true)
        signIn(app)
        app.terminate()

        app = launchApp(resetStorage: false)
        let scheduleTab = app.tabBars.buttons["app.tab.schedule"]
        XCTAssertTrue(scheduleTab.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["login.submit"].exists)
    }

    private func signIn(_ application: XCUIApplication) {
        let studentID = application.textFields["login.student-id"]
        let password = application.secureTextFields["login.password"]
        let submit = application.buttons["login.submit"]
        XCTAssertTrue(studentID.waitForExistence(timeout: 10))

        studentID.tap()
        studentID.typeText("ui-test-student")
        password.tap()
        password.typeText("ui-test-password")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(application.tabBars.buttons["app.tab.schedule"].waitForExistence(timeout: 10))
    }

    private func launchApp(resetStorage: Bool) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing"]
        application.launchEnvironment["BIT101_UI_TESTING"] = "1"
        application.launchEnvironment["BIT101_UI_TEST_RUN_ID"] = runIdentifier
        application.launchEnvironment["BIT101_UI_TEST_RESET_STORAGE"] = resetStorage ? "1" : "0"
        application.launch()
        return application
    }
}
