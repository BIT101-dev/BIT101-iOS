import CoreGraphics
import XCTest

nonisolated final class ScheduleNavigationUITests: UIAutomationTestCase {
    @MainActor
    @objc func testHolidayAndTransferConfirmedMutations() {
        app = configureApp(resetStorage: true, school: true)
        let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1周，周一，"))
            .firstMatch
        day.tapBriefly()
        tapHeader(app.segmentedControls.buttons["放假"])
        tap("确定")
        app.alerts["确认放假"].buttons["确定"].tapBriefly()
        assertUI(!app.buttons["学校测试课程"].exists, "确认放假应移除当日课程。")
        tap("第2周")
        assertUI(app.buttons["学校测试课程"].exists, "放假应保留其它周次课程。")
        let nextDay = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第2周，周一，"))
            .firstMatch
        nextDay.tapBriefly()
        tapHeader(app.segmentedControls.buttons["调至某天"])
        let target = app.datePickers["schedule.adjustment.date"]
        target.buttons.firstMatch.tapBriefly()
        _ = UITestControlClient.request([
            "command": "callback", "identifier": "schedule.adjustment.date",
            "action": "selection",
        ])
        selectSystemCalendarDate(
            Date(),
            in: app.datePickers.matching(NSPredicate(format: "identifier == %@", "")).firstMatch)
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .tapBriefly()
        tap("确定")
        app.alerts["确认调课"].buttons["确定"].tapBriefly()
        assertUI(app.buttons["schedule.add-content"].appears(timeout: 5), "确认调休应关闭调整窗口。")
        assertUI(!app.buttons["学校测试课程"].exists, "确认调休应移出原日期课程。")
        tap("第1周")
        assertUI(app.buttons["学校测试课程"].exists, "调休应在目标日期显示课程。")
    }

    @MainActor
    @objc func testScheduleWeekStripScroll() {
        app = configureApp(resetStorage: true, content: true, school: true)
        let week = app.buttons["第1周"]
        let start = week.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -100, dy: 0)),
            withVelocity: .fast, thenHoldForDuration: 0.1)
        assertUI(
            waitUntil(NSPredicate(format: "selected == false"), on: week, timeout: 5),
            "滑动周次栏应更新选择周。")
        tap("上一周")
        tap("第1周")
        let course = app.buttons["学校测试课程"]
        course.tapBriefly()
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "点按课程应打开课程详情。")
        tap("取消")
        course.press(forDuration: 1)
        tap("分享课程")
        dismissShareSheet()
        let area = app.descendants(matching: .any).matching(
            identifier: "schedule.blank-context-menu"
        ).firstMatch
        area.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).press(forDuration: 1)
        tap("分享课表")
        assertUI(app.navigationBars["分享课表"].appears(timeout: 5), "长按分享应打开学校课表编码。")
        app.buttons["schedule.export.share"].tapBriefly()
        dismissShareSheet()
        tap("取消")
    }

    @MainActor
    @objc func testCourseHistoryChartSelection() {
        app = configureApp(resetStorage: true, content: true, initialTab: "home")
        app.descendants(matching: .any)["home.score-surface"].swipeLeft()
        assertUI(app.segmentedControls.buttons["课程"].isSelected, "成绩页横滑应切换课程分区。")
        app.descendants(matching: .any)["home.course-surface"].swipeRight()
        assertUI(app.segmentedControls.buttons["成绩"].isSelected, "反向横滑应恢复成绩分区。")
        tapHeader(app.segmentedControls.buttons["课程"])
        tap("自动化测试课程")
        let chart = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "历史成绩图")
        ).firstMatch
        reveal(chart)
        let left = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
        let right = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4))
        right.press(
            forDuration: 0.6, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0.1)
        assertUI(
            waitUntil(
                NSPredicate(format: "value CONTAINS %@", "2025-2026-1"), on: chart, timeout: 5),
            "向左滑动历史图应选中第一学期。")
        left.press(
            forDuration: 0.6, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0.1)
        assertUI(
            waitUntil(
                NSPredicate(format: "value CONTAINS %@", "2025-2026-2"), on: chart, timeout: 5),
            "向右滑动历史图应选中第二学期。")
    }

    @MainActor
    @objc func testMapLocationAndScheduleLocationRoute() {
        app = configureApp(resetStorage: true, content: true, school: true)
        tap("学校测试课程")
        tap("查看上课地点")
        assertUI(
            waitUntil(NSPredicate(format: "selected == true"), on: app.mainTab("地图")), "课程地点应切换至地图。"
        )
        let location = app.buttons["定位到我的位置"]
        location.tapBriefly()
        UITestSystemAlerts.allowLocation(timeout: 2)
        closeAlertIfPresent()
        assertUI(app.maps.firstMatch.isHittable && location.isEnabled, "定位后地图及控件应继续响应。")
        revealBrowserAction("导航到下一节课").tapBriefly()
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        assertUI(maps.wait(for: .runningForeground, timeout: 10), "下一节导航应交给系统地图。")
        XCUIDevice.shared.press(.home)
        assertUI(
            waitUntil(NSPredicate { _, _ in
                [.runningBackground, .runningBackgroundSuspended].contains(maps.state)
            }, on: app), "返回 App 前系统地图应完成后台切换。")
        app.activate()
        assertUI(location.appears(timeout: 5), "从系统地图返回应恢复地图控件。")
    }

    @MainActor
    @objc func testNetworkDiagnosisProgressAndReport() {
        app = configureApp(
            resetStorage: true, content: true, school: true, initialSettings: "gallery")
        tap("测试网络并生成诊断报告")
        assertUI(app.alerts["网络诊断完成"].appears(timeout: 60), "诊断操作应汇总每个网络步骤。")
        for title in ["网络路径", "BIT101 首页", "话廊接口", "文章接口", "学校当前学期", "课表与考试", "DDL 接口", "可信成绩单"] {
            assertUI(
                app.alerts.staticTexts.allElementsBoundByIndex.contains {
                    $0.label.contains(title)
                }, "诊断报告应包含\(title)。")
        }
        for title in ["话廊接口", "文章接口", "学校当前学期", "课表与考试", "DDL 接口"] {
            assertUI(
                app.alerts.staticTexts.allElementsBoundByIndex.contains {
                    $0.label.contains("\(title)：通过")
                },
                "受控诊断服务应完成\(title)。")
        }
        assertUI(
            app.alerts.staticTexts.allElementsBoundByIndex.contains {
                $0.label.contains("可信成绩单：需要短信验证")
            },
            "成绩单诊断应保留受控服务的短信验证结果。")
        closeAlertIfPresent()
        assertUI(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "测试网络并生成诊断报告"))
                .firstMatch.isEnabled,
            "诊断结束应恢复执行入口。")
    }

    @MainActor
    @objc func testCourseScheduleAcademicRoute() {
        app = configureApp(resetStorage: true, content: true, school: true)
        tap("学校测试课程")
        tap("查看课程评价")
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "学校课程评价入口应打开匹配课程。")
        assertUI(textElement("学校测试课程").exists, "匹配后的课程详情应保留学校课程身份。")
        back()
        app.mainTab("话廊").tapBriefly()
        tap("自动化测试话题")
        tap("ui.gallery-poster-detail-view-scene.profile")
        assertUI(app.buttons["关注"].appears(timeout: 5), "帖子作者应打开公开主页。")
        back()
        tap("分享话题")
        dismissShareSheet()
        guard
            let commentUser = app.buttons.matching(NSPredicate(format: "label == %@", "自动化测试用户"))
                .allElementsBoundByIndex.last
        else {
            assertUI(false, "评论应提供用户主页入口。")
            return
        }
        reveal(commentUser)
        commentUser.tapBriefly()
        assertUI(app.buttons["关注"].appears(timeout: 5), "评论昵称应打开公开主页。")
    }

    @MainActor
    @objc func testEmptyShareAndImportGuideCancel() {
        app = configureApp(resetStorage: true, initialSettings: "calendar")
        tap("分享课表")
        app.alerts["当前课表为空"].buttons["取消"].tapBriefly()
        assertUI(app.buttons["schedule.settings.primary-name"].exists, "取消空课表分享应留在设置页。")
        tap("导入课表")
        app.alerts["导入分享课表提示"].buttons["取消"].tapBriefly()
        assertUI(!app.textViews["schedule.import.code"].exists, "取消导入说明应保留设置页。")
        back()
        app.mainTab("日程").tapBriefly()
        app.buttons["schedule.add-content"].tapBriefly()
        tap("添加日程")
        let sheet = app.navigationBars["添加自定义日程"]
        swipeSheetHeader(sheet)
        assertUI(
            waitUntil(
                NSPredicate(format: "hittable == true"), on: app.buttons["schedule.add-content"],
                timeout: 5), "下滑关闭应恢复课表入口。")
    }

    @MainActor
    @objc func testDdlEditorDetailsCancelEditingEditing() {
        app = configureApp(resetStorage: true)
        tapHeader(app.segmentedControls.buttons["DDL"])
        tap("添加待办")
        tapHeader(app.buttons["ddl.editor.save"])
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "空待办标题应展示校验结果。")
        closeAlertIfPresent()
        replaceText("带详情的待办", in: app.textFields["ddl.editor.title"])
        replaceText("待办详细说明", in: app.textFields["ddl.editor.details"])
        dismissKeyboard()
        openAndDismissDatePicker("ddl.editor.date", coverage: .contract)
        tapHeader(app.buttons["ddl.editor.save"])
        assertUI(app.navigationBars["添加 DDL"].disappears(timeout: 5), "保存应关闭待办编辑器。")
        tap("标记为已完成")
        assertUI(app.buttons["标记为未完成"].exists, "完成操作应更新待办状态。")
        tap("标记为未完成")
        let todo = app.staticTexts["带详情的待办"]
        reveal(todo)
        let card = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "ddl.event.")
        ).firstMatch
        assertUI(card.performAccessibilityAction(named: "打开详情"), "待办卡片应提供可执行的 VoiceOver 动作。")
        assertUI(textElement("待办详细说明").appears(timeout: 5), "待办详情应恢复输入正文。")
        tap("取消")
        todo.tapBriefly()
        assertUI(textElement("待办详细说明").appears(timeout: 5), "待办标题点击应打开详情。")
        tap("编辑")
        replaceText("取消的待办修改", in: app.textFields["ddl.editor.title"])
        dismissKeyboard()
        tap("取消")
        app.alerts["放弃当前输入？"].buttons["放弃输入"].tapBriefly()
        assertUI(textElement("带详情的待办").appears(timeout: 5), "取消待办编辑应保留原记录。")
        todo.tapBriefly()
        tap("编辑")
        replaceText("修改后的待办", in: app.textFields["ddl.editor.title"])
        dismissKeyboard()
        tapHeader(app.buttons["ddl.editor.save"])
        let edited = app.staticTexts["修改后的待办"]
        assertUI(edited.appears(timeout: 5), "保存编辑应更新待办标题。")
        edited.tapBriefly()
        tap("删除")
        assertUI(edited.disappears(timeout: 5), "删除应移除待办记录。")
        tap("添加待办")
        tap("取消")
        assertUI(app.buttons["添加待办"].exists, "取消新增应恢复待办列表。")
    }

}

