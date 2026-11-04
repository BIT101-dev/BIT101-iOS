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

nonisolated final class ScheduleEditingUITests: UIAutomationTestCase {
    @MainActor
    func testScheduleEditorsProtectChangedInput() {
        for (isDDL, title, input) in [
            (false, "添加自定义日程", "schedule.custom.title"), (true, "添加 DDL", "ddl.editor.title"),
        ] {
            app = configureApp(resetStorage: true)
            if isDDL {
                tapHeader(app.segmentedControls.buttons["DDL"])
                tap("添加待办")
            } else {
                tap("schedule.add-content")
                tap("添加日程")
            }
            replaceText("待保留的编辑内容", in: app.textFields[input])
            dismissKeyboard()
            swipeSheetHeader(app.navigationBars[title])
            assertUI(app.textFields[input].value as? String == "待保留的编辑内容", "下滑应保留日程编辑内容。")
            tap("取消")
            tap("继续编辑")
            assertUI(app.textFields[input].value as? String == "待保留的编辑内容", "继续编辑应保持原有输入。")
            tap("取消")
            tap("放弃输入")
            assertUI(app.navigationBars[title].disappears(timeout: 5), "确认放弃应关闭当前编辑页。")
        }
    }

    @MainActor
    func testCourseStartSectionKeepsItsEndValid() {
        app = configureApp(resetStorage: true)
        tap("schedule.add-content")
        tap("添加课程")
        replaceText("节次联动课程", in: app.textFields["课程名称"])
        dismissKeyboard()
        tap("开始节次")
        tap("第5节")
        swipeSheetHeader(app.navigationBars["添加课程"])
        assertUI(app.textFields["课程名称"].value as? String == "节次联动课程", "课程编辑应保留已修改的节次与名称。")
        tap("取消")
        tap("继续编辑")
        tap("确定")
        assertUI(textElement("节次联动课程").appears(timeout: 5), "提高开始节次后应通过课程范围校验并保存。")
    }

    @MainActor
    func testCourseEditorFieldsPickersSaveDetail() {
        app = configureApp(resetStorage: true)
        app.buttons["schedule.add-content"].tapBriefly()
        tap("添加课程")
        for (title, value) in [("课程名称", "测试补录课程"), ("教师", "测试教师"), ("教室", "线上")] {
            let field = app.textFields[title]
            assertUI(field.exists, "课程编辑应支持字段：\(title)")
            replaceText(value, in: field)
        }
        dismissKeyboard()
        app.buttons["schedule.course.weeks"].tapBriefly()
        XCTAssertEqual(app.buttons["第1周"].value as? String, "已选择")
        tap("第3周")
        tap("完成")
        choose("星期", option: "周2")
        tap("开始节次")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1节")).firstMatch
            .tapBriefly()
        tap("结束节次")
        tap("第2节")
        tap("确定")
        let course = textElement("测试补录课程")
        assertUI(course.appears(timeout: 5), "补录课程应显示在课表。")
        tap("下一周")
        assertUI(course.disappears(timeout: 5), "单周课程应跳过第2周。")
        tap("下一周")
        assertUI(course.appears(timeout: 5), "单周课程应显示在第3周。")
        tap("第1周")
        assertUI(course.appears(timeout: 5), "返回第1周应恢复课程。")
        app.mainTab("地图").tapBriefly()
        app.buttons["切换到珠海校区"].tapBriefly()
        app = configureApp(resetStorage: false, restartProcess: true)
        assertUI(textElement("测试补录课程").appears(timeout: 5), "重启应先恢复含线上课程的课表。")
        app.mainTab("地图").tapBriefly()
        assertUI(app.buttons["切换到珠海校区"].appears(timeout: 5), "地图应恢复已选校区。")
        let camera = UITestControlClient.request(["command": "map-camera"])
            .flatMap { $0.data(using: .utf8) }.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        XCTAssertEqual(
            camera?["latitude"] as? Double ?? 0, 22.359413, accuracy: 0.01,
            "下一节课校区未知时，相机应与持久化的珠海选中状态一致。")
        app.mainTab("日程").tapBriefly()
        let restoredCourse = textElement("测试补录课程")
        assertUI(restoredCourse.appears(timeout: 5), "返回日程应恢复补录课程。")
        restoredCourse.tapBriefly()
        tap("调这门课")
        assertUI(app.navigationBars["调这门课"].appears(timeout: 5), "调课应打开安排编辑器。")
        assertUI(app.textFields["地点"].exists, "教学楼目录尚待加载时应保留完整地点编辑。")
        tap("取消")
        assertUI(app.navigationBars["调这门课"].disappears(timeout: 5), "取消应关闭调课编辑器。")
        app.buttons["删除这门课"].press(forDuration: 0.01)
        app.alerts.buttons["取消"].tapBriefly()
        assertUI(app.buttons["删除这门课"].exists, "取消删除应保留课程详情。")
        app.buttons["删除这门课"].press(forDuration: 0.01)
        app.alerts.buttons["删除"].tapBriefly()
        assertUI(restoredCourse.disappears(timeout: 5), "确认删除应移除课程。")
        app.buttons["schedule.add-content"].tapBriefly()
        tap("添加课程")
        tap("取消")
        assertUI(app.buttons["schedule.add-content"].exists, "取消课程编辑应返回课表。")
    }

    @MainActor
    func testImportInvalidCodeReportsError() {
        app = configureApp(resetStorage: true)
        let area = app.descendants(matching: .any).matching(
            identifier: "schedule.blank-context-menu"
        ).firstMatch
        area.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        tap("导入课表")
        let code = app.textViews["schedule.import.code"]
        assertUI(code.appears(timeout: 5), "导入应打开编码编辑器。")
        code.tapBriefly()
        code.typeText("invalid-code")
        dismissKeyboard()
        tap("导入")
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "无效编码应给出校验结果。")
        closeAlertIfPresent()
        assertUI(code.value as? String == "invalid-code", "校验失败应保留输入以供修改。")
        tap("取消")
    }

    @MainActor
    func testSchoolDdlSources() throws {
        app = configureApp(resetStorage: true, ddlFixture: "sources")
        let ddl = app.segmentedControls.buttons["DDL"]
        assertUI(ddl.appears(timeout: 10), "日程页应展示 DDL 分页。")
        ddl.tapBriefly()
        let eclass = app.staticTexts["课程中心测试作业"]
        assertUI(eclass.appears(timeout: 5), "DDL 页应展示课程中心作业。")
        let ddlCell = app.native.cells.containing(.staticText, identifier: "课程中心测试作业").firstMatch
        let leadingInset = try renderedLeadingTextInset(eclass.native, in: ddlCell)
        let refreshText = app.native.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "更新时间")
        ).firstMatch
        let refreshCell = app.native.cells.containing(.staticText, identifier: refreshText.label)
            .firstMatch
        XCTAssertEqual(
            leadingInset, try renderedLeadingTextInset(refreshText, in: refreshCell), accuracy: 1,
            "DDL 卡片与普通列表应沿用相同的系统默认行边距。")
        assertUI(app.staticTexts["乐学测试日程"].exists, "DDL 页应展示乐学日程。")
        XCTAssertEqual(
            app.staticTexts["ddl.preview.lexue-ui"].label, "测试课程\n测试说明\n补充说明",
            "列表预览应按有效文本行排列课程名和作业说明。")
        let course = app.native.staticTexts["ddl.preview.eclass:23"].firstMatch
        for id in ["eclass:23", "lexue-ui"] {
            let date = app.native.staticTexts["ddl.due.\(id)"].firstMatch
            let source = app.native.staticTexts["ddl.source.\(id)"].firstMatch
            XCTAssertEqual(date.frame.minY, source.frame.minY, accuracy: 0.5, "日期和来源应沿同一行展示。")
            XCTAssertEqual(date.frame.height, course.frame.height, accuracy: 0.5, "日期应与课程名共用字号。")
            XCTAssertEqual(source.frame.height, course.frame.height, accuracy: 0.5, "来源应与课程名共用字号。")
        }
        let cards = ["课程中心测试作业", "乐学测试日程"].map {
            app.native.cells.containing(.staticText, identifier: $0).firstMatch.frame
        }.sorted { $0.minY < $1.minY }
        XCTAssertGreaterThan(
            cards[1].minY, cards[0].maxY,
            "每条 DDL 应沿独立卡片展示，卡片之间保留页面底色间距。")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "界面截图"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let completion = app.buttons["ddl.done.eclass:23"]
        assertUI(completion.exists, "课程中心作业应提供完成状态操作。")
        completion.tapBriefly()
        assertUI(completion.value as? String == "已完成", "点击后应保存完成状态。")
        assertUI(
            (UITestControlClient.request(["command": "consume-opened-url"]) ?? "").isEmpty,
            "完成按钮应独立修改待办状态。")
        eclass.tapBriefly()
        assertOpenedURL("https://zy-eclass.bit.edu.cn/course/42/learning-activity/full-screen#/23")
        let lexue = app.descendants(matching: .any)["ddl.event.lexue-ui"]
        assertUI(lexue.performAccessibilityAction(named: "在浏览器打开"), "学校日程应提供打开浏览器的 VoiceOver 动作。")
        assertOpenedURL("https://lexue.bit.edu.cn/calendar/view.php?view=day&time=")
        app = configureApp(resetStorage: false, restartProcess: true)
        tapHeader(app.segmentedControls.buttons["DDL"])
        let restored = app.buttons["ddl.done.eclass:23"]
        assertUI(restored.appears(timeout: 5), "重新启动后应恢复课程中心作业。")
        assertUI(restored.value as? String == "已完成", "重新启动后应恢复完成状态。")
    }

    @MainActor
    func testDdlEmptyStateExplainsRetentionWindow() throws {
        app = configureApp(resetStorage: true, ddlFixture: "overdue")
        tapHeader(app.segmentedControls.buttons["DDL"])
        let explanation = app.staticTexts["1 条日程已超出显示范围。当前滞留天数为 0 天，可在 DDL 设置调整。"]
        assertUI(explanation.appears(timeout: 5), "过期日程的空列表应说明当前显示范围。")
    }

    @MainActor
    func testLongPressOpensScheduleContextMenu() throws {
        app = configureApp(resetStorage: true)

        let contextArea = app.descendants(matching: .any)
            .matching(identifier: "schedule.blank-context-menu")
            .firstMatch
        assertUI(contextArea.appears(timeout: 10), "日程页面应展示可操作的空白课表区域。")
        contextArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 1)

        let shareAction = app.buttons["分享课表"]
        let importAction = app.buttons["导入课表"]
        assertUI(
            shareAction.appears(timeout: 5),
            """
            长按课表区域后应展示分享操作。\
            \(focusedAccessibilitySnapshot(app, matching: ["分享", "导入", "课表", "menu"]))
            """
        )
        assertUI(importAction.exists, "长按课表区域后应展示导入操作。")

        importAction.tapBriefly()
        assertUI(app.navigationBars["导入课表"].appears(timeout: 5), "点按导入后应打开导入课表面板。")
        assertUI(app.textViews["schedule.import.code"].exists, "导入面板应展示课表编码编辑区。")
    }

    @MainActor
    func testCustomSchedulesAreIsolatedAccounts() throws {
        app = configureApp(resetStorage: true, account: "ui-test-account-a", content: true)
        addCustomSchedule("A 账户专属日程", in: app)

        app.mainTab("我的").tapBriefly()
        let accountRoute = app.buttons["settings.route.account"]
        assertUI(accountRoute.appears(timeout: 10), "我的页面应展示账号设置入口。")
        accountRoute.tapBriefly()

        let logout = app.buttons["settings.account.logout"]
        assertUI(logout.appears(timeout: 5), "账号设置应展示退出操作。")
        logout.tapBriefly()

        let studentID = app.textFields["login.student-id"]
        assertUI(studentID.appears(timeout: 10), "退出后应返回登录表单。")
        assertUI(studentID.value as? String == "ui-test-account-a", "退出后表单应保留账号 A。")
        signIn(app, studentID: "ui-test-account-b")
        let accountASchedule = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "自定义日程，A 账户专属日程"))
            .firstMatch
        assertUI(!accountASchedule.exists, "账号 B 的课表应隔离账号 A 的日程。")
    }

    @MainActor
    func testMainTabsRemainType() throws {
        for style in ["Light", "Dark"] {
            app = configureApp(
                resetStorage: true,
                accessibilityTextSize: true,
                userInterfaceStyle: style
            )
            assertMainTabsRemainAccessible(style: style)
        }
    }

}

