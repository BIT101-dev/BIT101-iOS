import CoreGraphics
import Network
import UIKit
import XCTest
import os

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

nonisolated final class ScheduleLayoutUITests: UIAutomationTestCase {
    @MainActor
    func testSideToolbarUsesSpaceAboveNavigation() throws {
        app = configureApp(resetStorage: true, content: true, school: true, initialTab: "map")
        if !windowUsesSideToolbar {
            assertUI(app.buttons["切换地图图层"].appears(timeout: 5), "地图工具应完整展示。")
            return
        }
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
        checkScrollContainers()
        Self.captureControlInventory()
        application.open(try XCTUnwrap(URL(string: "bit101://schedule/ddl")))
        UITestSnapshotReader.invalidate()
        assertUI(
            app.native.segmentedControls.buttons["DDL"].waitForExistence(timeout: 10),
            "小组件链接应打开日程页面。")
        assertUI(app.native.segmentedControls.buttons["DDL"].isSelected, "DDL 小组件链接应选中 DDL 分页。")
        assertUI(app.staticTexts["课程中心测试作业"].appears(timeout: 5), "小组件入口应展示当前账号的待办。")
        checkScrollContainers()
        Self.captureControlInventory()
        application.open(try XCTUnwrap(URL(string: "bit101://schedule/courses")))
        UITestSnapshotReader.invalidate()
        assertUI(app.native.segmentedControls.buttons["课表"].isSelected, "课表小组件链接应选中课表分页。")
    }

    @MainActor
    func testDeadlineWidgetAppearsInSystemGallery() throws {
        app = configureApp(resetStorage: true)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        defer {
            app.activate()
            _ = waitUntil(NSPredicate { _, _ in self.app.state == .runningForeground }, on: app)
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
        XCTAssertEqual(actual["selected"] as? Bool, expected.isSelected)
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
        app.buttons["ui-test.occlusion"].tapBriefly()
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
        let slider = app.descendants(matching: .any)["interaction.ScheduleInlineWeekSlider.scroll"]
        let selected = try slider.selectedButtonIdentities().map { $0.0 + "\n" + $0.1 }.sorted()
        let expectedSelected = try slider.native.snapshot().snapshots(matching: .button)
            .filter(\.isSelected).map { $0.identifier + "\n" + $0.label }.sorted()
        XCTAssertFalse(expectedSelected.isEmpty)
        XCTAssertEqual(selected, expectedSelected)
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
        app = configureApp(resetStorage: true, school: true)
        let traits = windowTraits()
        let requiresPortrait =
            traits["idiom"] == UIUserInterfaceIdiom.phone.rawValue
            && (traits["horizontal"] != UIUserInterfaceSizeClass.regular.rawValue
                || traits["vertical"] != UIUserInterfaceSizeClass.regular.rawValue)
        let isTablet = traits["idiom"] == UIUserInterfaceIdiom.pad.rawValue
        defer { device.orient(to: .portrait) }
        assertWeekCentered(1)
        app.buttons["第3周"].tapBriefly()
        assertSelectedWeek(3)
        tap("schedule.add-content")
        tap("添加课程")
        let draft = app.textFields["课程名称"]
        replaceText("旋转保留课程草稿", in: draft)
        dismissKeyboard()
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            device.orient(to: orientation)
            UITestSnapshotReader.invalidate()
            assertUI(
                draft.appears(timeout: 5) && draft.value as? String == "旋转保留课程草稿",
                "旋转应保留课程编辑器及完整草稿。")
        }
        tap("取消")
        tap("放弃输入")
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait] {
            device.orient(to: orientation)
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
