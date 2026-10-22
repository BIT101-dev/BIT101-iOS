import XCTest
import CoreGraphics

nonisolated final class CalendarInteractionUITests: UIAutomationTestCase {
    @MainActor
    @objc func testCalendarImportHistoryRecoveryKeepsImportAvailable() {
        app = configureApp(resetStorage: true, school: true, calendarHistoryRecovery: true, initialSettings: "calendar")
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
    @objc func testCalendarReminderCloudSwitchesAndLeadTimePersistence() {
        app = configureApp(resetStorage: true, animations: true, initialSettings: "calendar")
        let sync = toggle("iCloud 多端同步")
        let preferences = toggle("同步设置与使用偏好（实验性）")
        let reminderControl = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "显示灵动岛提醒（实验性）")).firstMatch
        let reminderSwitch = reminderControl.switches.firstMatch
        reveal(reminderSwitch)
        reminderSwitch.tap()
        assertUI(app.alerts["实验性功能提醒"].appears(timeout: 5), "提醒开关应展示实验功能确认。")
        app.alerts["实验性功能提醒"].buttons["取消"].tapBriefly()
        waitForValue("0", of: reminderControl)
        assertUI(app.alerts["实验性功能提醒"].disappears(timeout: 5), "取消应关闭实验功能确认。")
        assertUI(waitUntil(NSPredicate(format: "hittable == true"), on: reminderSwitch), "取消后提醒开关应恢复交互。")
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
            let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            reveal(control)
            waitForValue(value, of: control)
        }
        let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "显示灵动岛提醒（实验性）")).firstMatch
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
            let preferencesControl = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "同步设置与使用偏好（实验性）")).firstMatch
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
    @objc func testSchoolTermsClassroomPickersRefreshAndDDLRefresh() {
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
        let chosenValues = (try? app.datePickers.firstMatch.snapshot())?.snapshots(matching: .pickerWheel)
            .compactMap { ($0.value as? String).flatMap { Int($0.filter(\.isNumber)) } } ?? []
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(secondsFromGMT: 8 * 3600) else {
            assertUI(false, "日期验收应创建学校所在时区。")
            return
        }
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        guard chosenValues.count == 3,
              let chosenDate = calendar.date(from: DateComponents(year: chosenValues[0], month: chosenValues[1], day: chosenValues[2])),
              let monday = calendar.dateInterval(of: .weekOfYear, for: chosenDate)?.start else {
            assertUI(false, "日期滚轮应提供可计算首周周一的完整日期。")
            return
        }
        let savedValues = ["\(calendar.component(.year, from: monday))年", "\(calendar.component(.month, from: monday))月",
                           "\(calendar.component(.day, from: monday))日"]
        tap("完成")
        app = configureApp(resetStorage: false, school: true, initialSettings: "calendar")
        tap("学期起始日期")
        let savedWheel = app.pickerWheels.element(boundBy: app.pickerWheels.count - 1)
        let actualValues = (try? app.datePickers.firstMatch.snapshot())?.snapshots(matching: .pickerWheel).compactMap { $0.value as? String }
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
        app.tabBars.buttons["日程"].tapBriefly()
        tapHeader(app.segmentedControls.buttons["空教室"])
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
        app.tabBars.buttons["日程"].tapBriefly()
        tapHeader(app.segmentedControls.buttons["DDL"])
        let assignment = app.staticTexts["课程中心测试作业"]
        reveal(assignment)
        assignment.tapBriefly()
        assertUI(textElement("刷新后的学校详情").appears(timeout: 5), "学校刷新应更新详情正文。")
        tap("取消")

        app = configureApp(resetStorage: false)
        tapHeader(app.segmentedControls.buttons["空教室"])
        assertUI(app.alerts["空教室同步失败"].appears(timeout: 5), "离线学校服务应提示刷新失败。")
        closeAlertIfPresent()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "节次筛选")).firstMatch.press(forDuration: 0.01)
        assertUI(app.navigationBars["节次筛选"].appears(timeout: 5), "空教室应支持节次筛选。")
        tap("全选")
        assertUI(app.buttons["全不选"].exists, "全选应更新批量操作。")
        tap("全不选")
        assertUI(app.buttons["全选"].exists, "全不选应清空选择。")
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1节")).firstMatch
        option.tapBriefly()
        waitForValue("已选择", of: option)
        assertUI(option.value as? String == "已选择", "单选应更新选择状态。")
        back()
        assertUI(app.alerts["空教室同步失败"].appears(timeout: 5), "筛选更新应完成离线刷新并展示失败提示。")
        closeAlertIfPresent()
        tap("清除节次筛选")
        tap("刷新空教室")
        assertUI(app.alerts["空教室同步失败"].appears(timeout: 5), "离线刷新应展示对应失败提示。")
        closeAlertIfPresent()
        tap("节次筛选")
        assertUI(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1节")).firstMatch.value as? String == "未选择", "清除应同步到选择页。")
        back()
    }


    @MainActor
    @objc func testCourseAndExamSystemCalendarActions() {
        app = configureApp(resetStorage: true, school: true)
        tap("学校测试课程")
        for (action, result) in [("导入这节课到日历", "已导入系统日历"), ("移除这节课日历事件", "已移除系统日历事件"),
                                 ("导入这门课到日历", "已导入系统日历"), ("移除这门课日历事件", "已移除系统日历事件"),
                                 ("移除这门课日历事件", "无需移除")] {
            tap(action)
            assertUI(app.alerts[result].appears(timeout: 5), "日历动作应展示对应结果：\(action)。")
            closeAlertIfPresent()
        }
        app.buttons["调这节课"].press(forDuration: 0.01)
        assertUI(app.navigationBars["调这节课"].appears(timeout: 5), "单节调整入口应打开对应课节编辑页。")
        choose("楼宇", option: "文萃楼B")
        replaceText("202", in: app.textFields["房间号"])
        dismissKeyboard()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "周次")).firstMatch.tapBriefly()
        assertUI(app.navigationBars["周次"].appears(timeout: 5), "周次入口应完成页面导航。")
        assertUI(app.buttons["第4周"].exists == false, "课节周次应沿用原课程覆盖范围。")
        tap("第2周")
        app.navigationBars["周次"].buttons["完成"].tapBriefly()
        assertUI(app.navigationBars["调这节课"].appears(timeout: 5), "周次完成应返回课程调整。")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "星期")).firstMatch.tapBriefly()
        assertUI(app.navigationBars["星期"].appears(timeout: 5), "星期入口应完成页面导航。")
        tap("周二")
        assertUI(app.navigationBars["调这节课"].appears(timeout: 5), "选择星期应返回课程调整。")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "节次")).firstMatch.tapBriefly()
        assertUI(app.navigationBars["节次"].appears(timeout: 5), "节次入口应完成页面导航。")
        for section in [1, 2] {
            let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第\(section)节")).firstMatch
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
        replaceText("303", in: app.textFields["房间号"])
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
    @objc func testCustomScheduleEmptyTitleDetailsAndCalendarActions() {
        app = configureApp(resetStorage: true, initialSettings: "calendar")
        choose("时间轴", option: "线性")
        back()
        app.tabBars.buttons["日程"].tapBriefly()
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

nonisolated final class ScoreInteractionUITests: UIAutomationTestCase {
    @MainActor
    @objc func testScoreIndividualFiltersRefreshCancelAndPendingDetail() {
        app = configureApp(resetStorage: true, content: true, animations: true, school: true, initialTab: "home")
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
        reveal(manualRetry, description: "短信验证重试")
        assertUI(waitUntil(NSPredicate(format: "enabled == true"), on: manualRetry),
                 "自动验证错误后应恢复手动重试。")
        fillVerificationCode("１２٣٤５６", in: app.textFields["verification.code"])
        assertUI(textElement("自动化测试课程").appears(timeout: 5), "替换完整验证码应自动验证并加载成绩。")
        for (route, option) in [("学期", "ui-test-term"), ("种类", "必修")] {
            openScoreFilter(route)
            if route == "学期" {
                tap("全不选")
                assertUI(app.buttons["全选"].exists, "公共筛选页批量清空应恢复全选操作。")
                tap("全选")
            }
            let item = app.buttons.matching(NSPredicate(format: "label == %@", option)).firstMatch
            assertUI(item.appears(timeout: 5), "筛选页应加载\(option)选项。")
            item.tapBriefly()
            waitForValue("未选", of: item)
            back()
            assertUI(app.navigationBars["\(route)筛选"].disappears(timeout: 5), "返回应关闭\(route)筛选页。")
            assertUI(app.staticTexts["当前筛选条件下暂无成绩。"].appears(timeout: 5), "取消单项选择应过滤成绩。")
            openScoreFilter(route)
            assertUI(item.appears(timeout: 5), "重新打开应恢复\(option)筛选项。")
            item.tapBriefly()
            waitForValue("已选", of: item)
            back()
            assertUI(app.navigationBars["\(route)筛选"].disappears(timeout: 5), "选择后返回应恢复成绩页。")
        }
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "排序")).firstMatch.tapBriefly()
        assertUI(app.navigationBars["成绩排序"].appears(timeout: 5), "排序入口应完成页面导航。")
        for title in ["名称", "成绩", "均分", "学分", "学期", "种类"] {
            let index = app.collectionViews.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
            reveal(index, description: title)
            index.tapBriefly()
            assertUI(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND selected == true", title)).firstMatch.exists,
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
        assertUI(waitUntil(NSPredicate(format: "selected == true"), on: app.segmentedControls.buttons["课程"]),
                 "成绩详情应进入课程搜索。")
    }

    @MainActor
    private func openScoreFilter(_ title: String) {
        let route = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title)、")).firstMatch
        reveal(route, description: "\(title)筛选")
        route.tapBriefly()
        assertUI(app.navigationBars["\(title)筛选"].appears(timeout: 5), "筛选入口应打开\(title)选择页。")
    }

    @MainActor
    @objc func testScoreStorageRecoveryConfirmationAndPersistence() {
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
    @objc func testTrustedTranscriptSMSRetryPreviewAndCancellation() throws {
        app = configureApp(resetStorage: true, animations: true, transcriptFailureOnce: true, initialTab: "home")
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
                      let page = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Int] else { return false }
                return page["count"] == 2 && page["index"] == index
            }
            assertUI(waitUntil(pageReady, on: app), "预览应展示两页成绩单中的第 \(index + 1) 页。")
        }
        try assertPreviewPage(0)
        app.swipeLeft()
        try assertPreviewPage(1)
        app.swipeRight()
        try assertPreviewPage(0)
        closeImagePreview()
        assertUI(app.navigationBars["可信成绩单"].appears(timeout: 5), "关闭预览应返回成绩单。")
        reveal(app.buttons["可信成绩单第2页"])
        app.buttons["可信成绩单第2页"].tapBriefly()
        _ = imagePreviewCloseButton()
        try assertPreviewPage(1)
        closeImagePreview()
    }


}

