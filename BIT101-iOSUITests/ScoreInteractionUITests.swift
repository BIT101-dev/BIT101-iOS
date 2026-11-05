import CoreGraphics
import XCTest

nonisolated final class ScoreInteractionUITests: UIAutomationTestCase {
    @MainActor
    @objc func testScoreDetailFollowsDetailedRefresh() throws {
        XCUIDevice.shared.orient(to: .landscapeLeft)
        defer { XCUIDevice.shared.orient(to: .portrait) }
        app = configureApp(
            resetStorage: true, content: true, animations: true, school: true, initialTab: "home")
        guard
            waitUntil(
                NSPredicate { _, _ in
                    self.app.windows.firstMatch.frame.width
                        > self.app.windows.firstMatch.frame.height
                }, on: app)
        else {
            throw XCTSkip("本例验收横屏双栏窗口。")
        }
        assertUI(
            UITestControlClient.request(["command": "hold-request", "key": "score-details"])
                == "queued", "详细成绩应进入受控等待。")
        defer {
            _ = UITestControlClient.request(["command": "release-request", "key": "score-details"])
        }
        app.buttons["score.query"].tapBriefly()
        fillVerificationCode("123456", in: app.textFields["verification.code"])
        waitForRequest("score-details")
        let grade = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "ui.score-list-page.score.")
        ).firstMatch
        reveal(grade, description: "简略成绩记录")
        grade.tapBriefly()
        assertUI(app.navigationBars["成绩详情"].appears(timeout: 5), "简略成绩应在右栏打开详情。")
        assertUI(!textElement("平均分、94.50").exists, "详细字段等待服务响应后展示。")
        releaseRequest("score-details")
        assertUI(textElement("平均分、94.50").appears(timeout: 5), "详细结果到达后，已打开的详情应原位更新。")
    }

    @MainActor
    @objc func testScoreIndividualFiltersRefreshCancel() {
        app = configureApp(
            resetStorage: true, content: true, animations: true, school: true, initialTab: "home")
        app.buttons["score.query"].tapBriefly()
        let code = app.textFields["verification.code"]
        assertUI(code.appears(timeout: 5), "成绩查询应打开短信验证。")
        app.buttons["验证并查询成绩"].assertDisabled("空验证码应禁用提交。")
        replaceTextWithKeyboard("000000", in: code)
        assertUI(code.value as? String == "000000", "逐位输入应保留完整验证码供手动验证。")
        dismissKeyboard()
        tap("验证并查询成绩")
        assertUI(app.staticTexts["测试验证码错误。"].appears(timeout: 5), "错误验证码应展示重试说明。")
        tap("取消")
        let retry = app.buttons["重新查询"]
        assertUI(retry.appears(timeout: 5) && retry.isEnabled, "取消短信应恢复重新查询入口。")
        retry.tapBriefly()
        fillVerificationCode("００٠٠００", in: app.textFields["verification.code"])
        assertUI(app.staticTexts["测试验证码错误。"].appears(timeout: 5), "完整错误验证码自动验证后应允许修改。")
        let manualRetry = app.buttons["验证并查询成绩"]
        assertUI(
            waitUntil(NSPredicate(format: "enabled == true"), on: manualRetry),
            "自动验证错误后应恢复手动重试。")
        fillVerificationCode("１２٣٤５６", in: app.textFields["verification.code"])
        assertUI(textElement("自动化测试课程").appears(timeout: 5), "替换完整验证码应自动验证并加载成绩。")
        assertUI(textElement("自动化测试课程").label.contains("专业教育"), "成绩行应显示学校课程性质。")
        for (route, option) in [("学期", "ui-test-term"), ("种类", "专业教育")] {
            openScoreFilter(route)
            if route == "种类" {
                for title in ["选修", "必修", "未分类"] {
                    assertUI(
                        !app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
                            .exists,
                        "成绩分类选项应来自实际成绩：\(title)。")
                }
            }
            if route == "学期" {
                tap("全不选")
                assertUI(app.buttons["全选"].exists, "公共筛选页批量清空应恢复全选操作。")
                tap("全选")
            }
            let item = app.buttons.matching(NSPredicate(format: "label == %@", option)).firstMatch
            assertUI(item.appears(timeout: 5), "筛选页应加载\(option)选项。")
            item.tapBriefly()
            waitForValue("未选择", of: item)
            back()
            assertUI(app.navigationBars["\(route)筛选"].disappears(timeout: 5), "返回应关闭\(route)筛选页。")
            assertUI(app.staticTexts["当前筛选条件下暂无成绩。"].appears(timeout: 5), "取消单项选择应过滤成绩。")
            openScoreFilter(route)
            assertUI(item.appears(timeout: 5), "重新打开应恢复\(option)筛选项。")
            item.tapBriefly()
            waitForValue("已选择", of: item)
            back()
            assertUI(app.navigationBars["\(route)筛选"].disappears(timeout: 5), "选择后返回应恢复成绩页。")
        }
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "排序")).firstMatch
            .tapBriefly()
        assertUI(app.navigationBars["成绩排序"].appears(timeout: 5), "排序入口应完成页面导航。")
        for title in ["名称", "成绩", "均分", "学分", "学期", "种类"] {
            let index = app.collectionViews.buttons.matching(
                NSPredicate(format: "label == %@", title)
            ).firstMatch
            reveal(index, description: title)
            index.tapBriefly()
            assertUI(
                app.descendants(matching: .any).matching(
                    NSPredicate(format: "label == %@ AND selected == true", title)
                ).firstMatch.exists,
                "排序应选中索引：\(title)。")
        }
        let direction = app.buttons["排序方向"]
        let initialDirection = direction.value as? String
        direction.tapBriefly()
        assertUI(direction.value as? String != initialDirection, "排序方向应切换。")
        back()
        app.buttons["score.query"].tapBriefly()
        fillVerificationCode("123456", in: app.textFields["verification.code"])
        assertUI(textElement("自动化测试课程").appears(timeout: 5), "已有成绩刷新应恢复成绩列表。")
        assertUI(app.alerts["成绩已是最新"].appears(timeout: 5), "重复查询应展示当前成绩已是最新。")
        closeAlertIfPresent()
        tap("学校测试课程")
        assertUI(app.navigationBars["成绩详情"].appears(timeout: 5), "未出分课程应打开详情。")
        back()
        tap("自动化测试课程")
        assertUI(app.navigationBars["成绩详情"].appears(timeout: 5), "成绩行应打开详情。")
        tap("查看课程评价")
        assertUI(
            waitUntil(
                NSPredicate(format: "selected == true"), on: app.segmentedControls.buttons["课程"]),
            "成绩详情应进入课程搜索。")
    }

    @MainActor
    private func openScoreFilter(_ title: String) {
        let route = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title)、"))
            .firstMatch
        reveal(route, description: "\(title)筛选")
        route.tapBriefly()
        assertUI(app.navigationBars["\(title)筛选"].appears(timeout: 5), "筛选入口应打开\(title)选择页。")
    }

    @MainActor
    @objc func testScoreStorageRecoveryConfirmation() {
        app = configureApp(resetStorage: true, scoreRecovery: true, initialTab: "home")
        closeAlertIfPresent()
        tap("score.recover-storage")
        let confirmation = app.alerts["恢复成绩存储"]
        assertUI(confirmation.appears(timeout: 5), "成绩恢复应展示账号数据影响。")
        confirmation.buttons["取消"].tapBriefly()
        assertUI(app.buttons["score.recover-storage"].exists, "取消后应继续保留恢复入口。")
        tap("score.recover-storage")
        assertUI(confirmation.appears(timeout: 5), "再次恢复应展示确认。")
        confirmation.buttons["恢复"].tapBriefly()
        assertUI(app.buttons["score.recover-storage"].disappears(timeout: 5), "恢复完成应更新存储状态。")
        app = configureApp(resetStorage: false, initialTab: "home")
        assertUI(app.buttons["score.query"].appears(timeout: 5), "重新打开应展示成绩查询。")
        assertUI(!app.buttons["score.recover-storage"].exists, "重新加载应读取恢复后的筛选偏好。")
    }

    @MainActor
    @objc func testTrustedTranscriptSmsRetryPreview() throws {
        app = configureApp(
            resetStorage: true, animations: true, transcriptFailureOnce: true, initialTab: "home")
        tap("申请可信成绩单")
        tap("取消")
        tap("重试")
        let code = app.textFields["verification.code"]
        fillVerificationCode("123456", in: code)
        assertUI(code.disappears(timeout: 5), "验证成功应关闭短信输入窗口。")
        assertUI(app.staticTexts["部分成绩单待恢复"].appears(timeout: 5), "分页故障应保留已取得的成绩单页面。")
        assertUI(app.buttons["可信成绩单第1页"].exists, "可用页面应继续提供预览。")
        tap("重试")
        assertUI(app.staticTexts["部分成绩单待恢复"].disappears(timeout: 5), "重试应复用认证并恢复完整页面。")
        tap("可信成绩单第1页")
        _ = imagePreviewCloseButton()
        func assertPreviewPage(_ index: Int) throws {
            let pageReady = NSPredicate { _, _ in
                guard let value = UITestControlClient.request(["command": "preview-page"]),
                    let page = try? JSONSerialization.jsonObject(with: Data(value.utf8))
                        as? [String: Int]
                else { return false }
                return page["count"] == 2 && page["index"] == index
            }
            assertUI(waitUntil(pageReady, on: app), "预览应展示两页成绩单中的第 \(index + 1) 页。")
        }
        try assertPreviewPage(0)
        swipeImagePreview(towardEnd: true)
        try assertPreviewPage(1)
        swipeImagePreview(towardEnd: false)
        try assertPreviewPage(0)
        closeImagePreview()
        assertUI(app.navigationBars["可信成绩单"].appears(timeout: 5), "关闭预览应返回成绩单。")
        reveal(app.buttons["可信成绩单第2页"])
        app.buttons["可信成绩单第2页"].tapBriefly()
        _ = imagePreviewCloseButton()
        try assertPreviewPage(1)
        closeImagePreview()
    }

    @MainActor
    @objc func testTrustedTranscriptKeepsAvailablePages() {
        app = configureApp(
            resetStorage: true, animations: true, transcriptFailureOnce: true, initialTab: "home")
        tap("申请可信成绩单")
        fillVerificationCode("123456", in: app.textFields["verification.code"])
        assertUI(app.staticTexts["部分成绩单待恢复"].appears(timeout: 5), "补页提示应保留当前报告的有效页。")
        assertUI(app.buttons["可信成绩单第1页"].appears(timeout: 5), "当前成绩单应保持可读。")
        tap("ui.trusted-transcript-page.reapply")
        assertUI(app.staticTexts["部分成绩单待恢复"].disappears(timeout: 5), "重新申请应取得完整报告。")
        assertUI(
            app.buttons["可信成绩单第1页"].appears(timeout: 5)
                && app.buttons["可信成绩单第2页"].appears(timeout: 5),
            "新报告应完整展示两页内容。")
    }

}