nonisolated final class AccountRecoveryUITests: UIAutomationTestCase {
    @MainActor
    @objc func testFutureScheduleImportUpdateCancel() {
        app = configureApp(resetStorage: true, animations: true, initialSettings: "calendar")
        app.native.typeKey(XCUIKeyboardKey.shift, modifierFlags: [])
        tap("导入课表")
        tap("知道了")
        let code = app.textViews["schedule.import.code"]
        replaceText("BIT101SCH99:test", in: code)
        dismissKeyboard()
        tap("导入")
        assertUI(app.alerts["需要更新 BIT101"].appears(timeout: 5), "较新编码应展示版本更新提示。")
        app.alerts.buttons["取消"].tapBriefly()
        assertUI(app.alerts["需要更新 BIT101"].disappears(timeout: 5), "取消更新应关闭版本提示。")
        assertUI(code.value as? String == "BIT101SCH99:test", "取消更新应保留编码输入。")
        tap("导入")
        assertUI(app.alerts["需要更新 BIT101"].appears(timeout: 5), "再次导入应展示版本提示。")
        app.alerts["需要更新 BIT101"].buttons["前往 App Store"].tapBriefly()
        assertOpenedURL("apps.apple.com/cn/app/bit101/id6761147125")
        tap("导入")
        assertUI(app.alerts["需要更新 BIT101"].appears(timeout: 5), "键盘验收应展示导入版本提示。")
        assertUI(
            UITestControlClient.request(["command": "keyboard-state"]) == "hidden", "版本提示应释放编码编辑焦点。"
        )
        app.alerts.buttons["前往 App Store"].pressReturnKey()
        assertOpenedURL("apps.apple.com/cn/app/bit101/id6761147125")
        assertUI(app.alerts["需要更新 BIT101"].disappears(timeout: 5), "Return 应关闭导入版本提示。")
        tap("取消")
    }

    @MainActor
    @objc func testWebGallerySettingReturn() {
        app = configureApp(resetStorage: true, content: true, initialSettings: "gallery")
        let value = toggle("使用网页话廊")
        back()
        app.mainTab("话廊").tapBriefly()
        let web = app.webViews.firstMatch
        assertUI(web.appears(timeout: 10), "网页设置应打开 WebKit 页面。")
        web.swipeUp()
        web.swipeDown()
        app = configureApp(resetStorage: false, content: true, initialSettings: "gallery")
        let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "使用网页话廊"))
            .firstMatch
        reveal(control)
        waitForValue(value, of: control)
        toggle("使用网页话廊")
        back()
        app.mainTab("话廊").tapBriefly()
        assertUI(app.buttons["发布话题"].appears(timeout: 5), "切回原生设置应恢复话题发布入口。")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "原生列表应加载测试帖子。")
    }

    @MainActor
    @objc func testErrorReportSanitizedSubmission() {
        app = configureApp(
            resetStorage: true, content: true, failureOnce: true, initialTab: "gallery")
        tap("向开发者分享错误信息")
        let report = app.navigationBars["分享错误信息"]
        assertUI(report.appears(timeout: 5), "诊断入口应呈现报告编辑器。")
        app = configureApp(
            resetStorage: false, content: true, failureOnce: true, feedbackResponseLostOnce: true,
            initialTab: "gallery")
        assertUI(report.disappears(timeout: 5), "场景切换应清理全局错误报告并恢复原进程页面。")
        assertUI(app.alerts["加载话廊失败"].appears(timeout: 5), "新场景应呈现所属请求的错误提示。")
        tap("向开发者分享错误信息")
        assertUI(report.appears(timeout: 5), "新场景应支持重新打开错误报告。")
        tap("原始网络响应")
        tap("脱敏调试信息")
        replaceText("合成错误报告复现步骤", in: app.textFields["error-report.comment"])
        dismissKeyboard()
        tap("提交")
        assertUI(app.alerts.buttons["继续提交"].appears(timeout: 5), "脱敏报告提交应请求确认。")
        tap("继续提交")
        let failure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "提交失败："))
            .firstMatch
        assertUI(failure.appears(timeout: 5), "受理后的响应丢失应呈现可重试结果。")
        assertUI(
            app.textFields["error-report.comment"].value as? String == "合成错误报告复现步骤",
            "响应丢失应保留错误报告内容。")
        tap("提交")
        tap("继续提交")
        assertUI(
            waitUntil(NSPredicate(format: "exists == false"), on: report, timeout: 5),
            "反馈响应成功应关闭报告编辑器。")
        tap("重试")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "提交报告后重试应恢复帖子列表。")
    }

    @MainActor
    @objc func testLoginSubmitButton() {
        app = configureApp(
            resetStorage: true, account: nil, animations: true, nativeInteraction: true)
        assertUI(app.secureTextFields["login.password"].exists, "登录页应展示密码字段。")
        app.buttons["login.submit"].assertDisabled("空凭据应禁用登录。")
        replaceTextWithKeyboard("ui-test-student", in: app.textFields["login.student-id"])
        app.buttons["login.submit"].assertDisabled("仅填写账号应保持登录禁用。")
        let submitBounds = app.buttons["login.submit"].native.frame
        app.native.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: submitBounds.midX, dy: submitBounds.maxY + 24)).tap()
        assertUI(app.keyboards.firstMatch.disappears(timeout: 5), "点按表单空白区域应收起系统键盘。")
        replaceTextWithKeyboard("ui-test-password", in: app.secureTextFields["login.password"])
        app.collectionViews.firstMatch.swipeUp()
        dismissKeyboard()
        let submit = app.buttons["login.submit"]
        assertUI(submit.isEnabled, "完整填写凭据应启用登录按钮。")
        submit.tapBriefly()
        assertUI(app.mainTab("日程").appears(timeout: 10), "点击登录按钮应进入主界面。")
    }

}