nonisolated final class InteractionCoverageUITests: UIAutomationTestCase {
    @MainActor
    @objc func testSettingsRecoveryPreservesScheduleAndAccount() {
        app = configureApp(resetStorage: true, content: true)
        addCustomSchedule("设置恢复保留日程", in: app)
        app = configureApp(resetStorage: false, content: true, settingsRecovery: true, initialSettings: "gallery")
        tap("settings.storage.recover")
        let dialog = app.alerts["恢复当前账号的设置？"]
        let cancel = dialog.buttons["取消"]
        assertUI(cancel.appears(timeout: 5), "恢复设置应提供确认与取消操作。")
        cancel.tapBriefly()
        assertUI(cancel.disappears(timeout: 5), "取消后应返回原设置页面。")
        assertUI(app.buttons["settings.storage.recover"].exists, "取消恢复后应保留账号设置的恢复入口。")
        tap("settings.storage.recover")
        let confirm = dialog.buttons["恢复账号设置"]
        assertUI(confirm.appears(timeout: 5), "再次恢复应展示原生确认操作。")
        confirm.tapBriefly()
        assertUI(app.buttons["settings.storage.recover"].disappears(timeout: 5), "恢复后应继续保存设置。")
        if let coverage = UITestControlClient.request(["command": "coverage"]),
           let inventory = try? JSONSerialization.jsonObject(with: Data(coverage.utf8)) as? [String: Any],
           let observed = inventory["observedControls"] as? [String] {
            let confirmations = observed.filter { $0.contains("恢复当前账号的设置？") && $0.contains("settings.storage.confirm-recovery") }
            XCTAssertEqual(confirmations.count, 2, "两次确认框应各捕获一个恢复按钮。")
        } else { XCTFail("恢复操作应提供控件观察证据。") }
        let value = toggle("隐藏机器人帖子")
        app = configureApp(resetStorage: false, content: true, initialSettings: "gallery")
        let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "隐藏机器人帖子")).firstMatch
        reveal(control)
        waitForValue(value, of: control)
        back()
        app.tabBars.buttons["日程"].tapBriefly()
        assertUI(textElement("设置恢复保留日程").appears(timeout: 5), "恢复设置后应保留登录账号与原日程。")
    }

    @MainActor
    @objc func testCommunityCommentLikesRepliesSortsAndPhotoPicker() {
        app = configureApp(resetStorage: true, content: true, initialTab: "gallery")
        tap("自动化测试话题")
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "话题应打开详情。")
        tap("点赞帖子")
        assertUI(app.buttons["取消帖子点赞"].appears(timeout: 5), "点赞应更新操作状态。")
        tap("取消帖子点赞")
        tap("评论帖子")
        let field = app.textFields.firstMatch
        field.tapBriefly()
        field.typeText("测试新增评论\n")
        dismissKeyboard()
        tap("发送")
        assertUI(textElement("测试新增评论").appears(timeout: 5), "发送后应显示评论。")
        tap("编辑帖子")
        assertUI(app.buttons["测试"].appears(timeout: 5) && app.buttons["自动化"].exists, "编辑应显示帖子原有的自定义标签。")
        tap("测试")
        tap("自动化")
        tap("水")
        tap("自定义")
        replaceText("讲座", in: app.textFields["自定义标签"])
        dismissKeyboard()
        replaceText("保存后的测试话题", in: app.textFields["标题"])
        replaceText("保存后的话题正文", in: app.textFields["正文"])
        dismissKeyboard()
        choose("声明", option: "日常")
        tap("保存")
        assertUI(textElement("保存后的测试话题").appears(timeout: 5), "保存应刷新详情标题。")
        assertUI(textElement("保存后的话题正文").exists, "保存应刷新正文。")
        tap("编辑帖子")
        assertUI(app.buttons["讲座"].appears(timeout: 5), "保存后的自定义标签应继续可编辑。")
        assertUI(!app.buttons["测试"].exists && !app.buttons["自动化"].exists, "移除的旧标签应随保存更新。")
        tap("讲座")
        tap("活动")
        tap("保存")
        for title in ["最新", "高赞", "最旧"] {
            tap("排序")
            tap(title)
            assertUI(textElement("自动化测试评论").appears(timeout: 5), "评论排序应保留服务结果。")
        }
        tap("点赞评论")
        assertUI(app.buttons["取消评论点赞"].appears(timeout: 5), "评论点赞应更新状态。")
        tap("取消评论点赞")
        tap("回复")
        tap("添加评论图片")
        cancelPhotoPicker()
        replaceText("自动化回复内容", in: app.textFields.firstMatch)
        dismissKeyboard()
        tap("发送")
        assertUI(textElement("自动化回复内容").appears(timeout: 5), "回复发送应更新评论。")
        let comment = app.staticTexts["自动化测试评论"]
        reveal(comment, description: "自动化测试评论")
        comment.press(forDuration: 1)
        tap("复制评论")
        comment.press(forDuration: 1)
        tap("举报评论")
        assertUI(app.textFields["请描述举报原因"].appears(timeout: 5), "举报应展示说明字段。")
        replaceText("测试举报说明", in: app.textFields["请描述举报原因"])
        dismissKeyboard()
        tap("提交举报")
        assertUI(app.alerts["举报已提交"].appears(timeout: 5), "举报提交应展示成功结果。")
        app.alerts.buttons["知道了"].tapBriefly()
        comment.press(forDuration: 1)
        tap("删除评论")
        app.alerts.buttons["取消"].tapBriefly()
        assertUI(comment.exists, "取消删除应保留评论。")
        comment.press(forDuration: 1)
        tap("删除评论")
        app.alerts.buttons["删除"].tapBriefly()
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: comment, timeout: 5), "确认删除应移除评论。")
    }

    @MainActor
    @objc func testBotFeedContinuesAcrossEmptyScanBatches() {
        app = configureApp(resetStorage: true, content: true, botPaging: true, initialTab: "gallery")
        tapHeader(app.segmentedControls.buttons["机器人"])
        let continuation = app.buttons["community.pagination.retry"]
        continuation.tapBriefly()
        assertUI(waitUntil(NSPredicate(format: "exists == true"), on: continuation), "空批完成后应恢复继续查询入口。")
        assertUI(textElement("机器人分页话题").exists == false, "首批续页保持空状态和继续入口。")
        continuation.tapBriefly()
        assertUI(textElement("机器人分页话题").appears(timeout: 5), "继续查询应展示后续源页中的机器人帖子。")
    }

    @MainActor
    @objc func testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes() {
        app = configureApp(resetStorage: true, content: true, initialTab: "gallery")
        assertUI(!app.segmentedControls.buttons["机器人"].exists, "隐藏机器人时顶部分栏应同步隐藏。")
        openSettings("gallery")
        _ = toggle("隐藏机器人帖子")
        back()
        app.tabBars.buttons["话廊"].tapBriefly()
        for title in ["关注", "最新", "最热", "机器人", "推荐"] {
            tapHeader(app.segmentedControls.buttons[title])
            assertUI(app.segmentedControls.buttons[title].isSelected, "话题分类应选中：\(title)。")
        }
        tapHeader(app.segmentedControls.buttons["机器人"])
        openSettings("gallery")
        _ = toggle("隐藏机器人帖子")
        back()
        app.tabBars.buttons["话廊"].tapBriefly()
        assertUI(!app.segmentedControls.buttons["机器人"].exists && app.segmentedControls.buttons["推荐"].isSelected,
                 "隐藏当前机器人分栏应选中推荐。")
        pullToRefresh()
        assertUI(textElement("自动化测试话题").exists, "话题列表刷新应保留服务结果。")
        assertUI(app.segmentedControls.buttons["推荐"].isSelected, "竖向刷新应保留话题分类。")
        let feed = app.descendants(matching: .any)["gallery.feed-surface"]
        feed.swipeLeft()
        assertUI(app.segmentedControls.buttons["最新"].isSelected, "话题横滑应切换分类。")
        feed.swipeRight()
        assertUI(app.segmentedControls.buttons["推荐"].isSelected, "反向横滑应恢复分类。")
        tap("消息")
        assertUI(textElement("自动化测试消息").appears(timeout: 5), "消息面板应完成首屏加载。")
        pullToRefresh()
        assertUI(textElement("自动化测试消息").exists, "消息刷新应保留服务结果。")
        app.descendants(matching: .any)["gallery.message-surface"].swipeLeft()
        let likes = app.segmentedControls.buttons.matching(NSPredicate(format: "label CONTAINS %@", "点赞")).firstMatch
        assertUI(likes.isSelected, "消息横滑应切换到点赞分类。")
        app.descendants(matching: .any)["gallery.message-surface"].swipeRight()
        let comments = app.segmentedControls.buttons.matching(NSPredicate(format: "label CONTAINS %@", "评论")).firstMatch
        assertUI(comments.isSelected, "消息反向横滑应恢复评论分类。")
        let message = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "自动化测试消息")).firstMatch
        reveal(message)
        message.tapBriefly()
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "消息行应打开关联帖子。")
        pullToRefresh()
        assertUI(textElement("自动化测试话题正文").exists, "帖子详情刷新应恢复正文。")
        back()
        for title in ["评论", "点赞", "关注", "系统"] {
            let segment = app.segmentedControls.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            segment.tapBriefly()
            assertUI(segment.isSelected, "消息分类应选中：\(title)。")
        }
        tap("全部已读")
        tap("取消")
        tap("搜索话廊")
        let gallerySearch = app.textFields.firstMatch
        replaceText("测试\n", in: gallerySearch)
        var selected = "最新"
        for option in ["相似", "高赞", "最新"] {
            tapSearchSort(selected)
            tap(option)
            selected = option
            assertUI(textElement("自动化测试话题").appears(timeout: 5), "话廊搜索排序应恢复结果。")
        }
        pullToRefresh()
        tap("自动化测试话题")
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "搜索结果应打开详情。")
        back()
        tap("清除搜索")
        assertUI(gallerySearch.value as? String != "测试", "清除应重置话廊搜索词。")
        tap("取消")
        tapHeader(app.segmentedControls.buttons["文章"])
        pullToRefresh()
        assertUI(textElement("自动化测试文章").exists, "文章列表刷新应恢复数据。")
        for title in ["最新", "高赞", "热评"] {
            tapHeader(app.segmentedControls.buttons[title])
            assertUI(app.segmentedControls.buttons[title].isSelected, "文章排序应更新选中项。")
        }
        tapHeader(app.segmentedControls.buttons["最新"])
        let paper = app.descendants(matching: .any)["paper.sort-surface"]
        paper.swipeLeft()
        assertUI(app.segmentedControls.buttons["高赞"].isSelected, "文章横滑应切换点赞排序。")
        paper.swipeLeft()
        assertUI(app.segmentedControls.buttons["热评"].isSelected, "连续横滑应切换评论排序。")
        paper.swipeRight()
        assertUI(app.segmentedControls.buttons["高赞"].isSelected, "反向横滑应恢复文章排序。")
        paper.swipeRight()
        assertUI(app.segmentedControls.buttons["最新"].isSelected, "反向横滑应返回首个文章排序。")
        paper.swipeRight()
        assertUI(app.segmentedControls.buttons["话题"].isSelected, "文章首个排序向外横滑应切换话题。")
        tapHeader(app.segmentedControls.buttons["关注"])
        feed.swipeRight()
        assertUI(app.segmentedControls.buttons["文章"].isSelected, "话题首个分类向外横滑应切换文章。")
        tapHeader(app.segmentedControls.buttons["热评"])
        paper.swipeLeft()
        assertUI(app.segmentedControls.buttons["话题"].isSelected, "文章末尾排序向外横滑应切换话题。")
        tapHeader(app.segmentedControls.buttons["最热"])
        feed.swipeLeft()
        assertUI(app.segmentedControls.buttons["文章"].isSelected, "话题末尾分类向外横滑应切换文章。")
        tap("搜索文章")
        let paperSearch = app.textFields.firstMatch
        replaceText("文章\n", in: paperSearch)
        selected = "最新"
        for option in ["高赞", "热评", "最新"] {
            tapSearchSort(selected)
            tap(option)
            selected = option
            assertUI(textElement("自动化测试文章").appears(timeout: 5), "文章搜索排序应恢复结果。")
        }
        pullToRefresh()
        assertUI(textElement("自动化测试文章").exists, "文章搜索刷新应保留匹配结果。")
        tap("自动化测试文章")
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5), "文章搜索结果应打开详情。")
        pullToRefresh()
        assertUI(textElement("自动化测试文章正文").exists, "文章详情刷新应恢复正文。")
        back()
        tap("清除搜索")
        assertUI(paperSearch.value as? String != "文章", "清除应重置文章搜索词。")
        tap("取消")
    }

    @MainActor
    @objc func testAccountProfileSaveLoginCheckAndLogout() {
        app = configureApp(resetStorage: true, content: true, initialTab: "mine")
        assertUI(textElement("自动化测试用户").appears(timeout: 5), "个人主页应先完成资料加载。")
        openSettings("account")
        let student = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "学号")).firstMatch
        assertUI(student.appears(timeout: 5), "固定账号应提供学号显示开关。")
        assertUI(student.value as? String == "已隐藏", "账号标识默认隐藏。")
        student.tapBriefly()
        waitForValue("ui-test-student", of: student)
        assertUI(student.value as? String == "ui-test-student", "点击后应显示当前账号。")
        student.tapBriefly()
        waitForValue("已隐藏", of: student)
        assertUI(student.value as? String == "已隐藏", "再次点击应隐藏账号。")
        tap("UID")
        let uid = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UID")).firstMatch
        waitForValue("1", of: uid)
        assertUI(uid.value as? String == "1", "UID 显示应使用当前资料。")
        tap("UID")
        for title in ["昵称", "个性签名"] {
            tap(title)
            assertUI(app.navigationBars["修改\(title)"].appears(timeout: 5), "资料字段应打开编辑窗口。")
            assertUI(app.textFields.firstMatch.exists, "编辑窗口应提供文本输入。")
            tap("取消")
        }
        tap("头像")
        cancelPhotoPicker()
        for (route, value) in [("昵称", "保存后的昵称"), ("个性签名", "保存后的签名")] {
            tap(route)
            replaceText(value, in: app.textFields.firstMatch)
            dismissKeyboard()
            tap("确定")
            assertUI(textElement(value).appears(timeout: 5), "资料提交应重新加载保存的值。")
        }
        back()
        assertUI(textElement("保存后的昵称").appears(timeout: 5) && textElement("保存后的签名").exists,
                 "设置保存后返回主页应更新资料卡。")
        pullToRefresh()
        assertUI(textElement("保存后的昵称").exists, "主页下拉刷新应保留已保存资料。")
        openSettings("account")
        tap("settings.account.school-password")
        assertUI(app.secureTextFields["school.credentials.password"].appears(timeout: 5), "学校认证应使用安全密码输入框。")
        app.alerts["学校统一身份认证"].buttons["保存并继续"].assertDisabled("学校密码填写后可保存。")
        replaceText("cancelled-school-password", in: app.secureTextFields["school.credentials.password"])
        app.alerts["学校统一身份认证"].buttons["取消"].tapBriefly()
        tap("学校统一身份认证密码")
        replaceText("school-password", in: app.secureTextFields["school.credentials.password"])
        app.alerts["学校统一身份认证"].buttons["保存并继续"].tapBriefly()
        assertUI(app.alerts["学校密码已保存"].appears(timeout: 5), "学校密码保存应保留当前账号页面。")
        app.alerts["学校密码已保存"].buttons.firstMatch.tapBriefly()
        tap("登录状态检查")
        assertUI(textElement("已登录").appears(timeout: 5), "登录检查应保留有效测试会话。")
        tap("退出登录")
        assertUI(app.textFields["login.student-id"].appears(timeout: 5), "退出应返回登录页。")
        signIn(app)
        assertUI(app.buttons["schedule.add-content"].appears(timeout: 5), "退出后应支持重新登录。")
    }

    @MainActor
    @objc func testSuggestionMissingContactConfirmationAndSubmitFailure() {
        app = configureApp(resetStorage: true)
        openSettings("suggestion")
        tap("插入图片")
        cancelPhotoPicker()
        replaceText("测试提交建议", in: app.textFields["建议内容"])
        dismissKeyboard()
        tap("提交")
        assertUI(app.alerts["你没有填写联系方式"].appears(timeout: 5), "缺少联系信息应展示提交确认。")
        tap("返回补充")
        assertUI(app.textFields["联系方式"].exists, "返回补充应恢复联系方式输入。")
        dismissKeyboard()
        tap("提交")
        tap("继续提交")
        assertUI(app.alerts["提交失败"].appears(timeout: 10), "离线提交应提供失败结果。")
        closeAlertIfPresent()
        assertUI(app.textFields["建议内容"].value as? String == "测试提交建议", "失败应保留建议内容。")
        tap("取消")
        tap("不保存")
    }

    @MainActor
    @objc func testCacheLimitPersistenceClearAndConfirmedReset() {
        app = configureApp(resetStorage: true)
        addCustomSchedule("重置测试日程", in: app)
        openSettings("gallery")
        replaceText("64", in: app.textFields["缓存上限"])
        dismissKeyboard()
        app = configureApp(resetStorage: false, initialSettings: "gallery")
        let limit = app.textFields["缓存上限"]
        reveal(limit)
        waitForValue("64", of: limit)
        back()
        openSettings("about")
        tap("清理缓存")
        assertUI(app.alerts["清理完成"].appears(timeout: 5), "缓存清理应展示结果。")
        closeAlertIfPresent()
        tap("删除所有文稿与数据")
        app.alerts.buttons["删除"].tapBriefly()
        assertUI(app.textFields["login.student-id"].appears(timeout: 10), "确认重置应返回登录页。")
        signIn(app)
        assertUI(!textElement("重置测试日程").exists, "重置应移除隔离账号日程。")
    }

    @MainActor
    @objc func testCommunityMediaPreviewsDraftRetryAndRemoval() {
        app = configureApp(resetStorage: true, content: true, animations: true, media: true, initialTab: "gallery")
        tapImage("查看第1张图片")
        let preview = app.otherElements["QLPreviewControllerView"]
        assertUI(preview.appears(timeout: 30), "卡片图片应进入系统 Quick Look。")
        app = configureApp(resetStorage: false, content: true, animations: true, media: true, initialTab: "gallery")
        assertUI(preview.disappears(timeout: 5), "场景切换应清理系统图片预览并恢复原进程页面。")
        tap("自动化测试话题")
        tapImage("图片 1")
        closeImagePreview()
        tapImage("查看第1张图片")
        closeImagePreview()
        tap("编辑帖子")
        tap("移除原有图片")
        assertUI(!app.buttons["移除原有图片"].exists, "编辑应移除原有图片条目。")
        tap("取消")
        assertUI(app.navigationBars["编辑帖子"].native.disappears(timeout: 5), "取消编辑应完成编辑弹窗关闭。")
        assertUI(app.buttons["图片 1"].appears(timeout: 5), "取消编辑应保留详情原图。")
        back()
        tap("发布话题")
        tap("加载草稿")
        tap("重试")
        assertUI(app.buttons["重试"].appears(timeout: 5), "首次上传失败应保留重试入口。")
        tap("重试")
        assertUI(textElement("已上传").appears(timeout: 5), "第二次上传应更新图片状态。")
        tap("移除图片")
        assertUI(!textElement("已上传").exists, "移除应清空图片条目。")
        tap("插入图片")
        cancelPhotoPicker()
        tap("取消")
        tap("不保存")
        assertUI(app.navigationBars["发布帖子"].disappears(timeout: 5), "放弃话题草稿应关闭编辑器。")
        openSettings("suggestion")
        tap("加载草稿")
        tap("移除图片")
        assertUI(!app.buttons["移除图片"].exists, "建议草稿应支持移除图片。")
        tap("取消")
        tap("不保存")
        assertUI(app.buttons["settings.route.suggestion"].appears(timeout: 5), "放弃建议草稿应返回个人设置入口。")
    }

    @MainActor
    private func cancelPhotoPicker() {
        dismissNotificationBanner()
        let platform = UIElement(app.native)
        let photos = platform.buttons.matching(NSPredicate(format: "label IN %@", ["照片", "Photos"])).firstMatch
        assertUI(photos.appears(timeout: 30), "图片入口应呈现系统照片选择器。")
        let cancel = platform.buttons.matching(identifier: "Cancel").firstMatch
        assertUI(cancel.appears(timeout: 5), "系统照片选择器应提供取消操作。")
        cancel.tap()
        assertUI(photos.disappears(timeout: 5), "取消图片选择应关闭系统选择器。")
    }


}

