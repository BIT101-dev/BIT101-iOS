import XCTest

nonisolated final class MaintenancePerformanceUITests: XCTestCase {
    @MainActor
    private func application(animations: Bool = true) -> XCUIApplication {
        UIAutomationTestCase.endSharedSession()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment = [
            "BIT101_UI_TEST_CONTROL_PORT": String(UITestControlClient.port),
            "BIT101_UI_TESTING": "1", "BIT101_UI_TEST_CASE": name,
            "BIT101_UI_TEST_RUN_ID": "ui", "BIT101_UI_TEST_RESET_STORAGE": "1",
            "BIT101_UI_TEST_ACCOUNT": "ui-test-student", "BIT101_UI_TEST_TAB": "schedule",
            "BIT101_UI_TEST_SCHOOL": "1", "BIT101_UI_TEST_ANIMATIONS": animations ? "1" : "0",
        ]
        return app
    }

    @MainActor
    func testStartupPerformance() throws {
        let workload = try PerformanceWorkload("startup", bundle: Bundle(for: Self.self))
        XCTAssertEqual(try workload.value("operation", as: String.self), "terminate-launch-schedule-ready")
        XCTAssertEqual(try workload.value("storage", as: String.self), "retained")
        XCTAssertEqual(try workload.value("composition", as: String.self), "production")
        let app = application()
        app.launchEnvironment["BIT101_UI_TEST_PERFORMANCE_COURSES"] = String(try workload.value("courses", as: Int.self))
        app.launchEnvironment["BIT101_UI_TEST_PERFORMANCE_WEEKS"] = String(try workload.value("weeks", as: Int.self))
        let restoredCourse = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "性能课程 1")).firstMatch
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(restoredCourse.waitForExistence(timeout: 5))
        app.terminate()
        app.launchEnvironment["BIT101_UI_TEST_RESET_STORAGE"] = "0"
        app.launchEnvironment["BIT101_UI_TEST_PRODUCTION_COMPOSITION"] = "1"
        app.launchEnvironment["BIT101_UI_TEST_SCHOOL"] = "0"
        app.launchEnvironment["BIT101_UI_TEST_CONTENT"] = "1"
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)]) {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["下一周"].waitForExistence(timeout: 5))
            XCTAssertTrue(restoredCourse.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testScheduleWeekLayoutPerformance() throws {
        let workload = try PerformanceWorkload("schedule-layout", bundle: Bundle(for: Self.self))
        let pairs = try workload.value("weekSwitchPairs", as: Int.self)
        let app = application(animations: try workload.value("animations", as: Bool.self))
        app.launchEnvironment["BIT101_UI_TEST_PERFORMANCE_COURSES"] = String(try workload.value("courses", as: Int.self))
        app.launchEnvironment["BIT101_UI_TEST_PERFORMANCE_WEEKS"] = String(try workload.value("weeks", as: Int.self))
        app.launchEnvironment["BIT101_UI_TEST_PERFORMANCE_COURSES_PER_SLOT"] = String(try workload.value("coursesPerSlot", as: Int.self))
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["下一周"].waitForExistence(timeout: 5))
        for index in [1, 4] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "性能课程 \(index)")).firstMatch.waitForExistence(timeout: 5))
        }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)]) {
            for _ in 0..<pairs {
                app.buttons["下一周"].tap()
                XCTAssertTrue(app.buttons["第2周"].isSelected)
                app.buttons["上一周"].tap()
                XCTAssertTrue(app.buttons["第1周"].isSelected)
            }
        }
    }
}
