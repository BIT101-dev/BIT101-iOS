import XCTest

nonisolated final class MaintenancePerformanceUITests: XCTestCase {
    @MainActor
    private func application() -> XCUIApplication {
        UIAutomationTestCase.endSharedSession()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment = [
            "BIT101_UI_TESTING": "1", "BIT101_UI_TEST_CASE": name,
            "BIT101_UI_TEST_RUN_ID": "ui", "BIT101_UI_TEST_RESET_STORAGE": "1",
            "BIT101_UI_TEST_ACCOUNT": "ui-test-student", "BIT101_UI_TEST_TAB": "schedule",
            "BIT101_UI_TEST_SCHOOL": "1", "BIT101_UI_TEST_ANIMATIONS": "1",
        ]
        return app
    }

    @MainActor
    func testStartupPerformance() {
        let app = application()
        defer { app.terminate() }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)]) {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["下一周"].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testScheduleWeekLayoutPerformance() {
        let app = application()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["下一周"].waitForExistence(timeout: 5))
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)]) {
            for _ in 0..<10 {
                app.buttons["下一周"].tap()
                XCTAssertTrue(app.buttons["第2周"].isSelected)
                app.buttons["上一周"].tap()
                XCTAssertTrue(app.buttons["第1周"].isSelected)
            }
        }
    }
}