nonisolated final class MineInteractionUITests: UIAutomationTestCase {
    @MainActor
    @objc func testMinePublicProfileFollowAndPostDeletion() {
        app = configureApp(resetStorage: true, initialTab: "mine")
        assertUI(textElement("个人信息加载失败").appears(timeout: 5), "离线个人页应完成服务加载并展示恢复入口。")
        app = configureApp(resetStorage: true, content: true, media: true, minePagingFailureOnce: true, initialTab: "mine")
        func retryPageInPlace() {
            let failure = textElement("加载更多失败")
            reveal(failure, description: "分页恢复")
            assertUI(failure.appears(timeout: 5), "分页故障应展示原位重试。")
            tap("重试")
            assertUI(failure.disappears(timeout: 5), "重试应完成当前页并保留已加载内容。")
        }
        assertUI(textElement("自动化测试用户").appears(timeout: 5), "个人页应加载账号资料。")
        tap("粉丝")
        assertUI(app.navigationBars["我的粉丝"].appears(timeout: 5), "粉丝统计应打开粉丝列表。")
        retryPageInPlace()
        pullToRefresh()
        assertUI(textElement("自动化测试用户").exists, "粉丝刷新应恢复用户。")
        tap("自动化测试用户")
        assertUI(app.buttons["关注"].appears(timeout: 5), "粉丝用户行应进入公开主页。")
        retryPageInPlace()
        back()
        assertUI(app.navigationBars["我的粉丝"].appears(timeout: 5), "返回应恢复粉丝列表。")
        back()
        tap("关注")
        assertUI(app.navigationBars["我的关注"].appears(timeout: 5), "关注统计应打开关注列表。")
        retryPageInPlace()
        pullToRefresh()
        assertUI(textElement("自动化测试用户").exists, "关注刷新应恢复用户。")
        tap("自动化测试用户")
        tap("关注")
        let followed = app.buttons["取消关注"]
        assertUI(followed.appears(timeout: 5), "关注成功应展示已关注状态。")
        followed.tapBriefly(); assertUI(app.buttons["关注"].appears(timeout: 5), "再次点击应恢复关注入口。")
        tap("查看头像")
        let previewClose = imagePreviewCloseButton()
        app.native.descendants(matching: .any)["QLPreviewControllerView"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        UITestSnapshotReader.invalidate()
        assertUI(previewClose.disappears(timeout: 5), "点击预览画布应收起系统工具栏。")
        closeImagePreview()
        for route in ["粉丝", "关注", "帖子"] {
            assertUI(textElement(route).exists, "公开主页应显示\(route)统计。")
        }
        pullToRefresh()
        tap("自动化测试话题")
        let detail = app.navigationBars["帖子详情"]
        assertUI(detail.appears(timeout: 5), "公开主页帖子应打开详情。")
        dismissPosterSheet(returningTo: "自动化测试用户")
        back()
        assertUI(app.navigationBars["我的关注"].appears(timeout: 5), "返回应恢复关注列表。")
        back()
        tap("帖子")
        assertUI(app.navigationBars["我的帖子"].appears(timeout: 5), "帖子统计应打开帖子列表。")
        retryPageInPlace()
        pullToRefresh()
        assertUI(textElement("自动化测试话题").exists, "个人帖子刷新应恢复记录。")
        tap("自动化测试话题")
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "个人帖子行应打开详情。")
        dismissPosterSheet(returningTo: "我的帖子")
        tap("更多操作")
        tap("删除帖子")
        app.alerts.buttons["取消"].tapBriefly()
        tap("更多操作")
        tap("删除帖子")
        app.alerts.buttons["删除"].tapBriefly()
        let poster = textElement("自动化测试话题")
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: poster, timeout: 5), "个人列表删除应移除帖子。")
    }
}
