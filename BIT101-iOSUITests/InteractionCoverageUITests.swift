import XCTest
import CoreGraphics

nonisolated final class InteractionCoverageUITests: UIAutomationTestCase {
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
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
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
        tap("第2周")
        app.navigationBars["周次"].buttons["完成"].tapBriefly()
        assertUI(app.navigationBars["调这节课"].appears(timeout: 5), "周次完成应返回课程调整。")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "星期")).firstMatch.tapBriefly()
        assertUI(app.navigationBars["星期"].appears(timeout: 5), "星期入口应完成页面导航。")
        tap("周二")
        assertUI(app.navigationBars["调这节课"].appears(timeout: 5), "选择星期应返回课程调整。")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "节次")).firstMatch.tapBriefly()
        assertUI(app.navigationBars["节次"].appears(timeout: 5), "节次入口应完成页面导航。")
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
        let unnamed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "schedule.entry.custom-")).firstMatch
        assertUI(unnamed.appears(timeout: 5), "空标题应创建采用默认显示名称的日程。")
        unnamed.tapBriefly()
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
        app = configureApp(resetStorage: false)
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

    @MainActor
    @objc func testScoreIndividualFiltersRefreshCancelAndPendingDetail() {
        app = configureApp(resetStorage: true, content: true, animations: true, school: true, initialTab: "home")
        app.buttons["score.query"].tapBriefly()
        let code = app.textFields["verification.code"]
        assertUI(code.appears(timeout: 5), "成绩查询应打开短信验证。")
        assertUI(!app.buttons["验证并查询成绩"].isEnabled, "空验证码应禁用提交。")
        replaceTextWithKeyboard("000000", in: code)
        assertUI(code.value as? String == "000000", "逐位输入应保留完整验证码供手动验证。")
        dismissKeyboard()
        tap("验证并查询成绩")
        assertUI(app.staticTexts["测试验证码错误。"].appears(timeout: 5), "错误验证码应展示重试说明。")
        tap("取消")
        let retry = app.buttons["重新查询"]
        assertUI(retry.appears(timeout: 5) && retry.isEnabled, "取消短信应恢复重新查询入口。")
        retry.tapBriefly()
        fillVerificationCode("000000", in: app.textFields["verification.code"])
        assertUI(app.staticTexts["测试验证码错误。"].appears(timeout: 5), "完整错误验证码自动验证后应允许修改。")
        assertUI(app.buttons["验证并查询成绩"].isEnabled, "自动验证错误后应恢复手动重试。")
        fillVerificationCode("123456", in: app.textFields["verification.code"])
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
    @objc func testTrustedTranscriptSMSRetryPreviewAndCancellation() {
        app = configureApp(resetStorage: true, animations: true, initialTab: "home")
        tap("申请可信成绩单")
        tap("取消")
        tap("重试")
        let code = app.textFields["verification.code"]
        fillVerificationCode("123456", in: code)
        assertUI(code.disappears(timeout: 5), "验证成功应关闭短信输入窗口。")
        tap("可信成绩单第1页")
        _ = imagePreviewCloseButton()
        app.swipeLeft()
        app.swipeRight()
        closeImagePreview()
        assertUI(app.navigationBars["可信成绩单"].appears(timeout: 5), "关闭预览应返回成绩单。")
        reveal(app.buttons["可信成绩单第2页"])
        app.buttons["可信成绩单第2页"].tapBriefly()
        closeImagePreview()
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
        replaceText("保存后的测试话题", in: app.textFields["标题"])
        replaceText("保存后的话题正文", in: app.textFields["正文"])
        dismissKeyboard()
        choose("声明", option: "日常")
        tap("保存")
        assertUI(textElement("保存后的测试话题").appears(timeout: 5), "保存应刷新详情标题。")
        assertUI(textElement("保存后的话题正文").exists, "保存应刷新正文。")
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
    @objc func testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes() {
        app = configureApp(resetStorage: true, content: true, initialTab: "gallery")
        for title in ["关注", "最新", "最热", "机器人", "推荐"] {
            tapHeader(app.segmentedControls.buttons[title])
            assertUI(app.segmentedControls.buttons[title].isSelected, "话题分类应选中：\(title)。")
        }
        pullToRefresh()
        assertUI(textElement("自动化测试话题").exists, "话题列表刷新应保留服务结果。")
        assertUI(app.segmentedControls.buttons["推荐"].isSelected, "竖向刷新应保留话题分类。")
        let list = app.scrollViews.firstMatch
        list.swipeLeft()
        assertUI(app.segmentedControls.buttons["最新"].isSelected, "话题横滑应切换分类。")
        list.swipeRight()
        assertUI(app.segmentedControls.buttons["推荐"].isSelected, "反向横滑应恢复分类。")
        tap("消息")
        assertUI(textElement("自动化测试消息").appears(timeout: 5), "消息面板应完成首屏加载。")
        pullToRefresh()
        assertUI(textElement("自动化测试消息").exists, "消息刷新应保留服务结果。")
        app.collectionViews.firstMatch.swipeLeft()
        let likes = app.segmentedControls.buttons.matching(NSPredicate(format: "label CONTAINS %@", "点赞")).firstMatch
        assertUI(likes.isSelected, "消息横滑应切换到点赞分类。")
        app.collectionViews.firstMatch.swipeRight()
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
        list.swipeLeft()
        assertUI(app.segmentedControls.buttons["高赞"].isSelected, "文章横滑应切换点赞排序。")
        list.swipeLeft()
        assertUI(app.segmentedControls.buttons["热评"].isSelected, "连续横滑应切换评论排序。")
        list.swipeRight()
        assertUI(app.segmentedControls.buttons["高赞"].isSelected, "反向横滑应恢复文章排序。")
        list.swipeRight()
        assertUI(app.segmentedControls.buttons["最新"].isSelected, "反向横滑应返回首个文章排序。")
        list.swipeRight()
        assertUI(app.segmentedControls.buttons["话题"].isSelected, "文章首个排序向外横滑应切换话题。")
        tapHeader(app.segmentedControls.buttons["关注"])
        list.swipeRight()
        assertUI(app.segmentedControls.buttons["文章"].isSelected, "话题首个分类向外横滑应切换文章。")
        tapHeader(app.segmentedControls.buttons["热评"])
        list.swipeLeft()
        assertUI(app.segmentedControls.buttons["话题"].isSelected, "文章末尾排序向外横滑应切换话题。")
        tapHeader(app.segmentedControls.buttons["机器人"])
        list.swipeLeft()
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
        app = configureApp(resetStorage: true, content: true)
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
        assertUI(photos.appears(timeout: 5), "图片入口应呈现系统照片选择器。")
        let cancel = platform.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"]))
            .allElementsBoundByIndex.last(where: { $0.isHittable })
        assertUI(cancel != nil, "系统照片选择器应提供取消操作。")
        cancel!.press(forDuration: 0.01)
        assertUI(photos.disappears(timeout: 5), "取消图片选择应关闭系统选择器。")
    }

    @MainActor
    private func tapImage(_ title: String) {
        let image = app.buttons[title]
        var frame = CGRect.zero
        if image.exists {
            frame = image.frame
            if frame.isEmpty {
                assertUI(waitUntil(NSPredicate { _, _ in !image.frame.isEmpty }, on: image), "图片入口应完成布局。")
                frame = image.frame
            }
        }
        if frame.isEmpty || !app.windows.firstMatch.frame.contains(frame) {
            reveal(image, description: title)
        }
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapBriefly()
    }

    @MainActor
    func closeImagePreview() {
        dismissNotificationBanner()
        let close = imagePreviewCloseButton()
        close.press(forDuration: 0.01)
        assertUI(app.otherElements["QLPreviewControllerView"].disappears(timeout: 5), "关闭图片预览应恢复来源页面。")
    }

    @MainActor
    private func imagePreviewCloseButton() -> UIElement {
        let platform = UIElement(app.native)
        let preview = platform.otherElements["QLPreviewControllerView"]
        assertUI(preview.appears(timeout: 30), "图片交互应进入系统 Quick Look。")
        let done = platform.buttons.matching(NSPredicate(format: "label IN %@", ["完成", "Done", "关闭", "Close"])).firstMatch
        if done.appears(timeout: 2) { return done }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tapBriefly()
        assertUI(done.appears(timeout: 10), "点击预览画布应显示关闭控件。")
        return done
    }

}