nonisolated final class AccountRegistrationUITests: UIAutomationTestCase {
    @MainActor
    func testRegistrationReset() throws {
        defer { Self.endSharedSession() }
        for method in ["统一身份认证", "校园邮箱"] {
            Self.endSharedSession()
            app = configureApp(
                resetStorage: true, account: nil, animations: true, nativeInteraction: true)
            app.buttons["login.register"].tapBriefly()
            let submit = app.buttons["registration.submit"]
            submit.assertDisabled("注册需要完整密码及身份验证。")
            replaceTextWithKeyboard("1120260001", in: app.textFields["registration.student-id"])
            replaceTextWithKeyboard(
                "community-password", in: app.secureTextFields["registration.password"])
            replaceTextWithKeyboard(
                "different-password", in: app.secureTextFields["registration.confirmation"])
            dismissKeyboard()
            if method == "校园邮箱" { choose("验证方式", option: method) }
            if method == "统一身份认证" {
                replaceTextWithKeyboard(
                    "school-password", in: app.secureTextFields["registration.school-password"])
                dismissKeyboard()
                app.buttons["registration.verify"].tapBriefly()
                assertUI(textElement("身份验证成功").appears(timeout: 5), "学校认证应呈现成功状态。")
                app.buttons["registration.verify"].assertDisabled("已验证身份应保持当前验证结果。")
            } else {
                app.buttons["registration.send-code"].tapBriefly()
                app.buttons["registration.send-code"].assertDisabled("发送成功后应显示重发倒计时。")
                replaceTextWithKeyboard("123456", in: app.textFields["registration.code"])
                dismissKeyboard()
            }
            reveal(submit)
            submit.assertDisabled("两次密码一致后可提交。")
            replaceTextWithKeyboard(
                "community-password", in: app.secureTextFields["registration.confirmation"])
            dismissKeyboard()
            reveal(submit)
            XCTAssertTrue(submit.native.isEnabled && submit.native.isHittable)
            let screenshot = XCTAttachment(screenshot: app.native.screenshot())
            screenshot.name = "界面截图"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            submit.tapBriefly()
            assertUI(app.mainTab("日程").appears(timeout: 10), "注册或重置成功应进入已登录页面。")
        }
        Self.endSharedSession()
        app = configureApp(
            resetStorage: true, account: nil, animations: true, nativeInteraction: true)
        app.buttons["login.register"].tapBriefly()
        back()
        replaceTextWithKeyboard("1120260001", in: app.textFields["login.student-id"])
        replaceTextWithKeyboard("community-password", in: app.secureTextFields["login.password"])
        dismissKeyboard()
        app.buttons["login.submit"].tapBriefly()
        assertUI(app.mainTab("日程").appears(timeout: 10), "BIT101 密码登录应进入已登录页面。")
    }
}

