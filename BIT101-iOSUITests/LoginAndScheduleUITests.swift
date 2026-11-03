import CoreGraphics
import Network
import UIKit
import XCTest
import os

nonisolated final class ScheduleLayoutUITests: UIAutomationTestCase {
    @MainActor
    func testSideToolbarUsesSpaceAboveNavigation() throws {
        app = configureApp(resetStorage: true, content: true, school: true, initialTab: "map")
        try XCTSkipIf(
            !windowUsesSideToolbar,
            "侧栏工具验收使用带侧方系统安全区的竖屏窗口。")
        checkSideToolbar(["切换地图图层", "定位到我的位置", "切换到良乡校区", "切换到中关村校区", "切换到珠海校区"])
        if app.native.buttons["导航到下一节课"].exists { checkSideToolbar(["导航到下一节课"]) }
        captureBrowserScreenshot("地图侧栏工具")
        app.mainTab("话廊").tapBriefly()
        checkSideToolbar(["我的收藏", "消息", "发布话题", "搜索话廊"])
        captureBrowserScreenshot("话题侧栏工具")
        app.native.segmentedControls.buttons["文章"].press(forDuration: 0.01)
        checkSideToolbar(["发布文章", "搜索文章"])
        captureBrowserScreenshot("文章侧栏工具")
        app.mainTab("日程").tapBriefly()
        checkSideToolbar(["添加课表内容"])
        checkScheduleGeometry()
        tapHeader(app.sectionTab("DDL"))
        checkSideToolbar(["添加待办"])
        captureBrowserScreenshot("日程侧栏工具")
    }
    @MainActor
    func testWeeklyHeaderKeepsItsCompactDateRow() {
        app = configureApp(resetStorage: true, animations: true, school: true)
        let date = app.native.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "第1周，周一，")
        ).firstMatch
        assertUI(
            waitUntil(
                NSPredicate { _, _ in date.exists && abs(date.frame.height - 26) <= 0.5 }, on: app),
            "周次日期行应保留原来的 26 点高度：\(date.frame)。")
        let week = app.native.buttons["第1周"]
        assertUI(
            week.exists && abs(week.frame.height - 44) <= 0.5 && week.isHittable,
            "默认字号的周次刻度应保留紧凑的 44 点点击区域：\(week.frame)。")
        checkScheduleGeometry()
        app.mainTab("地图").tapBriefly()
        app.mainTab("日程").tapBriefly()
        checkScheduleGeometry()
    }

    @MainActor
    func testDeadlineWidgetLinkOpensTheDDLSection() throws {
        app = configureApp(resetStorage: true, ddlFixture: "sources")
        defer { Self.endSharedSession() }
        let application = try XCTUnwrap(app.native as? XCUIApplication)
        application.open(try XCTUnwrap(URL(string: "bit101://schedule/ddl")))
        UITestSnapshotReader.invalidate()
        assertUI(
            app.native.segmentedControls.buttons["DDL"].waitForExistence(timeout: 10),
            "小组件链接应打开日程页面。")
        assertUI(app.native.segmentedControls.buttons["DDL"].isSelected, "DDL 小组件链接应选中 DDL 分页。")
        assertUI(app.staticTexts["课程中心测试作业"].appears(timeout: 5), "小组件入口应展示当前账号的待办。")
        application.open(try XCTUnwrap(URL(string: "bit101://schedule/courses")))
        UITestSnapshotReader.invalidate()
        assertUI(app.native.segmentedControls.buttons["课表"].isSelected, "课表小组件链接应选中课表分页。")
    }

    @MainActor
    func testDeadlineWidgetAppearsInSystemGallery() throws {
        app = configureApp(resetStorage: true)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        defer {
            let hierarchy = XCTAttachment(string: springboard.debugDescription)
            hierarchy.name = "失败时的界面元素树：小组件系统元素树"
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: springboard.screenshot())
            screenshot.name = "界面截图：小组件系统预览"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCUIDevice.shared.press(.home)
            app.activate()
        }
        XCUIDevice.shared.press(.home)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.82)).press(
            forDuration: 2)
        let edit = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Edit", "编辑"]))
            .firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let addWidget = springboard.buttons.matching(
            NSPredicate(format: "label IN %@", ["Add Widget", "添加小组件"])
        ).firstMatch
        XCTAssertTrue(addWidget.waitForExistence(timeout: 5))
        addWidget.tap()
        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("BIT101")
        let result = springboard.cells["BIT101"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let preview = springboard.buttons["BIT101, DDL"].firstMatch
        for _ in 0..<6 {
            if preview.exists && preview.isHittable { break }
            springboard.swipeLeft()
        }
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "系统小组件库应展示 DDL 的真实扩展预览。")
        var sizes: [CGSize] = []
        for index in 0..<3 {
            XCTAssertTrue(
                preview.isHittable && !preview.frame.isEmpty
                    && springboard.frame.contains(preview.frame), "DDL 应完整显示在当前尺寸预览中。")
            sizes.append(preview.frame.size)
            let screenshot = XCTAttachment(screenshot: springboard.screenshot())
            screenshot.name = "界面截图：DDL 系统预览"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            if index < 2 { springboard.swipeLeft() }
        }
        XCTAssertGreaterThan(sizes[1].width, sizes[0].width)
        XCTAssertGreaterThan(sizes[2].height, sizes[1].height)
    }

    @MainActor
    private func assertNativeControlParity(_ element: UIElement) throws {
        XCTAssertTrue(element.appears(timeout: 5), "滚动恢复后应完成当前控件的无障碍挂载。")
        let actual = try XCTUnwrap(element.attributes(), "渲染查询应提供当前控件状态。")
        let expected = try element.native.snapshot()
        XCTAssertEqual(actual["identifier"] as? String, expected.identifier)
        XCTAssertEqual(actual["label"] as? String, expected.label)
        XCTAssertEqual(actual["elementType"] as? Int, Int(expected.elementType.rawValue))
        XCTAssertEqual(actual["enabled"] as? Bool, expected.isEnabled)
        XCTAssertEqual(element.isHittable, element.native.isHittable)
        let frame = try XCTUnwrap(actual["frame"] as? [Double])
        for (value, reference) in zip(
            frame,
            [expected.frame.minX, expected.frame.minY, expected.frame.width, expected.frame.height])
        {
            XCTAssertEqual(value, Double(reference), accuracy: 0.5)
        }
    }

    @MainActor
    func testRefreshStatusRowsUseConsistentGeometry() throws {
        XCUIDevice.shared.orientation = .portrait
        for largeText in [false, true] {
            app = configureApp(
                resetStorage: !largeText, restartProcess: largeText,
                accessibilityTextSize: largeText, content: true, school: true)
            var samples: [(page: String, cell: CGRect, text: CGRect, action: CGRect)] = []
            for page in ["课表", "DDL", "空教室", "成绩"] {
                if page == "成绩" {
                    app.mainTab(page).native.tap()
                } else {
                    app.native.segmentedControls.buttons[page].tap()
                }
                UITestSnapshotReader.invalidate()
                let container =
                    switch page {
                    case "课表":
                        UIElement(
                            app.native.collectionViews.containing(
                                .other, identifier: "schedule.refresh-status"
                            ).firstMatch)
                    case "DDL":
                        app.descendants(matching: .any)["interaction.DDLScheduleTabView.list"]
                    case "空教室": app.descendants(matching: .any)["schedule.section-surface"]
                    default: app.descendants(matching: .any)["browser.master"]
                    }
                let actionID = page == "成绩" ? "score.query" : "app.refresh-status.action"
                let action = container.native.buttons[actionID]
                let timestamp = container.native.staticTexts["app.refresh-status.timestamp"]
                    .firstMatch
                let cell = container.native.cells.containing(.button, identifier: actionID)
                    .firstMatch
                assertUI(
                    timestamp.waitForExistence(timeout: 5) && cell.exists,
                    "\(page)应呈现更新时间行。")
                assertUI(
                    waitUntil(
                        NSPredicate(format: "enabled == true"), on: container.buttons[actionID],
                        timeout: 5),
                    "\(page)刷新完成后应开放操作。")
                for element in [
                    container.buttons[actionID],
                    container.staticTexts["app.refresh-status.timestamp"],
                ] { try assertNativeControlParity(element) }
                let frames = (
                    page: page, cell: cell.frame, text: timestamp.frame, action: action.frame
                )
                samples.append(frames)
                assertUI(
                    frames.cell.height >= max(44, frames.text.height, frames.action.height) + 7,
                    "\(page)行高应容纳点击区域、当前字体和上下边距。")
                assertUI(
                    frames.cell.insetBy(dx: 0, dy: 4).contains(frames.text),
                    "\(page)更新时间文字应完整落在行内容区域。")
            }
            guard
                let buttonAllowance = samples.map({ max(0, $0.cell.height - 8 - $0.action.height) })
                    .min()
            else {
                XCTFail("四个数据页应提供布局样本。")
                return
            }
            for sample in samples {
                let expectedHeight =
                    largeText
                    ? max(44, sample.text.height, sample.action.height + buttonAllowance) + 8 : 52
                XCTAssertEqual(
                    sample.cell.height, expectedHeight, accuracy: 1,
                    """
                    \(sample.page)更新时间行应由文字、操作区和行边距决定高度：行 \(sample.cell)，文字 \(sample.text)，操作 \
                    \(sample.action)，大字体 \(largeText)。
                    """
                )
            }
        }
    }

    @MainActor
    func testRecurringSchedulesUseDisplayedWeek() {
        app = configureApp(resetStorage: true)
        let calendar = app.native.cells.containing(.button, identifier: "schedule.add-content")
            .firstMatch
        assertUI(calendar.appears(timeout: 5), "课表应完成布局。")
        checkScheduleGeometry()
        tap("下一周")
        tap("下一周")
        assertSelectedWeek(3)
        app.buttons["schedule.add-content"].tapBriefly()
        tap("添加课程")
        app.buttons["schedule.course.weeks"].tapBriefly()
        XCTAssertEqual(app.buttons["第3周"].value as? String, "已选择")
        tap("完成")
        tap("取消")
        app.buttons["schedule.add-content"].tapBriefly()
        tap("添加日程")
        replaceText("每周活动", in: app.textFields["schedule.custom.title"])
        dismissKeyboard()
        app.buttons["schedule.custom.weeks"].tapBriefly()
        XCTAssertEqual(app.buttons["第3周"].value as? String, "已选择")
        tap("第4周")
        tap("完成")
        tap("确定")
        let activity = app.buttons["自定义日程，每周活动"]
        assertUI(activity.appears(timeout: 5), "添加后应显示当前周活动。")
        tap("下一周")
        assertUI(activity.appears(timeout: 5), "下一周应显示相同活动。")
        activity.tapBriefly()
        tap("编辑")
        app.buttons["schedule.custom.weeks"].tapBriefly()
        XCTAssertEqual(app.buttons["第3周"].value as? String, "已选择")
        XCTAssertEqual(app.buttons["第4周"].value as? String, "已选择")
        tap("第3周")
        tap("第5周")
        tap("完成")
        tap("确定")
        tap("上一周")
        assertUI(activity.disappears(timeout: 5), "移出的周次应清除活动。")
        app = configureApp(resetStorage: false, restartProcess: true)
        tap("第5周")
        assertUI(activity.appears(timeout: 5), "重新打开应保留多周日程。")
        activity.tapBriefly()
        tap("删除")
        assertUI(activity.disappears(timeout: 5), "删除应移除整组日程。")
        tap("上一周")
        assertUI(activity.disappears(timeout: 5), "其余周次应同步移除。")
    }

    @MainActor
    func testAccessibilityQueryParity() throws {
        app = configureApp(resetStorage: true, account: nil, nativeInteraction: false)
        XCTAssertEqual(app.frame, app.native.frame)
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "ui-test.scene").firstMatch.value
                as? String,
            app.native.descendants(matching: .any).matching(identifier: "ui-test.scene").firstMatch
                .value as? String)
        for element in [
            app.textFields["login.student-id"], app.secureTextFields["login.password"],
            app.buttons["login.submit"],
        ] {
            try assertNativeControlParity(element)
        }
        let submit = app.buttons["login.submit"]
        func checkedDisabledControls() throws -> [String] {
            let report = try XCTUnwrap(UITestControlClient.request(["command": "coverage"]))
            let value = try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any]
            return try XCTUnwrap(value?["checkedDisabledControls"] as? [String])
        }
        let previousChecks = try checkedDisabledControls()
        _ = submit.isEnabled
        XCTAssertEqual(try checkedDisabledControls(), previousChecks, "状态读取应保持独立的断言库存。")
        submit.assertDisabled("空凭据应禁用登录。")
        XCTAssertEqual(
            Set(try checkedDisabledControls()).subtracting(previousChecks).count, 1,
            "成功的禁用断言应登记当前控件。")
        XCTAssertTrue(
            ["native", "input focus missing"].contains(
                app.textFields["login.student-id"].insertText("待聚焦输入") ?? ""))
        XCTAssertEqual(app.textFields["login.student-id"].value as? String, "", "输入写入应由当前实际焦点承接。")
        replaceTextWithKeyboard("20230001", in: app.textFields["login.student-id"])
        XCTAssertEqual(app.textFields["login.student-id"].insertText("20230002"), "entered")
        XCTAssertEqual(app.textFields["login.student-id"].value as? String, "20230002")
        XCTAssertEqual(app.textFields["login.student-id"].insertText("20230001"), "entered")
        replaceTextWithKeyboard("fixture-password", in: app.secureTextFields["login.password"])
        dismissKeyboard()
        XCTAssertTrue(submit.isEnabled)
        XCTAssertEqual(
            UITestControlClient.request([
                "command": "occlusion", "identifier": "login.submit", "enabled": "1",
            ]), "covered")
        UITestSnapshotReader.invalidate()
        let cover = app.native.buttons["ui-test.occlusion"]
        assertUI(
            cover.waitForExistence(timeout: 5)
                && cover.frame.contains(CGPoint(x: submit.frame.midX, y: submit.frame.midY)),
            "遮挡层应覆盖登录按钮。")
        let query = try JSONSerialization.data(withJSONObject: [
            ["type": "9"], ["predicate": "identifier == 'login.submit'"], ["first": "1"],
        ])
        XCTAssertEqual(
            UITestControlClient.request([
                "command": "query-activate", "query": String(decoding: query, as: UTF8.self),
                "hittable": submit.isHittable ? "1" : "0",
            ]), "native")
        XCTAssertEqual(
            UITestControlClient.request(["command": "occlusion", "enabled": "0"]), "cleared")
        UITestSnapshotReader.invalidate()
        XCTAssertTrue(submit.isHittable)
        let studentID = app.textFields["login.student-id"]
        let previous = studentID.value as? String
        XCTAssertEqual(
            UITestControlClient.request([
                "command": "occlusion", "identifier": "login.student-id", "enabled": "1",
            ]), "covered")
        UITestSnapshotReader.invalidate()
        assertUI(
            cover.frame.contains(CGPoint(x: studentID.frame.midX, y: studentID.frame.midY)),
            "遮挡层应覆盖输入位置。")
        XCTAssertEqual(studentID.insertText("遮挡输入"), "native")
        XCTAssertEqual(studentID.value as? String, previous)
        XCTAssertEqual(
            UITestControlClient.request(["command": "occlusion", "enabled": "0"]), "cleared")
        UITestSnapshotReader.invalidate()
        let missing = app.buttons["ui-test.missing-control"]
        XCTAssertFalse(missing.exists)
        XCTAssertFalse(missing.native.exists)
        XCTAssertFalse(missing.isHittable)
        for element in [
            app.staticTexts.firstMatch,
            app.descendants(matching: .any).matching(identifier: "login.student-id").firstMatch,
        ] {
            let actual = try XCTUnwrap(element.attributes())
            let expected = try element.native.snapshot()
            XCTAssertEqual(actual["identifier"] as? String, expected.identifier)
            XCTAssertEqual(actual["label"] as? String, expected.label)
            XCTAssertEqual(actual["elementType"] as? Int, Int(expected.elementType.rawValue))
        }
        app = configureApp(resetStorage: true)
        app.buttons["下一周"].native.press(forDuration: 0.01)
        UITestSnapshotReader.invalidate()
        assertSelectedWeek(2)
        XCTAssertTrue(app.buttons["第2周"].native.isSelected)
        app.buttons["上一周"].tapBriefly()
        assertSelectedWeek(1)
        XCTAssertTrue(app.buttons["第1周"].native.isSelected)
        app.buttons["schedule.add-content"].native.press(forDuration: 0.01)
        UITestSnapshotReader.invalidate()
        app.native.buttons["添加日程"].firstMatch.press(forDuration: 0.01)
        UITestSnapshotReader.invalidate()
        let title = app.textFields["schedule.custom.title"]
        title.native.tap()
        UITestSnapshotReader.invalidate()
        replaceText("渲染查询输入", in: title)
        XCTAssertEqual(title.native.value as? String, "渲染查询输入")
        XCTAssertTrue(app.keyboards.firstMatch.native.exists)
        dismissKeyboard()
        XCTAssertTrue(app.keyboards.firstMatch.native.disappears(timeout: 5))
        replaceTextWithKeyboard("字段绑定输入", in: title)
        XCTAssertEqual(title.native.value as? String, "字段绑定输入")
        dismissKeyboard()
        XCTAssertTrue(app.keyboards.firstMatch.native.disappears(timeout: 5))
        app.buttons["取消"].native.press(forDuration: 0.01)
        UITestSnapshotReader.invalidate()
        XCTAssertTrue(app.buttons["schedule.add-content"].native.exists)
        app = configureApp(resetStorage: true, initialSettings: "gallery")
        let row = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "隐藏匿名内容"))
            .firstMatch
        let control = row.native.switches.firstMatch
        let initial = control.value as? String
        control.tap()
        UITestSnapshotReader.invalidate()
        XCTAssertNotEqual(control.value as? String, initial)
        _ = toggle("隐藏匿名内容")
        XCTAssertEqual(control.value as? String, initial)
        app = configureApp(resetStorage: false, initialSettings: "gallery")
        XCTAssertEqual(
            app.switches.matching(NSPredicate(format: "label CONTAINS %@", "隐藏匿名内容")).firstMatch
                .native.switches.firstMatch.value as? String, initial)
        app.navigationBars["话廊设置"].buttons.firstMatch.native.press(forDuration: 0.01)
        UITestSnapshotReader.invalidate()
        XCTAssertTrue(app.buttons["settings.route.gallery"].appears(timeout: 5))
        openSettings("gallery")
        back()
        XCTAssertTrue(app.buttons["settings.route.gallery"].appears(timeout: 5))
        app = configureApp(resetStorage: true, initialTab: "gallery")
        let alert = app.alerts["加载话廊失败"]
        XCTAssertTrue(alert.appears(timeout: 5))
        try assertNativeControlParity(alert.buttons["知道了"])
        alert.buttons["知道了"].native.press(forDuration: 0.01)
        UITestSnapshotReader.invalidate()
        XCTAssertTrue(alert.disappears(timeout: 5))
        XCTAssertFalse(alert.native.exists)
    }

    @MainActor
    func testScheduleKeepsWeek() {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        app = configureApp(resetStorage: true, school: true)
        let traits = windowTraits()
        let requiresPortrait =
            traits["idiom"] == UIUserInterfaceIdiom.phone.rawValue
            && (traits["horizontal"] != UIUserInterfaceSizeClass.regular.rawValue
                || traits["vertical"] != UIUserInterfaceSizeClass.regular.rawValue)
        let isTablet = traits["idiom"] == UIUserInterfaceIdiom.pad.rawValue
        defer { device.orientation = .portrait }
        assertWeekCentered(1)
        app.buttons["第3周"].tapBriefly()
        assertSelectedWeek(3)
        tap("schedule.add-content")
        tap("添加课程")
        let draft = app.textFields["课程名称"]
        replaceText("旋转保留课程草稿", in: draft)
        dismissKeyboard()
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            device.orientation = orientation
            UITestSnapshotReader.invalidate()
            assertUI(
                draft.appears(timeout: 5) && draft.value as? String == "旋转保留课程草稿",
                "旋转应保留课程编辑器及完整草稿。")
        }
        tap("取消")
        tap("放弃输入")
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait] {
            device.orientation = orientation
            UITestSnapshotReader.invalidate()
            let add = app.buttons["schedule.add-content"]
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in
                        UITestSnapshotReader.invalidate()
                        let window = self.app.native.windows.firstMatch.frame
                        let followsRotation =
                            !isTablet
                            || (orientation.isLandscape
                                ? window.width > window.height : window.height > window.width)
                        return followsRotation && add.native.exists && add.native.isHittable
                            && window.contains(add.native.frame)
                    }, on: app, timeout: 10), "窗口旋转后课表操作入口保持可触达。")
            if requiresPortrait {
                assertUI(
                    app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width,
                    "紧凑手机窗口应保持竖屏：\(windowTraits())。")
            }
            assertSelectedWeek(3)
            assertWeekCentered(3)
            let calendar = app.buttons["schedule.blank-context-menu"]
            assertUI(calendar.appears(timeout: 10), "窗口旋转后课表保持可见。")
            let window = app.windows.firstMatch.frame
            assertUI(
                calendar.frame.height > add.frame.height && window.intersects(calendar.frame),
                "窗口旋转后课表保留可用的内容区域。")
            for title in ["日程", "地图", "成绩", "话廊", "我的"] {
                let tab = app.mainTab(title)
                assertUI(tab.exists && tab.native.isHittable, "窗口旋转后主导航保持可触达：\(title)。")
            }
        }
    }

    @MainActor
    private func assertWeekCentered(_ week: Int) {
        let item = app.native.buttons["第\(week)周"]
        let viewport = app.native.scrollViews["interaction.ScheduleInlineWeekSlider.scroll"]
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    item.exists && viewport.exists && viewport.frame.width > 0
                        && abs(item.frame.midX - viewport.frame.midX) <= 1
                }, on: app, timeout: 5), "首屏及旋转后选中周应与滚动视口居中对齐。")
    }

}