@MainActor
extension XCUIElement {

    func appears(timeout: TimeInterval) -> Bool {
        waitForPresence(true, timeout: timeout)
    }

    func disappears(timeout: TimeInterval) -> Bool {
        waitForPresence(false, timeout: timeout)
    }

    @MainActor
    private func waitForPresence(_ presence: Bool, timeout: TimeInterval) -> Bool {
        if exists == presence { return true }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            UITestSnapshotReader.poll()
            if exists == presence { return true }
        } while Date() < deadline
        return false
    }
}

nonisolated final class AuthenticationLifecycleUITests: UIAutomationTestCase {
    @MainActor
    @objc func testLeavingRegistrationCancelsActivation() {
        app = configureApp(resetStorage: true, account: nil)
        app.buttons["login.register"].tapBriefly()
        replaceTextWithKeyboard("1120260001", in: app.textFields["registration.student-id"])
        replaceTextWithKeyboard(
            "community-password", in: app.secureTextFields["registration.password"])
        replaceTextWithKeyboard(
            "community-password", in: app.secureTextFields["registration.confirmation"])
        replaceTextWithKeyboard(
            "school-password", in: app.secureTextFields["registration.school-password"])
        dismissKeyboard()
        let verify = app.buttons["registration.verify"]
        reveal(verify)
        verify.tapBriefly()
        reveal(app.buttons["registration.submit"])
        _ = UITestControlClient.request(["command": "hold-request", "key": "registration-submit"])
        app.buttons["registration.submit"].tapBriefly()
        waitForRequest("registration-submit")
        back()
        releaseRequest("registration-submit")
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    UITestControlClient.request([
                        "command": "request-state", "key": "registration-submit",
                    ]) == "completed"
                }, on: app), "已退出注册页面的响应应完成取消处理。")
        assertUI(app.textFields["login.student-id"].exists, "注册页面退出后应保留登录表单。")
        assertUI(!app.mainTab("日程").exists, "已退出的注册提交应结束自身的登录激活。")
    }
}