nonisolated final class CalendarInteractionUITests: UIAutomationTestCase {
    @MainActor
    @objc func testCalendarImportHistoryKeepsAvailable() {
        app = configureApp(
            resetStorage: true, school: true, calendarHistoryRecovery: true,
            initialSettings: "calendar")
        let recovery = app.buttons["schedule.calendar.recover-history"]
        reveal(recovery, description: "日历记录重建入口")
        assertUI(recovery.isHittable, "课表设置应直接提供日历记录重建入口。")
        tap("导入到系统日历")
        app.alerts["导入当前学期到系统日历？"].buttons["导入并替换本学期旧事件"].tapBriefly()
        assertUI(app.alerts["导入失败"].appears(timeout: 5), "导入记录受损应展示恢复提示。")
        closeAlertIfPresent()
        tap("schedule.calendar.recover-history")
        assertUI(app.alerts["重建日历导入记录？"].appears(timeout: 5), "重建应先展示影响确认。")
        app.alerts["重建日历导入记录？"].buttons["schedule.calendar.recover-history.cancel"].tapBriefly()
        tap("schedule.calendar.recover-history")
        app.alerts["重建日历导入记录？"].buttons["schedule.calendar.recover-history.confirm"].tapBriefly()
        assertUI(app.alerts["导入记录已恢复"].appears(timeout: 5), "重建后应展示恢复结果。")
        closeAlertIfPresent()
        tap("导入到系统日历")
        app.alerts["导入当前学期到系统日历？"].buttons["导入并替换本学期旧事件"].tapBriefly()
        assertUI(app.alerts["导入成功"].appears(timeout: 5), "恢复后应完成当前学期导入。")
        closeAlertIfPresent()
    }

    @MainActor
    @objc func testCalendarReminderCloudSwitches() {
        app = configureApp(resetStorage: true, animations: true, initialSettings: "calendar")
        let sync = toggle("iCloud 多端同步")
        let preferences = toggle("同步设置与使用偏好（实验性）")
        let reminderControl = app.switches.matching(
            NSPredicate(format: "label CONTAINS %@", "显示灵动岛提醒（实验性）")
        ).firstMatch
        let reminderSwitch = reminderControl.switches.firstMatch
        reveal(reminderSwitch)
        reminderSwitch.tap()
        assertUI(app.alerts["实验性功能提醒"].appears(timeout: 5), "提醒开关应展示实验功能确认。")
        app.alerts["实验性功能提醒"].buttons["取消"].tapBriefly()
        waitForValue("0", of: reminderControl)
        assertUI(app.alerts["实验性功能提醒"].disappears(timeout: 5), "取消应关闭实验功能确认。")
        assertUI(
            waitUntil(NSPredicate(format: "hittable == true"), on: reminderSwitch), "取消后提醒开关应恢复交互。")
        reminderSwitch.tap()
        assertUI(app.alerts["实验性功能提醒"].appears(timeout: 5), "再次开启应展示确认。")
        app.alerts["实验性功能提醒"].buttons["继续打开"].tapBriefly()
        waitForValue("1", of: reminderControl)
        assertUI(app.alerts["实验性功能提醒"].disappears(timeout: 5), "继续打开应关闭实验功能确认。")
        let reminder = reminderControl.value as? String ?? ""
        tap("提前显示阈值")
        assertUI(app.pickerWheels.firstMatch.appears(timeout: 5), "提醒阈值应提供滚轮选择。")
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "15 分钟")
        tap("取消")
        tap("提前显示阈值")
        assertUI(app.pickerWheels.firstMatch.appears(timeout: 5), "再次打开应恢复提醒阈值滚轮。")
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "20 分钟")
        tap("完成")
        app = configureApp(resetStorage: false, animations: true, initialSettings: "calendar")
        for (title, value) in [("iCloud 多端同步", sync), ("同步设置与使用偏好（实验性）", preferences)] {
            let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", title))
                .firstMatch
            reveal(control)
            waitForValue(value, of: control)
        }
        let control = app.switches.matching(
            NSPredicate(format: "label CONTAINS %@", "显示灵动岛提醒（实验性）")
        ).firstMatch
        reveal(control)
        waitForValue(reminder, of: control)
        tap("提前显示阈值")
        waitForValue("20 分钟", of: app.pickerWheels.firstMatch)
        tap("取消")
        for title in ["清理当前账号的云端偏好记录", "清理其他账号的云端偏好记录"] {
            tap(title)
            let confirmation = app.alerts["清理云端偏好记录"]
            assertUI(confirmation.appears(timeout: 5), "清理操作应先展示影响确认。")
            confirmation.buttons["取消"].tapBriefly()
            let preferencesControl = app.switches.matching(
                NSPredicate(format: "label CONTAINS %@", "同步设置与使用偏好（实验性）")
            ).firstMatch
            reveal(preferencesControl)
            waitForValue(preferences, of: preferencesControl)
            tap(title)
            assertUI(confirmation.appears(timeout: 5), "再次清理应展示影响确认。")
            confirmation.buttons["清理"].tapBriefly()
            assertUI(app.alerts["云端记录清理"].appears(timeout: 5), "清理完成应展示提交结果。")
            app.alerts["云端记录清理"].buttons["好"].tapBriefly()
            reveal(preferencesControl)
            waitForValue("0", of: preferencesControl)
            if preferences == "1" { preferencesControl.switches.firstMatch.tap() }
        }
    }

    @MainActor
    @objc func testSchoolTermsClassroomPickersRefresh() {
        app = configureApp(resetStorage: true, school: true, initialSettings: "calendar")
        tap("当前学期")
        assertUI(app.buttons["ui-test-term-2"].appears(timeout: 5), "学校响应应展示可切换的学期。")
        pullToRefresh()
        tap("ui-test-term-2")
        back()
        assertUI(textElement("ui-test-term-2").appears(timeout: 5), "学期选择应更新当前学期。")
        tap("学期起始日期")
        let wheel = app.pickerWheels.element(boundBy: app.pickerWheels.count - 1)
        let initial = wheel.value as? String
        wheel.swipeUp()
        let manualValue = wheel.value as? String ?? ""
        assertUI(manualValue != initial, "日期滚轮应响应滑动。")
        let chosenValues =
            (try? app.datePickers.firstMatch.snapshot())?.snapshots(matching: .pickerWheel)
            .compactMap { ($0.value as? String).flatMap { Int($0.filter(\.isNumber)) } } ?? []
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(secondsFromGMT: 8 * 3600) else {
            assertUI(false, "日期验收应创建学校所在时区。")
            return
        }
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        guard chosenValues.count == 3,
            let chosenDate = calendar.date(
                from: DateComponents(
                    year: chosenValues[0], month: chosenValues[1], day: chosenValues[2])),
            let monday = calendar.dateInterval(of: .weekOfYear, for: chosenDate)?.start
        else {
            assertUI(false, "日期滚轮应提供可计算首周周一的完整日期。")
            return
        }
        let savedValues = [
            "\(calendar.component(.year, from: monday))年",
            "\(calendar.component(.month, from: monday))月",
            "\(calendar.component(.day, from: monday))日",
        ]
        tap("完成")
        app = configureApp(resetStorage: false, school: true, initialSettings: "calendar")
        tap("学期起始日期")
        let savedWheel = app.pickerWheels.element(boundBy: app.pickerWheels.count - 1)
        let actualValues = (try? app.datePickers.firstMatch.snapshot())?.snapshots(
            matching: .pickerWheel
        ).compactMap { $0.value as? String }
        assertUI(actualValues == savedValues, "重新装载应保留手动设置的首周周一。")
        savedWheel.adjust(toPickerWheelValue: initial ?? "")
        assertUI(savedWheel.value as? String != savedValues.last, "取消前应更改日期草稿。")
        tap("取消")
        tap("学期起始日期")
        let restoredWheel = app.pickerWheels.element(boundBy: app.pickerWheels.count - 1)
        assertUI(restoredWheel.value as? String == savedValues.last, "取消应保留已保存的学期日期。")
        tap("使用学校日期")
        tap("完成")
        back()
        app.mainTab("日程").tapBriefly()
        tapHeader(app.sectionTab("空教室"))
        assertUI(textElement("A101").appears(timeout: 10), "学校响应应展示空教室。")
        choose("校区", option: "中关村校区")
        choose("教学楼", option: "文萃楼B")
        assertUI(textElement("B101").appears(timeout: 5), "教学楼选择应更新教室结果。")
        tap("刷新")
        assertUI(textElement("B101").appears(timeout: 5), "手动刷新应恢复当前教学楼结果。")
        openSettings("ddl")
        tap("重新获取订阅链接")
        assertUI(app.alerts["订阅链接更新成功"].appears(timeout: 5), "更新订阅链接应展示成功提示。")
        closeAlertIfPresent()
        tap("刷新学校日程")
        assertUI(app.alerts["DDL 同步成功"].appears(timeout: 5), "刷新学校日程应展示同步结果。")
        closeAlertIfPresent()
        back()
        app.mainTab("日程").tapBriefly()
        tapHeader(app.segmentedControls.buttons["DDL"])
        let assignment = app.staticTexts["课程中心测试作业"]
        reveal(assignment)
        assertUI(textElement("刷新后的学校详情").appears(timeout: 5), "学校刷新应更新详情正文。")
        assignment.tapBriefly()
        assertOpenedURL("https://zy-eclass.bit.edu.cn/course/42/learning-activity/full-screen#/23")

        app = configureApp(resetStorage: false)
        tapHeader(app.sectionTab("空教室"))
        assertUI(textElement("B101").appears(timeout: 5), "同日重新打开应展示已缓存的教室。")
        tap("刷新")
        assertUI(app.alerts["空教室同步失败"].appears(timeout: 5), "手动刷新应呈现学校服务的失败。")
        closeAlertIfPresent()
        assertUI(textElement("B101").exists, "刷新失败应保留当天可用结果。")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "节次筛选")).firstMatch.press(
            forDuration: 0.01)
        assertUI(app.navigationBars["节次筛选"].appears(timeout: 5), "空教室应支持节次筛选。")
        tap("全选")
        assertUI(app.buttons["全不选"].exists, "全选应更新批量操作。")
        tap("全不选")
        assertUI(app.buttons["全选"].exists, "全不选应清空选择。")
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1节"))
            .firstMatch
        option.tapBriefly()
        waitForValue("已选择", of: option)
        assertUI(option.value as? String == "已选择", "单选应更新选择状态。")
        back()
        assertUI(textElement("B101").appears(timeout: 5), "节次筛选应沿本地缓存完成。")
        tap("节次筛选")
        option.tapBriefly()
        assertUI(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1节")).firstMatch.value
                as? String == "未选择", "清除应同步到选择页。")
        back()
    }

    @MainActor
    @objc func testCourseAndExamSystemCalendarActions() {
        app = configureApp(resetStorage: true, school: true)
        tap("学校测试课程")
        for (action, result) in [
            ("导入这节课到日历", "已导入系统日历"), ("移除这节课日历事件", "已移除系统日历事件"),
            ("导入这门课到日历", "已导入系统日历"), ("移除这门课日历事件", "已移除系统日历事件"),
            ("移除这门课日历事件", "无需移除"),
        ] {
            tap(action)
            assertUI(app.alerts[result].appears(timeout: 5), "日历动作应展示对应结果：\(action)。")
            closeAlertIfPresent()
        }
        app.buttons["调这节课"].press(forDuration: 0.01)
        assertUI(app.navigationBars["调这节课"].appears(timeout: 5), "单节调整入口应打开对应课节编辑页。")
        choose("楼宇", option: "文萃楼B")
        replaceText("202", in: app.textFields["房间号"])
        dismissKeyboard()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "周次")).firstMatch
            .tapBriefly()
        assertUI(app.navigationBars["周次"].appears(timeout: 5), "周次入口应完成页面导航。")
        assertUI(app.buttons["第4周"].exists == false, "课节周次应沿用原课程覆盖范围。")
        tap("第2周")
        app.navigationBars["周次"].buttons["完成"].tapBriefly()
        assertUI(app.navigationBars["调这节课"].appears(timeout: 5), "周次完成应返回课程调整。")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "星期")).firstMatch
            .tapBriefly()
        assertUI(app.navigationBars["星期"].appears(timeout: 5), "星期入口应完成页面导航。")
        tap("周二")
        assertUI(app.navigationBars["调这节课"].appears(timeout: 5), "选择星期应返回课程调整。")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "节次")).firstMatch
            .tapBriefly()
        assertUI(app.navigationBars["节次"].appears(timeout: 5), "节次入口应完成页面导航。")
        for section in [1, 2] {
            let option = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "第\(section)节")
            ).firstMatch
            option.tapBriefly()
            assertUI(option.value as? String == "未选择", "逐项清空应保留空选择状态。")
        }
        tap("第3节")
        app.navigationBars["节次"].buttons["完成"].tapBriefly()
        assertUI(app.navigationBars["调这节课"].appears(timeout: 5), "节次完成应返回课程调整。")
        tap("确定")
        tap("取消")
        assertUI(app.buttons["schedule.add-content"].appears(timeout: 5), "保存单节调整后关闭详情应返回课表。")
        tap("学校测试课程")
        tap("调这门课")
        assertUI(app.navigationBars["调这门课"].appears(timeout: 5), "整门调整入口应打开对应课程编辑页。")
        replaceText("303", in: app.textFields["地点"])
        dismissKeyboard()
        tap("确定")
        tap("取消")
        tap("学校测试课程")
        assertUI(textElement("303").appears(timeout: 5), "整门调课应保存地点。")
        tap("删除这节课")
        app.alerts.buttons["取消"].tapBriefly()
        assertUI(app.buttons["删除这节课"].exists, "取消应保留课节。")
        tap("删除这节课")
        app.alerts.buttons["删除"].tapBriefly()
        assertUI(app.navigationBars["课程详情"].disappears(timeout: 5), "删除单节后应关闭课程详情。")
        assertUI(app.buttons["schedule.add-content"].appears(timeout: 5), "删除单节后应恢复课表入口。")
        tap("下一周")
        tap("下一周")
        assertSelectedWeek(3)
        assertUI(textElement("学校测试课程").appears(timeout: 5), "删除单节应保留其余周次。")
        tap("第1周")
        let exam = app.buttons["schedule.entry.exam-ui-exam"]
        reveal(exam, description: "测试考试")
        exam.tapBriefly()
        tap("导入考试到日历")
        assertUI(app.alerts["已导入系统日历"].appears(timeout: 5), "考试应支持日历导入。")
        closeAlertIfPresent()
        tap("移除考试日历事件")
        assertUI(app.alerts["已移除系统日历事件"].appears(timeout: 5), "考试应支持日历移除。")
        closeAlertIfPresent()
        tap("取消")
        openSettings("calendar")
        tap("导入到系统日历")
        assertUI(app.alerts["导入当前学期到系统日历？"].appears(timeout: 5), "整学期导入应请求确认。")
        app.alerts.buttons["取消"].tapBriefly()
        tap("导入到系统日历")
        app.alerts.buttons["导入并替换本学期旧事件"].tapBriefly()
        assertUI(app.alerts["导入成功"].appears(timeout: 5), "整学期导入确认应展示成功结果。")
        closeAlertIfPresent()
        tap("删除已导入的日历")
        assertUI(app.alerts["删除 BIT101 导入的日历事件？"].appears(timeout: 5), "整学期移除应请求确认。")
        app.alerts.buttons["取消"].tapBriefly()
        tap("删除已导入的日历")
        app.alerts.buttons["删除"].tapBriefly()
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "整学期移除应展示结果。")
        closeAlertIfPresent()
    }

    @MainActor
    @objc func testCustomScheduleEmptyTitleDetails() {
        app = configureApp(resetStorage: true, initialSettings: "calendar")
        choose("时间轴", option: "线性")
        back()
        app.mainTab("日程").tapBriefly()
        app.buttons["schedule.add-content"].tapBriefly()
        tap("添加日程")
        tap("确定")
        assertUI(app.alerts["保存失败"].appears(timeout: 5), "空标题应展示保存校验提示。")
        assertUI(textElement("请填写日程标题。").exists, "校验提示应说明标题必填。")
        closeAlertIfPresent()
        assertUI(app.textFields["schedule.custom.title"].exists, "关闭校验提示应保留编辑草稿。")
        replaceText("待编辑日程", in: app.textFields["schedule.custom.title"])
        dismissKeyboard()
        tap("确定")
        let created = app.buttons["自定义日程，待编辑日程"]
        assertUI(created.appears(timeout: 5), "填写标题后应创建日程。")
        created.tapBriefly()
        tap("编辑")
        for identifier in ["schedule.custom.date", "schedule.custom.end", "schedule.custom.begin"] {
            openAndDismissDatePicker(identifier, coverage: .integration)
        }
        replaceText("详细测试日程", in: app.textFields["schedule.custom.title"])
        replaceText("测试地点", in: app.textFields["schedule.custom.subtitle"])
        replaceText("测试描述", in: app.textFields["schedule.custom.details"])
        dismissKeyboard()
        tap("确定")
        assertUI(app.buttons["自定义日程，详细测试日程"].appears(timeout: 5), "保存编辑应更新课表中的日程标题。")
        app = configureApp(resetStorage: false, restartProcess: true)
        tap("自定义日程，详细测试日程")
        assertUI(textElement("测试地点").exists, "重新装载应恢复日程地点。")
        assertUI(textElement("测试描述").appears(timeout: 5), "详情应恢复描述。")
        tap("导入到系统日历")
        assertUI(app.alerts["已导入系统日历"].appears(timeout: 5), "自定义日程应支持日历导入。")
        closeAlertIfPresent()
        tap("移除日历事件")
        assertUI(app.alerts["已移除系统日历事件"].appears(timeout: 5), "自定义日程应支持日历移除。")
        closeAlertIfPresent()
        tap("编辑")
        replaceText("取消的日程修改", in: app.textFields["schedule.custom.title"])
        dismissKeyboard()
        tap("取消")
        app.alerts["放弃当前输入？"].buttons["放弃输入"].tapBriefly()
        assertUI(app.navigationBars["修改自定义日程"].disappears(timeout: 5), "放弃修改应关闭编辑器。")
        assertUI(!textElement("取消的日程修改").exists, "取消编辑应保留已保存日程。")
        assertUI(textElement("详细测试日程").exists, "取消应恢复原日程标题。")
        tap("自定义日程，详细测试日程")
        tap("删除")
        assertUI(textElement("详细测试日程").disappears(timeout: 5), "删除应移除已保存日程。")
        app.buttons["schedule.add-content"].tapBriefly()
        tap("添加日程")
        tap("取消")
        assertUI(app.buttons["schedule.add-content"].exists, "取消新增应恢复课表。")
    }

}
