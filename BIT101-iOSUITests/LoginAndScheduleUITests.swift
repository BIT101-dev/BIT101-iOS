import CoreGraphics
import Network
import UIKit
import XCTest
import os

nonisolated final class LoginAndScheduleUITests: UIAutomationTestCase {
    @MainActor
    func testScheduleWeekButtonsAndSectionSwipes() {
        app = configureApp(resetStorage: true, school: true)
        let outside = app.scrollViews["schedule.calendar.outside-events"]
        assertUI(outside.appears(timeout: 5), "课间考试应提供课表展示入口。")
        outside.swipeLeft()
        assertUI(app.segmentedControls.buttons["课表"].isSelected, "日程条横滑应保留课表分栏。")
        app.buttons["schedule.entry.exam-ui-outside-exam"].tapBriefly()
        assertUI(app.navigationBars["考试详情"].appears(timeout: 5), "课间考试应打开详情。")
        assertUI(app.staticTexts["时间：12:30-12:45"].exists, "考试详情应保留课间原始时间。")
        tap("取消")
        tap("下一周")
        assertSelectedWeek(2)
        tap("上一周")
        assertSelectedWeek(1)
        tap("第3周")
        assertSelectedWeek(3)
        app.descendants(matching: .any)["schedule.section-surface"].swipeLeft()
        assertUI(app.segmentedControls.buttons["DDL"].isSelected, "横滑应切换到 DDL。")
        app.descendants(matching: .any)["schedule.section-surface"].swipeLeft()
        assertUI(app.sectionTab("空教室").isSelected, "横滑应切换到空教室。")
        closeAlertIfPresent()
        app.descendants(matching: .any)["schedule.section-surface"].swipeRight()
        assertUI(app.segmentedControls.buttons["DDL"].isSelected, "反向横滑应恢复 DDL。")
        tapHeader(app.segmentedControls.buttons.element(boundBy: 0))
        assertUI(app.buttons["schedule.add-content"].exists, "分栏切换应恢复课表交互。")
    }

    @MainActor
    func testPageSwipesCancelRowOpening() {
        app = configureApp(resetStorage: true, ddlFixture: "sources")
        tapHeader(app.segmentedControls.buttons["DDL"])
        let assignment = app.staticTexts["课程中心测试作业"]
        assertUI(assignment.appears(timeout: 5), "DDL 应显示可打开网页的作业。")
        assignment.swipeRight()
        assertUI(app.segmentedControls.buttons["课表"].isSelected, "从作业起滑应切回课表。")
        assertUI(app.buttons["schedule.add-content"].isHittable, "翻页后课表应直接可操作。")
        let add = app.buttons["schedule.add-content"]
        assertUI(add.frame.midX > app.frame.midX, "课表加号应位于右侧。")

        app = configureApp(resetStorage: true, content: true, initialTab: "home")
        tapHeader(app.segmentedControls.buttons["课程"])
        let course = app.staticTexts["自动化测试课程"]
        assertUI(course.appears(timeout: 5), "课程列表应展示测试课程。")
        course.swipeRight()
        assertUI(app.segmentedControls.buttons["成绩"].isSelected, "从课程起滑应回到成绩。")
        assertUI(!app.navigationBars["课程详情"].exists, "翻页应取消课程点击。")

        app.mainTab("话廊").tapBriefly()
        tapHeader(app.segmentedControls.buttons["最新"])
        let poster = app.descendants(matching: .any).matching(
            identifier: "community.poster.1"
        ).firstMatch
        assertUI(poster.appears(timeout: 5), "话廊应展示测试话题。")
        poster.swipeLeft()
        assertUI(!app.segmentedControls.buttons["最新"].isSelected, "从话题正文起滑应切换分区。")
        assertUI(!app.navigationBars["帖子详情"].exists, "翻页应取消话题点击。")
    }

    @MainActor
    func testCourseDetailsUseEdgeBack() {
        app = configureApp(resetStorage: true, content: true, initialTab: "home")
        tapHeader(app.segmentedControls.buttons["课程"])
        tap("自动化测试课程")
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "课程应打开原生详情导航。")
        let window = app.native.windows.firstMatch
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        let destination = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        edge.press(forDuration: 0, thenDragTo: destination)
        assertUI(app.navigationBars["课程详情"].disappears(timeout: 5), "左侧边缘拖动应返回课程列表。")
        assertUI(app.segmentedControls.buttons["课程"].isSelected, "返回应保留课程分区。")
    }

    @MainActor
    func testScheduleDayHolidayCancel() {
        app = configureApp(resetStorage: true)
        tap("第1周")
        let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1周，周一，"))
            .firstMatch
        assertUI(day.appears(timeout: 5), "每日表头应提供调整入口。")
        day.tapBriefly()
        assertUI(app.navigationBars["调休 / 放假"].appears(timeout: 5), "每日表头应打开日期调整。")
        tapHeader(app.segmentedControls.buttons["放假"])
        tap("确定")
        assertUI(app.alerts["确认放假"].appears(timeout: 5), "放假应展示确认。")
        app.alerts.buttons["取消"].tapBriefly()
        tapHeader(app.segmentedControls.buttons["调至某天"])
        assertUI(app.datePickers.firstMatch.exists, "调休应提供目标日期选择。")
        tap("确定")
        assertUI(app.alerts["确认调课"].appears(timeout: 5), "调休应展示确认。")
        app.alerts.buttons["取消"].tapBriefly()
        tap("取消")
        assertUI(app.buttons["schedule.add-content"].exists, "取消日期调整应恢复课表。")
    }

    @MainActor
    func testLinearScheduleTimelineScrollAndPinch() {
        app = configureApp(resetStorage: true)
        openSettings("calendar")
        assertInteractiveLabelUsesPrimaryColor("时间轴")
        choose("时间轴", option: "线性")
        back()
        app.mainTab("日程").tapBriefly()
        let timeline = app.scrollViews["schedule.linear.timeline"]
        assertUI(timeline.appears(timeout: 5), "线性模式应提供可缩放的时间轴。")
        let canvas = app.buttons["schedule.blank-context-menu"]
        XCTAssertEqual(
            canvas.native.frame.minX, timeline.native.frame.minX, accuracy: 0.5, "初始时间轴应与视口左界限对齐。")
        let initial = timeline.value as? String
        timeline.pinch(withScale: 1.5, velocity: 1)
        assertUI(
            waitUntil(NSPredicate(format: "value != %@", initial ?? ""), on: timeline, timeout: 5),
            "双指展开应放大时间轴，当前值：\(String(describing: timeline.value))，\(timeline.label)。")
        let enlarged = timeline.value as? String
        XCTAssertEqual(
            canvas.native.frame.minX, timeline.native.frame.minX, accuracy: 0.5, "放大后的日期列应与视口左界限对齐。"
        )
        timeline.swipeUp()
        timeline.swipeDown()
        timeline.pinch(withScale: 0.8, velocity: -1)
        assertUI(timeline.value as? String != enlarged, "双指收拢应缩小时间轴。")
        XCTAssertEqual(
            canvas.native.frame.minX, timeline.native.frame.minX, accuracy: 0.5, "缩小后的日期列应与视口左界限对齐。"
        )
        assertUI(timeline.isHittable, "缩放和滚动后时间轴应可交互。")
        XCTAssertEqual(
            UITestControlClient.request([
                "command": "record", "identifier": "fabricated", "type": "9",
                "instance": "fabricated", "action": "tap",
            ]), "unobserved", "访问记录应对应已捕获的控件。")
        guard let coverage = UITestControlClient.request(["command": "coverage"]),
            let inventory = try? JSONSerialization.jsonObject(with: Data(coverage.utf8))
                as? [String: Any],
            let visits = inventory["visitedControls"] as? [[String: Any]]
        else {
            XCTFail("时间轴应提供实际交互库存。")
            return
        }
        XCTAssertFalse((inventory["observedControls"] as? [String] ?? []).contains("fabricated"))
        let actions = Set(
            visits.filter { $0["identifier"] as? String == "schedule.linear.timeline" }
                .flatMap { $0["actions"] as? [String] ?? [] })
        XCTAssertTrue(actions.isSuperset(of: ["swipe", "pinch"]), "时间轴应分别保留滚动与捏合证据。")
    }

    @MainActor
    func testMapCampusLayerPanAndZoomPersist() throws {
        app = configureApp(resetStorage: true, initialTab: "map")
        let layer = app.buttons["切换地图图层"]
        assertUI(layer.appears(timeout: 5), "地图应提供图层入口。")
        func camera() throws -> [String: Any] {
            let snapshot = try XCTUnwrap(UITestControlClient.request(["command": "map-camera"]))
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any])
        }
        let original = try XCTUnwrap(try camera()["configuration"] as? String)
        layer.tapBriefly()
        let changed = try XCTUnwrap(try camera()["configuration"] as? String)
        assertUI(changed != original, "切换图层应改变原生地图配置。")
        checkBrowserActionBounds(["切换地图图层", "定位到我的位置", "切换到良乡校区", "切换到中关村校区", "切换到珠海校区"])
        var longitude = try XCTUnwrap(try camera()["longitude"] as? Double)
        for campus in ["中关村校区", "良乡校区", "珠海校区"] {
            revealBrowserAction("切换到\(campus)").tapBriefly()
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in
                        (try? camera()["longitude"] as? Double).map { $0 != longitude } == true
                    }, on: app), "校区切换应改变地图中心：\(campus)。")
            longitude = try XCTUnwrap(try camera()["longitude"] as? Double)
        }
        let map = app.maps.firstMatch
        assertUI(map.exists, "地图应暴露可交互的地图区域。")
        let initialCamera = try camera()
        XCTAssertEqual(initialCamera["scrollEnabled"] as? Bool, true, "原生地图应启用平移。")
        XCTAssertEqual(initialCamera["zoomEnabled"] as? Bool, true, "原生地图应启用缩放。")
        map.swipeLeft()
        let pannedCamera = try camera()
        XCTAssertNotEqual(
            try XCTUnwrap(pannedCamera["longitude"] as? Double),
            try XCTUnwrap(initialCamera["longitude"] as? Double), "向左滑动应改变地图中心经度。")
        map.pinch(withScale: 1.5, velocity: 1)
        let zoomedCamera = try camera()
        XCTAssertLessThan(
            try XCTUnwrap(zoomedCamera["distance"] as? Double),
            try XCTUnwrap(pannedCamera["distance"] as? Double), "双指展开应拉近地图相机距离。")
        layer.tapBriefly()
        XCTAssertEqual(try camera()["configuration"] as? String, original, "平移和缩放后图层操作应继续生效。")
        layer.tapBriefly()
        XCTAssertEqual(try camera()["configuration"] as? String, changed, "图层操作应恢复已选择的配置。")
        app = configureApp(resetStorage: false, initialTab: "map")
        let restored = try camera()
        assertUI(restored["configuration"] as? String == changed, "重新装载应保留图层设置。")
        XCTAssertEqual(
            try XCTUnwrap(restored["longitude"] as? Double),
            try XCTUnwrap(initialCamera["longitude"] as? Double), accuracy: 0.0001, "重新装载应保留校区。")
    }

    @MainActor
    func testCalendarSettingsPickersToggles() {
        app = configureApp(resetStorage: true, initialSettings: "calendar")
        tap("时间表")
        let editor = app.textViews.firstMatch
        replaceTextWithKeyboard("invalid", in: editor)
        dismissKeyboard()
        tap("确定")
        assertUI(app.alerts["设置失败"].appears(timeout: 5), "错误时间表应展示校验结果。")
        closeAlertIfPresent()
        replaceText("08:00,08:45\n09:00,09:45", in: editor)
        dismissKeyboard()
        tap("确定")
        tap("时间表")
        assertUI((editor.value as? String ?? "").contains("08:00"), "保存应恢复新时间表。")
        replaceText("10:00,10:45", in: editor)
        dismissKeyboard()
        tap("取消")
        tap("放弃输入")
        tap("时间表")
        assertUI((editor.value as? String ?? "").contains("08:00"), "取消应保留已保存时间表。")
        tap("取消")
        let cancelName = app.buttons["schedule.settings.primary-name"]
        reveal(cancelName)
        cancelName.tapBriefly()
        replaceText("取消的名称", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("取消")
        assertUI(!cancelName.label.contains("取消的名称"), "取消改名应保留课表名称。")
        choose("时间轴", option: "线性")
        choose("时间轴", option: "节次")
        choose("课程显示方式", option: "全学期叠加")
        choose("课程显示方式", option: "按周显示")
        for option in ["名称", "地点", "名称和地点"] {
            choose("显示内容", option: option)
        }
        let savedSwitches = Dictionary(
            uniqueKeysWithValues: ["显示周六", "显示周日", "显示考试安排"].map { ($0, toggle($0)) })
        let nameRow = app.buttons["schedule.settings.primary-name"]
        reveal(nameRow, description: "课表名称")
        nameRow.tapBriefly()
        let name = app.textFields["schedule.rename.name"]
        assertUI(name.appears(timeout: 5), "重命名应展示输入框。")
        replaceText("测试课表名称", in: name)
        tap("确定")
        assertUI(textElement("测试课表名称").appears(timeout: 5), "重命名应更新设置行。")
        app = configureApp(resetStorage: false)
        assertUI(app.segmentedControls.buttons["测试课表名称"].exists, "重新装载应保留课表名称。")
        openSettings("calendar")
        for title in ["显示周六", "显示周日", "显示考试安排"] {
            let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", title))
                .firstMatch
            reveal(control, description: title)
            assertUI(control.value as? String == savedSwitches[title], "重新装载应保留开关：\(title)")
        }
    }

    @MainActor
    func testCalendarOfflineTermFailureAndCancel() {
        app = configureApp(resetStorage: true, initialSettings: "calendar")
        tap("当前学期")
        assertUI(app.navigationBars["切换学期"].appears(timeout: 5), "当前学期应打开选择页。")
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "学校离线应展示学期加载失败。")
        closeAlertIfPresent()
        assertUI(app.staticTexts["学期列表尚未加载"].appears(timeout: 5), "失败后应展示学期列表的待加载状态。")
        assertUI(
            !app.descendants(matching: .activityIndicator).firstMatch.exists, "请求结束后应恢复空状态与重试入口。")
        tap("重新加载")
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "重试应重新执行学期请求并反馈连接结果。")
        closeAlertIfPresent()
        back()
        assertUI(app.buttons["schedule.settings.primary-name"].exists, "关闭失败提示并返回应恢复日程设置。")
    }

    @MainActor
    func testScheduleCopyImportRenameCycle() throws {
        app = configureApp(resetStorage: true, initialSettings: "calendar")
        defer { Self.endSharedSession() }
        tap("分享课表")
        assertUI(app.alerts["当前课表为空"].appears(timeout: 5), "空课表分享应先提示确认。")
        app.alerts["当前课表为空"].buttons["确定"].tapBriefly()
        tap("复制到剪贴板")
        assertUI(app.alerts["已复制"].appears(timeout: 5), "复制编码应展示成功提示。")
        app.alerts["已复制"].buttons["知道了"].tapBriefly()
        tap("取消")
        tap("导入课表")
        assertUI(app.alerts["导入分享课表提示"].appears(timeout: 5), "首次导入应展示说明。")
        app.alerts["导入分享课表提示"].buttons["知道了"].tapBriefly()
        tap("粘贴剪贴板")
        let code = app.textViews["schedule.import.code"]
        assertUI(!(code.value as? String ?? "").isEmpty, "粘贴应恢复刚导出的编码。")
        tap("导入")
        assertUI(app.alerts["导入成功"].appears(timeout: 5), "导入分享课表应展示成功结果。")
        closeAlertIfPresent()
        assertUI(code.disappears(timeout: 5), "导入完成应关闭编码页面并恢复课表设置。")
        let shared = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "schedule.settings.shared.")
        ).firstMatch
        reveal(shared, description: "分享课表名称")
        shared.tapBriefly()
        replaceText("测试分享课表", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("确定")
        assertUI(
            waitUntil(NSPredicate(format: "label CONTAINS %@", "测试分享课表"), on: shared, timeout: 5),
            "保存应更新分享课表名称。")
        back()
        app.mainTab("日程").tapBriefly()
        let sharedSegment = app.segmentedControls.buttons["测试分享课表"]
        assertUI(sharedSegment.appears(timeout: 5), "导入和改名应增加课表分栏。")
        app.swipeUp()
        assertUI(
            waitUntil(
                NSPredicate(format: "label == %@", "课表"),
                on: app.segmentedControls.buttons.element(boundBy: 0), timeout: 5),
            "向上滑动应从分享课表循环到主课表。")
        app.swipeDown()
        assertUI(
            waitUntil(
                NSPredicate(format: "label == %@", "测试分享课表"),
                on: app.segmentedControls.buttons.element(boundBy: 0), timeout: 5), "向下滑动应恢复分享课表。")
        let application = try XCTUnwrap(app.native as? XCUIApplication)
        application.launchEnvironment["BIT101_UI_TEST_RESET_STORAGE"] = "0"
        application.launchEnvironment["BIT101_UI_TEST_SETTINGS"] = nil
        checkScrollContainers()
        Self.captureControlInventory()
        application.open(try XCTUnwrap(URL(string: "bit101://schedule/courses")))
        UITestSnapshotReader.invalidate()
        assertUI(
            waitUntil(
                NSPredicate(format: "label == %@", "课表"),
                on: app.segmentedControls.buttons.element(boundBy: 0), timeout: 5),
            "自己的课表小组件应从分享分身返回主课表。")
        openSettings("calendar")
        reveal(shared, description: "分享课表名称")
        checkScrollContainers(force: true)
        shared.swipeLeft()
        let delete = app.buttons["删除"]
        assertUI(delete.native.waitForExistence(timeout: 5), "左滑应显示删除操作。")
        delete.tapBriefly()
        assertUI(shared.disappears(timeout: 5), "删除操作应移除分享课表。")
    }

    @MainActor
    func testDdlSettingsWheelSaveCancel() {
        app = configureApp(resetStorage: true)
        openSettings("ddl")
        tap("变色天数")
        let wheel = app.pickerWheels.firstMatch
        assertUI(wheel.appears(timeout: 5), "变色天数应使用滚轮选择。")
        wheel.adjust(toPickerWheelValue: "7 天")
        tap("完成")
        assertUI(wheel.disappears(timeout: 5), "保存变色天数应收起滚轮。")
        tap("滞留天数")
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "10 天")
        tap("取消")
        assertUI(wheel.disappears(timeout: 5), "取消滞留天数应收起滚轮。")
        tap("滞留天数")
        assertUI(app.pickerWheels.firstMatch.value as? String != "10 天", "取消应保留原值。")
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "5 天")
        tap("完成")
        assertUI(wheel.disappears(timeout: 5), "保存滞留天数应收起滚轮。")
        app = configureApp(resetStorage: false, initialSettings: "ddl")
        tap("变色天数")
        assertUI(app.pickerWheels.firstMatch.value as? String == "7 天", "重新装载应保留变色天数。")
        tap("取消")
        assertUI(wheel.disappears(timeout: 5), "取消变色天数应收起滚轮。")
        tap("滞留天数")
        assertUI(app.pickerWheels.firstMatch.value as? String == "5 天", "重新装载应保留滞留天数。")
        tap("取消")
    }

}