extension UIAutomationTestCase {
    @MainActor
    func tapLink(_ title: String) {
        let types = [
            Int(XCUIElement.ElementType.link.rawValue),
            Int(XCUIElement.ElementType.button.rawValue),
        ]
        let link = app.descendants(matching: .any)
            .matching(NSPredicate(format: "elementType IN %@ AND label CONTAINS %@", types, title))
            .firstMatch
        reveal(link, description: title)
        link.tap()
    }

    @MainActor
    func assertOpenedURL(_ target: String, exact: Bool = false) {
        var openedURL = ""
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    openedURL = UITestControlClient.request(["command": "consume-opened-url"]) ?? ""
                    return !openedURL.isEmpty
                }, on: app), "链接操作应发出页面选定的地址。")
        assertUI(
            exact ? openedURL == target : openedURL.contains(target),
            "链接地址应匹配\(target)，实际地址：\(openedURL)。")
    }

    @MainActor
    func dismissShareSheet() {
        dismissNotificationBanner()
        let sheet = app.navigationBars["UIActivityContentView"]
        assertUI(sheet.appears(timeout: 30), "分享入口应打开系统分享面板。")
        let dismissRegion = app.otherElements.matching(identifier: "PopoverDismissRegion")
            .firstMatch
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["关闭", "Close"]))
            .firstMatch
        let popover = app.popovers.firstMatch
        if dismissRegion.exists, popover.exists {
            dismissSystemPopover(popover)
        } else {
            assertUI(close.appears(timeout: 5), "分享面板应提供关闭控件。")
            close.tapBriefly()
        }
        assertUI(
            waitUntil(NSPredicate(format: "exists == false"), on: sheet, timeout: 5),
            "关闭分享面板应返回来源页面。")
    }

    @MainActor
    func dismissSystemPopover(_ popover: UIElement, within bounds: CGRect? = nil) {
        let dismiss = app.buttons["PopoverDismissRegion"]
        let isSourceForm = bounds != nil
        let bounds = bounds ?? app.frame
        let panel = popover.frame
        let gaps = [
            CGRect(
                x: bounds.minX, y: bounds.minY, width: panel.minX - bounds.minX,
                height: bounds.height),
            CGRect(
                x: panel.maxX, y: bounds.minY, width: bounds.maxX - panel.maxX,
                height: bounds.height),
            CGRect(
                x: bounds.minX, y: bounds.minY, width: bounds.width,
                height: panel.minY - bounds.minY),
            CGRect(
                x: bounds.minX, y: panel.maxY, width: bounds.width, height: bounds.maxY - panel.maxY
            ),
        ].filter { $0.size.width > 0 && $0.size.height > 0 }
            .map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        guard
            let gap = isSourceForm
                ? gaps.first : gaps.max(by: { $0.width * $0.height < $1.width * $1.height })
        else {
            assertUI(false, "系统浮窗外应提供可点击的页面区域。")
            return
        }
        let origin =
            dismiss.exists
            ? dismiss.coordinate(withNormalizedOffset: .zero)
            : app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: gap.midX, dy: gap.midY)).tapBriefly()
        assertUI(popover.disappears(timeout: 5), "点击浮窗外应关闭系统浮窗。")
    }

    @MainActor
    func pullToRefresh(whileRefreshing: () -> Void = {}) {
        guard let value = UITestControlClient.request(["command": "scroll-inventory"]),
            let data = value.data(using: .utf8),
            let views = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let viewport = views.last(where: { $0["hasRefreshControl"] as? Bool == true })?[
                "viewport"] as? [Double],
            viewport.count == 4,
            let bounds = app.scrollGestureFrame(
                in: CGRect(x: viewport[0], y: viewport[1], width: viewport[2], height: viewport[3]))
        else {
            assertUI(false, "刷新场景应提供可滚动区域。")
            return
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(
            CGVector(dx: bounds.minX + bounds.width * 0.03, dy: bounds.minY + bounds.height * 0.2))
        let end = origin.withOffset(
            CGVector(dx: bounds.minX + bounds.width * 0.03, dy: bounds.minY + bounds.height * 0.9))
        start.press(
            forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
        whileRefreshing()
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    guard let value = UITestControlClient.request(["command": "scroll-inventory"]),
                        let data = value.data(using: .utf8),
                        let views = try? JSONSerialization.jsonObject(with: data)
                            as? [[String: Any]],
                        let scroll = views.last(where: { $0["hasRefreshControl"] as? Bool == true })
                    else { return false }
                    return scroll["refreshing"] as? Bool == false
                        && scroll["scrolling"] as? Bool == false
                }, on: app), "下拉刷新完成并停止滚动后应继续交互。")
    }

    @MainActor
    func swipeSheetHeader(_ header: UIElement) {
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.01,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
            withVelocity: .fast, thenHoldForDuration: 0.01)
    }

    @MainActor
    func dismissPosterSheet(returningTo title: String) {
        let detail = app.navigationBars["帖子详情"]
        swipeSheetHeader(detail)
        assertUI(waitUntil(NSPredicate { _, _ in !detail.native.exists }, on: detail), "下滑应关闭帖子详情。")
        assertUI(
            waitUntil(NSPredicate(format: "hittable == true"), on: app.navigationBars[title]),
            "关闭详情应恢复\(title)。")
    }

    @MainActor
    func tapSearchSort(_ title: String) {
        let menu = app.buttons["search.sort"]
        reveal(menu, description: "搜索排序")
        assertUI(menu.label.contains(title), "搜索排序应显示当前选项\(title)。")
        menu.tapBriefly()
    }

    enum DatePickerCoverage {
        case contract
        case integration
    }

    @MainActor
    func openAndDismissDatePicker(_ identifier: String, coverage: DatePickerCoverage) {
        let field = app.datePickers[identifier]
        reveal(field)
        _ = UITestControlClient.request([
            "command": "callback", "identifier": identifier, "action": "selection",
        ])
        guard let fieldState = try? field.snapshot() else {
            assertUI(false, "日期时间控件应提供可读的界面状态。")
            return
        }
        var seen = Set<String>()
        let labels = fieldState.snapshots(matching: .button).compactMap { button -> String? in
            guard !button.frame.isEmpty,
                button.children.allSatisfy({
                    $0.firstSnapshot(where: { $0.elementType == .button }) == nil
                })
            else { return nil }
            let label = button.label
            return seen.insert(label).inserted ? label : nil
        }
        assertUI(!labels.isEmpty, "日期时间控件应暴露系统选择入口。")
        let pickerCount = app.datePickers.count
        let form = app.collectionViews.containing(.datePicker, identifier: identifier).firstMatch
        guard let formState = try? form.snapshot() else {
            assertUI(false, "日期时间编辑页应提供来源表单。")
            return
        }
        let sourceBounds = formState.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for label in labels {
            guard let currentField = try? field.snapshot(),
                let button = currentField.firstSnapshot(where: {
                    $0.elementType == .button && $0.label == label
                })
            else {
                assertUI(false, "日期时间入口应保持可交互：\(label)。")
                return
            }
            origin.withOffset(CGVector(dx: button.frame.midX, dy: button.frame.midY)).tapBriefly()
            let nativePicker = app.datePickers.matching(NSPredicate(format: "identifier == %@", ""))
                .firstMatch
            guard let pickerState = try? nativePicker.snapshot() else {
                assertUI(false, "日期或时间点击应打开独立的系统选择器。")
                return
            }
            let wheels = pickerState.snapshots(matching: .pickerWheel)
            if !wheels.isEmpty {
                exerciseTimePickerWheels(
                    nativePicker, wheels: wheels, origin: origin, coverage: coverage)
            } else if identifier == "ddl.editor.date" {
                exerciseSystemCalendar(nativePicker)
            }
            dismissSystemPopover(nativePicker, within: sourceBounds)
            assertUI(app.pickerWheels.firstMatch.disappears(timeout: 5), "关闭选择器应收起时间滚轮。")
            assertUI(field.exists && app.datePickers.count == pickerCount, "关闭选择器应恢复来源日期控件。")
            dismissKeyboard()
        }
    }

    @MainActor
    private func exerciseTimePickerWheels(
        _ nativePicker: UIElement,
        wheels: [any XCUIElementSnapshot],
        origin: UIAutomationCoordinate,
        coverage: DatePickerCoverage
    ) {
        let exercisedWheels = coverage == .contract ? wheels : Array(wheels.prefix(1))
        for (index, state) in exercisedWheels.enumerated() {
            let wheel = nativePicker.pickerWheels.element(boundBy: index)
            let original = state.value as? String ?? ""
            let downward =
                original.hasPrefix("59") || original.hasPrefix("23")
                || original.hasPrefix("下午")
            let start = origin.withOffset(
                CGVector(dx: state.frame.midX, dy: state.frame.midY))
            start.press(
                forDuration: 0.1,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: downward ? 44 : -44)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
            assertUI(
                waitUntil(NSPredicate(format: "value != %@", original), on: wheel),
                "第\(index + 1)列时间滚轮应响应滑动。")
            let selection =
                original.first?.isNumber == true
                ? String(original.prefix(while: { $0.isNumber })) : original
            wheel.adjust(toPickerWheelValue: selection)
            waitForValue(original, of: wheel)
        }
    }

    @MainActor
    func exerciseSystemCalendar(_ picker: UIElement) {
        let month = picker.buttons.matching(
            NSPredicate(format: "identifier IN %@", ["DatePicker.Show", "DatePicker.Hide"])
        ).firstMatch
        let original = month.value as? String ?? ""
        assertUI(!original.isEmpty, "日历标题应显示当前年月。")
        picker.buttons["DatePicker.NextMonth"].tapBriefly()
        assertUI(waitUntil(NSPredicate(format: "value != %@", original), on: month), "下一月应更新日历标题。")
        picker.buttons["DatePicker.PreviousMonth"].tapBriefly()
        assertUI(waitUntil(NSPredicate(format: "value == %@", original), on: month), "上一月应恢复当前月份。")
        month.tapBriefly()
        assertUI(app.pickerWheels.firstMatch.appears(timeout: 5), "月份标题应打开年月滚轮。")
        for index in 0..<app.pickerWheels.count {
            let wheel = app.pickerWheels.element(boundBy: index)
            let value = wheel.value as? String ?? ""
            wheel.swipeUp()
            assertUI(waitUntil(NSPredicate(format: "value != %@", value), on: wheel), "年月滚轮应响应滑动。")
            wheel.adjust(toPickerWheelValue: value)
            waitForValue(value, of: wheel)
        }
        month.tapBriefly()
        assertUI(app.pickerWheels.firstMatch.disappears(timeout: 5), "月份标题应返回日期网格。")
        guard
            let selected = picker.collectionViews.buttons.allElementsBoundByIndex.first(where: {
                $0.isSelected
            })
        else {
            assertUI(false, "日期网格应标记当前选择。")
            return
        }
        selected.tapBriefly()
    }
    @MainActor
    func tapImage(_ title: String) {
        let image = app.buttons[title]
        var frame = CGRect.zero
        if image.exists {
            frame = image.frame
            if frame.isEmpty {
                assertUI(
                    waitUntil(NSPredicate { _, _ in !image.frame.isEmpty }, on: image), "图片入口应完成布局。"
                )
                frame = image.frame
            }
        }
        if frame.isEmpty || !app.windows.firstMatch.frame.contains(frame) {
            reveal(image, description: title)
        }
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapBriefly()
    }

    @MainActor
    func swipeImagePreview(towardEnd: Bool) {
        let preview = app.native.descendants(matching: .any)["QLPreviewControllerView"]
        if towardEnd {
            preview.swipeLeft(velocity: .slow)
        } else {
            preview.swipeRight(velocity: .slow)
        }
        UITestSnapshotReader.invalidate()
    }

    @MainActor
    func closeImagePreview() {
        dismissNotificationBanner()
        let close = imagePreviewCloseButton()
        close.native.tap()
        UITestSnapshotReader.invalidate()
        assertUI(waitForImagePreview(visible: false, timeout: 5), "关闭图片预览应恢复来源页面。")
    }

    @MainActor
    func imagePreviewCloseButton() -> UIElement {
        let platform = UIElement(app.native)
        assertUI(waitForImagePreview(visible: true, timeout: 30), "图片交互应进入系统 Quick Look。")
        let done = platform.buttons.matching(
            NSPredicate(format: "label IN %@", ["完成", "Done", "关闭", "Close"])
        ).firstMatch
        let ready = NSPredicate { _, _ in done.exists && !done.frame.isEmpty }
        if !waitUntil(ready, on: done, timeout: 1) {
            app.native.images.firstMatch.coordinate(
                withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25)
            ).tap()
            UITestSnapshotReader.invalidate()
        }
        assertUI(waitUntil(ready, on: done, timeout: 10), "系统预览应完成关闭控件布局。")
        return done
    }
}
