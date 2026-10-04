import XCTest
import CoreGraphics

nonisolated final class InteractionCoverageUITests: UIAutomationTestCase {
    @MainActor
    @objc func testCalendarReminderCloudSwitchesAndLeadTimePersistence() {
        app = configureApp(resetStorage: true, animations: true, initialSettings: "calendar")
        let sync = toggle("iCloud 多端同步")
        let preferences = toggle("同步设置与使用偏好（实验性）")
        let reminderControl = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "显示灵动岛提醒（实验性）")).firstMatch
        reveal(reminderControl)
        reminderControl.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tapBriefly()
        assertUI(app.alerts["实验性功能提醒"].appears(timeout: 5), "提醒开关应展示实验功能确认。")
        app.alerts["实验性功能提醒"].buttons["取消"].tapBriefly()
        waitForValue("0", of: reminderControl)
        assertUI(app.alerts["实验性功能提醒"].disappears(timeout: 5), "取消应关闭实验功能确认。")
        assertUI(waitUntil(NSPredicate(format: "hittable == true"), on: reminderControl), "取消后提醒开关应恢复交互。")
        reminderControl.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tapBriefly()
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
        toggle("同步设置与使用偏好（实验性）")
        toggle("iCloud 多端同步")
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
        assertUI(wheel.value as? String != initial, "日期滚轮应响应滑动。")
        tap("取消")
        tap("学期起始日期")
        tap("使用学校日期")
        tap("完成")
        back()
        app.tabBars.buttons["日程"].tapBriefly()
        app.segmentedControls.buttons["空教室"].tapBriefly()
        assertUI(textElement("A101").appears(timeout: 10), "学校响应应展示空教室。")
        choose("校区", option: "中关村校区")
        choose("教学楼", option: "文萃楼B")
        assertUI(textElement("B101").appears(timeout: 5), "教学楼选择应更新教室结果。")
        tap("刷新")
        assertUI(textElement("B101").appears(timeout: 5), "手动刷新应恢复当前教学楼结果。")
        openSettings("ddl")
        tap("重新获取订阅链接")
        closeAlertIfPresent()
        tap("刷新学校日程")
        closeAlertIfPresent()
        back()
        app.tabBars.buttons["日程"].tapBriefly()
        app.segmentedControls.buttons["DDL"].tapBriefly()
        let assignment = app.staticTexts["课程中心测试作业"]
        reveal(assignment)
        assignment.tapBriefly()
        assertUI(textElement("刷新后的学校详情").appears(timeout: 5), "学校刷新应更新详情正文。")
        tap("取消")

        app = configureApp(resetStorage: false)
        app.segmentedControls.buttons["空教室"].tapBriefly()
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "离线学校服务应提示刷新失败。")
        closeAlertIfPresent()
        tap("节次筛选")
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
        closeAlertIfPresent()
        tap("清除节次筛选")
        closeAlertIfPresent()
        tap("刷新空教室")
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
        tap("调这节课")
        choose("楼宇", option: "文萃楼B")
        replaceText("202", in: app.textFields["房间号"])
        dismissKeyboard()
        tap("周次")
        tap("第2周")
        tap("完成")
        tap("星期")
        tap("周二")
        tap("节次")
        tap("第3节")
        tap("完成")
        tap("确定")
        tap("取消")
        assertUI(app.buttons["schedule.add-content"].appears(timeout: 5), "保存单节调整后关闭详情应返回课表。")
        tap("学校测试课程")
        tap("调这门课")
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
        tap("第3周")
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
        for identifier in ["schedule.custom.date", "schedule.custom.begin", "schedule.custom.end"] {
            openAndDismissDatePicker(identifier)
        }
        replaceText("详细测试日程", in: app.textFields["schedule.custom.title"])
        replaceText("测试地点", in: app.textFields["schedule.custom.subtitle"])
        replaceText("测试描述", in: app.textFields["schedule.custom.details"])
        dismissKeyboard()
        tap("确定")
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
        assertUI(!textElement("详细测试日程").exists, "删除应移除已保存日程。")
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
        replaceText("000000", in: code)
        dismissKeyboard()
        tap("验证并查询成绩")
        assertUI(app.staticTexts["测试验证码错误。"].appears(timeout: 5), "错误验证码应展示重试说明。")
        tap("取消")
        let retry = app.buttons["重新查询"]
        assertUI(retry.appears(timeout: 5) && retry.isEnabled, "取消短信应恢复重新查询入口。")
        retry.tapBriefly()
        replaceText("123456", in: app.textFields["verification.code"])
        dismissKeyboard()
        tap("验证并查询成绩")
        assertUI(textElement("自动化测试课程").appears(timeout: 5), "短信提交应加载成绩。")
        for (route, option) in [("学期", "ui-test-term"), ("种类", "必修")] {
            openScoreFilter(route)
            tap("全不选")
            assertUI(app.buttons["全选"].exists, "批量清空应恢复全选操作。")
            tap("全选")
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
        tap("排序")
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
        replaceText("123456", in: app.textFields["verification.code"])
        dismissKeyboard()
        tap("验证并查询成绩")
        assertUI(textElement("自动化测试课程").appears(timeout: 5), "已有成绩刷新应恢复成绩列表。")
        assertUI(app.alerts["成绩已是最新"].appears(timeout: 5), "重复查询应展示当前成绩已是最新。")
        closeAlertIfPresent()
        tap("学校测试课程")
        assertUI(app.navigationBars["成绩详情"].appears(timeout: 5), "未出分课程应打开详情。")
        back()
        tap("自动化测试课程")
        assertUI(app.navigationBars["成绩详情"].appears(timeout: 5), "成绩行应打开详情。")
        tap("查看课程评价")
        assertUI(app.segmentedControls.buttons["课程"].isSelected, "成绩详情应进入课程搜索。")
    }

    @MainActor
    private func openScoreFilter(_ title: String) {
        let route = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title)、")).firstMatch
        reveal(route, description: "\(title)筛选")
        route.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tapBriefly()
        assertUI(app.navigationBars["\(title)筛选"].appears(timeout: 5), "筛选入口应打开\(title)选择页。")
    }

    @MainActor
    @objc func testTrustedTranscriptSMSRetryPreviewAndCancellation() {
        app = configureApp(resetStorage: true, animations: true, initialTab: "home")
        tap("申请可信成绩单")
        tap("取消")
        tap("重试")
        let code = app.textFields["verification.code"]
        replaceText("000000", in: code)
        dismissKeyboard()
        tap("验证并申请成绩单")
        assertUI(textElement("测试验证码错误。").appears(timeout: 5), "成绩单短信应支持错误重试。")
        replaceText("123456", in: code)
        dismissKeyboard()
        tap("验证并申请成绩单")
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
        tap("取消")
        replaceText("自动化回复内容", in: app.textFields.firstMatch)
        dismissKeyboard()
        tap("发送")
        assertUI(textElement("自动化回复内容").appears(timeout: 5), "回复发送应更新评论。")
        back()
        app.segmentedControls.buttons["文章"].tapBriefly()
        tap("自动化测试文章")
        tap("点赞评论")
        assertUI(app.buttons["取消评论点赞"].appears(timeout: 5), "文章评论应支持点赞。")
        tap("取消评论点赞")
        tap("回复")
        replaceText("文章回复内容", in: app.textFields.firstMatch)
        dismissKeyboard()
        tap("发布")
        reveal(textElement("文章回复内容"))
        assertUI(textElement("文章回复内容").exists, "文章回复应显示正文。")
        back()
        app.segmentedControls.buttons["话题"].tapBriefly()
        tap("保存后的测试话题")
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
            app.segmentedControls.buttons[title].tapBriefly()
            assertUI(app.segmentedControls.buttons[title].isSelected, "话题分类应选中：\(title)。")
        }
        pullToRefresh()
        assertUI(textElement("自动化测试话题").exists, "话题列表刷新应保留服务结果。")
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
        app.segmentedControls.buttons["文章"].tapBriefly()
        pullToRefresh()
        assertUI(textElement("自动化测试文章").exists, "文章列表刷新应恢复数据。")
        for title in ["最新", "高赞", "热评"] {
            app.segmentedControls.buttons[title].tapBriefly()
            assertUI(app.segmentedControls.buttons[title].isSelected, "文章排序应更新选中项。")
        }
        app.segmentedControls.buttons["最新"].tapBriefly()
        list.swipeLeft()
        assertUI(app.segmentedControls.buttons["高赞"].isSelected, "文章横滑应切换点赞排序。")
        list.swipeLeft()
        assertUI(app.segmentedControls.buttons["热评"].isSelected, "连续横滑应切换评论排序。")
        list.swipeRight()
        assertUI(app.segmentedControls.buttons["高赞"].isSelected, "反向横滑应恢复文章排序。")
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
        closeImagePreview()
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
        let photos = app.buttons.matching(NSPredicate(format: "label IN %@", ["照片", "Photos"])).firstMatch
        assertUI(photos.appears(timeout: 5), "图片入口应呈现系统照片选择器。")
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"]))
            .allElementsBoundByAccessibilityElement.last(where: { $0.isHittable })
        assertUI(cancel != nil, "系统照片选择器应提供取消操作。")
        cancel!.tapBriefly()
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
    private func closeImagePreview() {
        let close = imagePreviewCloseButton()
        close.tapBriefly()
        assertUI(app.otherElements["QLPreviewControllerView"].disappears(timeout: 5), "关闭图片预览应恢复来源页面。")
    }

    @MainActor
    private func imagePreviewCloseButton() -> XCUIElement {
        let preview = app.otherElements["QLPreviewControllerView"]
        assertUI(preview.appears(timeout: 30), "图片交互应进入系统 Quick Look。")
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["完成", "Done", "关闭", "Close"])).firstMatch
        if done.appears(timeout: 2) { return done }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tapBriefly()
        assertUI(done.appears(timeout: 10), "点击预览画布应显示关闭控件。")
        return done
    }

    @MainActor
    @objc func testPaperImagePreviewCommentsSortAndShare() {
        app = configureApp(resetStorage: true, content: true, animations: true, media: true, initialTab: "gallery")
        app.segmentedControls.buttons["文章"].tapBriefly()
        tap("自动化测试文章")
        let link = app.links.matching(identifier: "正文链接").firstMatch
        reveal(link)
        link.tapBriefly()
        assertOpenedURL("github.com/BIT101-dev/BIT101-iOS")
        let image = app.buttons["文章图片：测试图片"]
        reveal(image)
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapBriefly()
        closeImagePreview()
        let footerLike = app.buttons["paper.detail.footer-like"]
        reveal(footerLike)
        footerLike.tapBriefly()
        let headerLike = app.buttons["paper.detail.header-like"]
        assertUI(waitUntil(NSPredicate(format: "label == %@", "取消文章点赞"), on: headerLike, timeout: 5), "正文末尾点赞应同步顶部状态。")
        footerLike.tapBriefly()
        assertUI(waitUntil(NSPredicate(format: "label == %@", "点赞文章"), on: headerLike, timeout: 5), "正文末尾取消点赞应同步顶部状态。")
        for title in ["高赞", "最旧", "最新"] {
            tap("排序")
            tap(title)
            assertUI(textElement("自动化测试评论").appears(timeout: 5), "文章评论排序应显示对应结果。")
        }
        tap("更多操作")
        tap("分享文章")
        dismissShareSheet()
        tap("评论文章")
        toggle("匿名评论")
        tap("取消")
        assertUI(app.navigationBars["文章详情"].exists, "取消评论应恢复文章详情。")
    }

    @MainActor
    @objc func testCourseCommentRepliesRatingsCleaningSearchAndShare() {
        app = configureApp(resetStorage: true, content: true, animations: true, media: true, initialTab: "home")
        app.segmentedControls.buttons["课程"].tapBriefly()
        replaceText("测试\n", in: app.textFields.firstMatch)
        tap("清除搜索")
        tap("自动化测试课程")
        let cleaning = app.buttons["数据清洗"]
        let original = cleaning.value as? String
        cleaning.tapBriefly()
        assertUI(cleaning.value as? String != original, "数据清洗应改变历史成绩展示策略。")
        cleaning.tapBriefly()
        tap("评论课程")
        for rating in ["0.5", "1.0", "1.5", "2.0", "2.5", "3.0", "3.5", "4.0", "4.5", "5.0"] {
            tap("评分 \(rating) 星")
        }
        tap("评分 5.0 星")
        assertUI(app.staticTexts["不评分"].appears(timeout: 5), "再次点击相同星级应清空评分。")
        toggle("匿名评论")
        tap("取消")
        tap("点赞评论")
        assertUI(app.buttons["取消评论点赞"].appears(timeout: 5), "课程评论应支持点赞。")
        tap("取消评论点赞")
        tap("查看评论图片，第1张，共1张")
        closeImagePreview()
        tap("回复")
        replaceText("课程回复内容", in: app.textFields.firstMatch)
        dismissKeyboard()
        tap("发送")
        reveal(textElement("课程回复内容"))
        assertUI(textElement("课程回复内容").exists, "课程回复应显示正文。")
        tap("分享课程")
        dismissShareSheet()
    }

    @MainActor
    @objc func testPosterReportSelectionCancellationAndSubmission() {
        app = configureApp(resetStorage: true, content: true, initialTab: "gallery")
        tap("更多操作")
        tap("举报帖子")
        choose("类型", option: "其他")
        tap("取消")
        assertUI(app.buttons["发布话题"].exists, "取消卡片举报应返回列表。")
        tap("自动化测试话题")
        tap("更多操作")
        tap("举报帖子")
        replaceText("帖子举报说明", in: app.textFields["请描述举报原因"])
        dismissKeyboard()
        tap("提交举报")
        assertUI(app.alerts["举报已提交"].appears(timeout: 5), "详情举报应展示提交结果。")
        tap("知道了")
        assertUI(app.navigationBars["帖子详情"].exists, "举报完成应返回详情。")
    }

    @MainActor
    @objc func testExternalLinksFromLoginAboutAndCourseResources() {
        app = configureApp(resetStorage: true, account: nil, content: true)
        tapLink("京ICP备")
        assertOpenedURL("beian.miit.gov.cn")
        signIn(app)
        openSettings("about")
        for (entry, url) in [("项目仓库", "github.com/BIT101-dev/BIT101-iOS"), ("QQ交流群", "jq.qq.com"),
                             ("邮箱", "mailto:systemd@linux.do"), ("ICP备案", "beian.miit.gov.cn"),
                             ("如果你也想加入", "mailto:systemd@linux.do")] {
            tapLink(entry)
            assertOpenedURL(url)
        }
        back()
        app.tabBars.buttons["成绩"].tapBriefly()
        app.segmentedControls.buttons["课程"].tapBriefly()
        tap("自动化测试课程")
        tap("共享资料")
        assertOpenedURL("http")
    }

    @MainActor
    private func tapLink(_ title: String) {
        let types = [Int(XCUIElement.ElementType.link.rawValue), Int(XCUIElement.ElementType.button.rawValue)]
        let link = app.descendants(matching: .any)
            .matching(NSPredicate(format: "elementType IN %@ AND label CONTAINS %@", types, title)).firstMatch
        reveal(link, description: title)
        link.tapBriefly()
    }

    @MainActor
    private func assertOpenedURL(_ target: String) {
        let alert = app.alerts["打开链接"]
        assertUI(alert.appears(timeout: 5), "链接操作应发出页面选定的地址。")
        assertUI(alert.staticTexts.allElementsBoundByIndex.contains { $0.label.contains(target) }, "链接地址应匹配\(target)。")
        alert.buttons["知道了"].tapBriefly()
        assertUI(alert.disappears(timeout: 5), "关闭链接提示应恢复来源页面。")
    }

    @MainActor
    private func dismissShareSheet() {
        let sheet = app.navigationBars["UIActivityContentView"]
        assertUI(sheet.appears(timeout: 5), "分享入口应打开系统分享面板。")
        let dismissRegion = app.otherElements.matching(identifier: "PopoverDismissRegion").firstMatch
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["关闭", "Close"])).firstMatch
        let popover = app.popovers.firstMatch
        if dismissRegion.exists, popover.exists {
            dismissSystemPopover(popover)
        } else {
            assertUI(close.appears(timeout: 5), "分享面板应提供关闭控件。")
            close.tapBriefly()
        }
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: sheet, timeout: 5), "关闭分享面板应返回来源页面。")
    }

    @MainActor
    private func dismissSystemPopover(_ popover: XCUIElement, within bounds: CGRect? = nil) {
        let dismiss = app.buttons["PopoverDismissRegion"]
        let bounds = bounds ?? app.frame
        let panel = popover.frame
        let gaps = [
            CGRect(x: bounds.minX, y: bounds.minY, width: panel.minX - bounds.minX, height: bounds.height),
            CGRect(x: panel.maxX, y: bounds.minY, width: bounds.maxX - panel.maxX, height: bounds.height),
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: panel.minY - bounds.minY),
            CGRect(x: bounds.minX, y: panel.maxY, width: bounds.width, height: bounds.maxY - panel.maxY),
        ].filter { $0.size.width > 0 && $0.size.height > 0 }
            .map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        let gap = gaps.first
        assertUI(gap != nil, "系统浮窗外应提供可点击的页面区域。")
        let origin = dismiss.exists ? dismiss.coordinate(withNormalizedOffset: .zero)
            : app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: gap!.midX, dy: gap!.midY)).tapBriefly()
        assertUI(popover.disappears(timeout: 5), "点击浮窗外应关闭系统浮窗。")
    }

    @MainActor
    @objc func testManualUpdatePromptAllActionsAndCurrentVersion() {
        app = configureApp(resetStorage: true, animations: true, update: "new", initialSettings: "about")
        for action in ["本次忽略", "忽略此版本", "前往 App Store"] {
            tap("检查更新")
            assertUI(app.alerts["发现新版本 999.0"].appears(timeout: 5), "更新响应应展示新版本。")
            tap(action)
            if action == "前往 App Store" { assertOpenedURL("apps.apple.com/cn/app/bit101/id6761147125") }
        }
        app = configureApp(resetStorage: true, animations: true, update: "current", initialSettings: "about")
        tap("检查更新")
        assertUI(app.alerts["已是最新版本"].appears(timeout: 5), "当前版本响应应展示检查结果。")
        closeAlertIfPresent()
    }

    @MainActor
    @objc func testOfflineRecoveryRetryAndErrorReportEditor() {
        app = configureApp(resetStorage: true, animations: true, initialTab: "gallery")
        closeAlertIfPresent()
        tap("重试")
        assertUI(textElement("加载失败").appears(timeout: 5), "离线重试应恢复失败状态。")
        tap("向开发者分享错误信息")
        assertUI(app.navigationBars["分享错误信息"].appears(timeout: 5), "诊断入口应打开报告编辑器。")
        tap("原始网络响应")
        replaceText("测试复现步骤", in: app.textFields["error-report.comment"])
        dismissKeyboard()
        tap("提交")
        tap("返回补充")
        replaceText("测试联系信息", in: app.textFields["联系方式"])
        dismissKeyboard()
        tap("提交")
        assertUI(app.alerts["确认提交原始网络响应？"].appears(timeout: 5), "原始模式应要求确认。")
        tap("取消")
        tap("提交")
        tap("确认提交")
        assertUI(textElement("提交失败").appears(timeout: 10), "离线报告应保留失败结果。")
        tap("取消")
        assertUI(app.tabBars.buttons["话廊"].exists, "取消报告应返回话廊。")
    }

    @MainActor
    @objc func testCommunityFailedRequestsRetryToLoadedState() {
        app = configureApp(resetStorage: true, content: true, failureOnce: true, initialTab: "home")
        app.segmentedControls.buttons["课程"].tapBriefly()
        assertUI(app.alerts["加载课程失败"].appears(timeout: 5), "首次课程失败应展示错误提示。")
        closeAlertIfPresent()
        tap("重新加载")
        assertUI(textElement("自动化测试课程").appears(timeout: 5), "课程重试应恢复加载结果。")
        app.tabBars.buttons["话廊"].tapBriefly()
        assertUI(app.alerts["加载话廊失败"].appears(timeout: 5), "首次话廊失败应展示错误提示。")
        closeAlertIfPresent()
        tap("重试")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "话廊重试应恢复列表。")
        app.segmentedControls.buttons["文章"].tapBriefly()
        assertUI(app.alerts["加载文章失败"].appears(timeout: 5), "首次文章失败应展示错误提示。")
        closeAlertIfPresent()
        tap("重试")
        assertUI(textElement("自动化测试文章").appears(timeout: 5), "文章重试应恢复列表。")
    }

    @MainActor
    @objc func testSuggestionSuccessfulSubmissionAndDiscardSavedDraft() {
        app = configureApp(resetStorage: true, content: true)
        openSettings("suggestion")
        replaceText("成功提交测试建议", in: app.textFields["建议内容"])
        dismissKeyboard()
        tap("取消")
        tap("保存草稿")
        openSettings("suggestion")
        tap("不加载")
        assertUI(app.textFields["建议内容"].value as? String != "成功提交测试建议", "放弃加载应清空保存草稿。")
        replaceText("成功提交测试建议", in: app.textFields["建议内容"])
        dismissKeyboard()
        tap("提交")
        tap("继续提交")
        let page = app.navigationBars["向开发者提建议"]
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: page, timeout: 5), "提交成功应关闭建议页。")
        openSettings("suggestion")
        assertUI(!app.alerts["加载草稿？"].exists, "提交成功应清理建议草稿。")
        tap("取消")
    }

    @MainActor
    @objc func testSchoolSMSCourseSyncValidationCancelAndContinuation() {
        app = configureApp(resetStorage: true, animations: true, school: true, schoolSMS: true)
        tap("刷新")
        assertUI(app.navigationBars["短信验证"].appears(timeout: 5), "课表刷新应呈现学校验证码。")
        tap("取消")
        tap("刷新")
        let field = app.textFields["verification.code"]
        replaceText("000000", in: field)
        dismissKeyboard()
        tap("验证并同步课表")
        assertUI(textElement("测试学校验证码错误。").appears(timeout: 5), "学校错误验证码应支持修改。")
        replaceText("123456", in: field)
        dismissKeyboard()
        tap("验证并同步课表")
        assertUI(app.buttons["schedule.add-content"].appears(timeout: 5), "验证成功应继续课表刷新。")
        assertUI(textElement("学校测试课程").exists, "继续同步应保存学校课程。")
    }

    @MainActor
    @objc func testSchoolSSODDLVerificationCancelAndContinuation() {
        app = configureApp(resetStorage: true, school: true, schoolSMS: true)
        app.segmentedControls.buttons["DDL"].tapBriefly()
        tap("刷新学校日程")
        assertUI(app.buttons["验证并继续"].appears(timeout: 5), "学校日程应展示 SSO 短信面板。")
        tap("取消")
        tap("刷新学校日程")
        replaceText("123456", in: app.textFields.firstMatch)
        dismissKeyboard()
        tap("验证并继续")
        assertUI(textElement("课程中心测试作业").appears(timeout: 5), "SSO 验证成功应恢复学校日程请求。")
    }

    @MainActor
    @objc func testHolidayAndTransferConfirmedMutations() {
        app = configureApp(resetStorage: true, school: true)
        let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1周，周一，")).firstMatch
        day.tapBriefly()
        app.segmentedControls.buttons["放假"].tapBriefly()
        tap("确定")
        app.alerts["确认放假"].buttons["确定"].tapBriefly()
        assertUI(!app.buttons["学校测试课程"].exists, "确认放假应移除当日课程。")
        tap("第2周")
        assertUI(app.buttons["学校测试课程"].exists, "放假应保留其它周次课程。")
        let nextDay = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第2周，周一，")).firstMatch
        nextDay.tapBriefly()
        app.segmentedControls.buttons["调至某天"].tapBriefly()
        let target = app.datePickers["schedule.adjustment.date"]
        target.buttons.firstMatch.tapBriefly()
        let today = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS[c] %@", "今天", "today")).firstMatch
        assertUI(today.appears(timeout: 5), "日期选择器应提供今天的选择入口。")
        today.tapBriefly()
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapBriefly()
        tap("确定")
        app.alerts["确认调课"].buttons["确定"].tapBriefly()
        assertUI(app.buttons["schedule.add-content"].appears(timeout: 5), "确认调休应关闭调整窗口。")
        assertUI(!app.buttons["学校测试课程"].exists, "确认调休应移出原日期课程。")
        tap("第1周")
        assertUI(app.buttons["学校测试课程"].exists, "调休应在目标日期显示课程。")
    }

    @MainActor
    @objc func testScheduleWeekStripScrollAndCourseLongPressShare() {
        app = configureApp(resetStorage: true, content: true, school: true)
        let week = app.buttons["第1周"]
        let start = week.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -100, dy: 0)),
                    withVelocity: .fast, thenHoldForDuration: 0.1)
        assertUI(waitUntil(NSPredicate(format: "selected == false"), on: week, timeout: 5), "滑动周次栏应更新选择周。")
        tap("上一周")
        tap("第1周")
        let course = app.buttons["学校测试课程"]
        course.press(forDuration: 1)
        tap("分享课程")
        dismissShareSheet()
        let area = app.descendants(matching: .any).matching(identifier: "schedule.blank-context-menu").firstMatch
        area.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).press(forDuration: 1)
        tap("分享课表")
        assertUI(app.navigationBars["分享课表"].appears(timeout: 5), "长按分享应打开学校课表编码。")
        app.buttons["schedule.export.share"].tapBriefly()
        dismissShareSheet()
        tap("取消")
    }

    @MainActor
    @objc func testCourseHistoryChartSelectionAndHomeSurfaceSwipes() {
        app = configureApp(resetStorage: true, content: true, initialTab: "home")
        app.collectionViews.firstMatch.swipeLeft()
        assertUI(app.segmentedControls.buttons["课程"].isSelected, "成绩页横滑应切换课程分区。")
        app.collectionViews.firstMatch.swipeRight()
        assertUI(app.segmentedControls.buttons["成绩"].isSelected, "反向横滑应恢复成绩分区。")
        app.segmentedControls.buttons["课程"].tapBriefly()
        tap("自动化测试课程")
        let chart = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "历史成绩图")).firstMatch
        reveal(chart)
        let left = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
        let right = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4))
        right.press(forDuration: 0.6, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0.1)
        assertUI(waitUntil(NSPredicate(format: "value CONTAINS %@", "2025-2026-1"), on: chart, timeout: 5), "向左滑动历史图应选中第一学期。")
        left.press(forDuration: 0.6, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0.1)
        assertUI(waitUntil(NSPredicate(format: "value CONTAINS %@", "2025-2026-2"), on: chart, timeout: 5), "向右滑动历史图应选中第二学期。")
    }


    @MainActor
    private func pullToRefresh() {
        let scroll = interactionScrollArea()
        assertUI(scroll != nil, "刷新场景应提供可滚动区域。")
        let area = scroll!
        let start = area.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.2))
        let end = area.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.9))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
    }

    @MainActor
    @objc func testMinePublicProfileFollowAndPostDeletion() {
        app = configureApp(resetStorage: true, content: true, animations: true, media: true, initialTab: "mine")
        assertUI(textElement("自动化测试用户").appears(timeout: 5), "个人页应加载账号资料。")
        tap("粉丝")
        assertUI(app.navigationBars["我的粉丝"].appears(timeout: 5), "粉丝统计应打开粉丝列表。")
        pullToRefresh()
        assertUI(textElement("自动化测试用户").exists, "粉丝刷新应恢复用户。")
        tap("自动化测试用户")
        assertUI(app.buttons["关注"].appears(timeout: 5), "粉丝用户行应进入公开主页。")
        back()
        tap("关注")
        assertUI(app.navigationBars["我的关注"].appears(timeout: 5), "关注统计应打开关注列表。")
        pullToRefresh()
        assertUI(textElement("自动化测试用户").exists, "关注刷新应恢复用户。")
        tap("自动化测试用户")
        tap("关注")
        let followed = app.buttons["已关注"]
        assertUI(followed.appears(timeout: 5) && !followed.isEnabled, "关注成功应展示已关注状态。")
        tap("查看头像")
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
        tap("帖子")
        assertUI(app.navigationBars["我的帖子"].appears(timeout: 5), "帖子统计应打开帖子列表。")
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

    @MainActor
    private func dismissPosterSheet(returningTo title: String) {
        let detail = app.navigationBars["帖子详情"]
        detail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
            withVelocity: .fast, thenHoldForDuration: 0.1)
        assertUI(detail.disappears(timeout: 5), "下滑应关闭帖子详情。")
        assertUI(waitUntil(NSPredicate(format: "hittable == true"), on: app.navigationBars[title]), "关闭详情应恢复\(title)。")
    }

    @MainActor
    @objc func testMapLocationAndScheduleLocationRoute() {
        app = configureApp(resetStorage: true, content: true, school: true)
        tap("学校测试课程")
        tap("查看上课地点")
        assertUI(app.tabBars.buttons["地图"].isSelected, "课程地点应切换至地图。")
        let location = app.buttons["定位到我的位置"]
        location.tapBriefly()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.firstMatch
        if permission.appears(timeout: 2) {
            let allow = permission.buttons.matching(NSPredicate(format: "label IN %@", ["允许一次", "Allow Once"])).firstMatch
            assertUI(allow.exists, "定位权限应提供单次授权。")
            allow.tapBriefly()
        }
        closeAlertIfPresent()
        assertUI(app.maps.firstMatch.isHittable && location.isHittable, "定位后地图及控件应继续响应。")
        tap("导航到下一节课")
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        assertUI(maps.wait(for: .runningForeground, timeout: 10), "下一节导航应交给系统地图。")
        app.activate()
        assertUI(location.appears(timeout: 5), "从系统地图返回应恢复地图控件。")
    }


    @MainActor
    private func tapSearchSort(_ title: String) {
        let menu = app.buttons["search.sort"]
        reveal(menu, description: "搜索排序")
        assertUI(menu.label.contains(title), "搜索排序应显示当前选项\(title)。")
        menu.tapBriefly()
    }

    @MainActor
    @objc func testNetworkDiagnosisProgressAndReport() {
        app = configureApp(resetStorage: true, initialSettings: "gallery")
        tap("测试网络并生成诊断报告")
        assertUI(app.alerts["网络诊断完成"].appears(timeout: 60), "诊断操作应汇总每个网络步骤。")
        for title in ["网络路径", "BIT101 首页", "话廊接口", "文章接口", "学校当前学期", "课表与考试", "DDL 接口", "可信成绩单"] {
            assertUI(app.alerts.staticTexts.allElementsBoundByIndex.contains { $0.label.contains(title) }, "诊断报告应包含\(title)。")
        }
        closeAlertIfPresent()
        assertUI(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "测试网络并生成诊断报告")).firstMatch.isEnabled,
                 "诊断结束应恢复执行入口。")
    }

    @MainActor
    @objc func testCourseScheduleAcademicRouteAndPosterAuthorProfile() {
        app = configureApp(resetStorage: true, content: true, school: true)
        tap("学校测试课程")
        tap("查看课程评价")
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "学校课程评价入口应打开匹配课程。")
        assertUI(textElement("学校测试课程").exists, "匹配后的课程详情应保留学校课程身份。")
        back()
        app.tabBars.buttons["话廊"].tapBriefly()
        tap("自动化测试话题")
        tap("自动化测试用户")
        assertUI(app.buttons["关注"].appears(timeout: 5), "帖子作者应打开公开主页。")
        back()
        tap("分享话题")
        dismissShareSheet()
        let commentUser = app.buttons.matching(NSPredicate(format: "label == %@", "自动化测试用户")).allElementsBoundByIndex.last
        assertUI(commentUser != nil, "评论应提供用户主页入口。")
        reveal(commentUser!)
        commentUser!.tapBriefly()
        assertUI(app.buttons["关注"].appears(timeout: 5), "评论昵称应打开公开主页。")
    }

    @MainActor
    @objc func testEmptyShareAndImportGuideCancellationAndSheetSwipeDismissal() {
        app = configureApp(resetStorage: true, initialSettings: "calendar")
        tap("分享课表")
        app.alerts["当前课表为空"].buttons["取消"].tapBriefly()
        assertUI(app.buttons["schedule.settings.primary-name"].exists, "取消空课表分享应留在设置页。")
        tap("导入课表")
        app.alerts["导入分享课表提示"].buttons["取消"].tapBriefly()
        assertUI(!app.textViews["schedule.import.code"].exists, "取消导入说明应保留设置页。")
        back()
        app.tabBars.buttons["日程"].tapBriefly()
        app.buttons["schedule.add-content"].tapBriefly()
        tap("添加日程")
        let sheet = app.navigationBars["添加自定义日程"]
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
            withVelocity: .fast, thenHoldForDuration: 0.1)
        assertUI(waitUntil(NSPredicate(format: "hittable == true"), on: app.buttons["schedule.add-content"], timeout: 5), "下滑关闭应恢复课表入口。")
    }


    @MainActor
    @objc func testDDLEditorDetailsDatePickerValidationAndCancelEditing() {
        app = configureApp(resetStorage: true)
        app.segmentedControls.buttons["DDL"].tapBriefly()
        tap("添加待办")
        app.buttons["ddl.editor.save"].tapBriefly()
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "空待办标题应展示校验结果。")
        closeAlertIfPresent()
        replaceText("带详情的待办", in: app.textFields["ddl.editor.title"])
        replaceText("待办详细说明", in: app.textFields["ddl.editor.details"])
        dismissKeyboard()
        openAndDismissDatePicker("ddl.editor.date")
        app.buttons["ddl.editor.save"].tapBriefly()
        assertUI(app.navigationBars["添加 DDL"].disappears(timeout: 5), "保存应关闭待办编辑器。")
        tap("标记为已完成")
        assertUI(app.buttons["标记为未完成"].exists, "完成操作应更新待办状态。")
        tap("标记为未完成")
        let todo = app.staticTexts["带详情的待办"]
        reveal(todo)
        todo.tapBriefly()
        assertUI(textElement("待办详细说明").appears(timeout: 5), "待办详情应恢复输入正文。")
        tap("编辑")
        replaceText("取消的待办修改", in: app.textFields["ddl.editor.title"])
        dismissKeyboard()
        tap("取消")
        assertUI(textElement("带详情的待办").appears(timeout: 5), "取消待办编辑应保留原记录。")
        todo.tapBriefly()
        tap("编辑")
        replaceText("修改后的待办", in: app.textFields["ddl.editor.title"])
        dismissKeyboard()
        app.buttons["ddl.editor.save"].tapBriefly()
        let edited = app.staticTexts["修改后的待办"]
        assertUI(edited.appears(timeout: 5), "保存编辑应更新待办标题。")
        edited.tapBriefly()
        tap("删除")
        assertUI(!edited.exists, "删除应移除待办记录。")
        tap("添加待办")
        tap("取消")
        assertUI(app.buttons["添加待办"].exists, "取消新增应恢复待办列表。")
    }

    @MainActor
    @objc func testFutureScheduleImportUpdateCancellationAndLink() {
        app = configureApp(resetStorage: true, initialSettings: "calendar")
        tap("导入课表")
        tap("知道了")
        let code = app.textViews["schedule.import.code"]
        replaceText("BIT101SCH99:test", in: code)
        dismissKeyboard()
        tap("导入")
        assertUI(app.alerts["需要更新 BIT101"].appears(timeout: 5), "较新编码应展示版本更新提示。")
        app.alerts.buttons["取消"].tapBriefly()
        assertUI(code.value as? String == "BIT101SCH99:test", "取消更新应保留编码输入。")
        tap("导入")
        tap("前往 App Store")
        assertOpenedURL("apps.apple.com/cn/app/bit101/id6761147125")
        tap("取消")
    }

    @MainActor
    @objc func testWebGallerySettingPersistenceScrollingAndNativeReturn() {
        app = configureApp(resetStorage: true, content: true, initialSettings: "gallery")
        let value = toggle("使用网页话廊")
        back()
        app.tabBars.buttons["话廊"].tapBriefly()
        let web = app.webViews.firstMatch
        assertUI(web.appears(timeout: 10), "网页设置应打开 WebKit 页面。")
        web.swipeUp()
        web.swipeDown()
        app = configureApp(resetStorage: false, content: true, initialSettings: "gallery")
        let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "使用网页话廊")).firstMatch
        reveal(control)
        waitForValue(value, of: control)
        toggle("使用网页话廊")
        back()
        app.tabBars.buttons["话廊"].tapBriefly()
        assertUI(app.buttons["发布话题"].appears(timeout: 5), "切回原生设置应恢复话题发布入口。")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "原生列表应加载测试帖子。")
    }

    @MainActor
    @objc func testErrorReportSanitizedSubmissionAndFailureRecovery() {
        app = configureApp(resetStorage: true, content: true, failureOnce: true, initialTab: "gallery")
        tap("向开发者分享错误信息")
        assertUI(app.navigationBars["分享错误信息"].appears(timeout: 5), "诊断入口应呈现报告编辑器。")
        tap("原始网络响应")
        tap("脱敏调试信息")
        replaceText("合成错误报告复现步骤", in: app.textFields["error-report.comment"])
        dismissKeyboard()
        tap("提交")
        tap("继续提交")
        let report = app.navigationBars["分享错误信息"]
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: report, timeout: 5), "反馈响应成功应关闭报告编辑器。")
        tap("重试")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "提交报告后重试应恢复帖子列表。")
    }

    @MainActor
    @objc func testLoginSubmitButtonAndKeyboardScrollDismissal() {
        app = configureApp(resetStorage: true, account: nil)
        assertUI(app.secureTextFields["login.password"].exists, "登录页应展示密码字段。")
        assertUI(!app.buttons["login.submit"].isEnabled, "空凭据应禁用登录。")
        replaceText("ui-test-student", in: app.textFields["login.student-id"])
        assertUI(!app.buttons["login.submit"].isEnabled, "仅填写账号应保持登录禁用。")
        replaceText("ui-test-password", in: app.secureTextFields["login.password"])
        app.collectionViews.firstMatch.swipeUp()
        dismissKeyboard()
        let submit = app.buttons["login.submit"]
        assertUI(submit.isEnabled, "完整填写凭据应启用登录按钮。")
        submit.tapBriefly()
        assertUI(app.tabBars.buttons["日程"].appears(timeout: 10), "点击登录按钮应进入主界面。")
    }

    @MainActor
    private func openAndDismissDatePicker(_ identifier: String) {
        let field = app.datePickers[identifier]
        reveal(field)
        var seen = Set<String>()
        let labels = field.buttons.allElementsBoundByAccessibilityElement.compactMap { button -> String? in
            guard button.exists, !button.frame.isEmpty, button.isHittable, button.buttons.count == 0 else { return nil }
            let label = button.label
            return seen.insert(label).inserted ? label : nil
        }
        assertUI(!labels.isEmpty, "日期时间控件应暴露系统选择入口。")
        let pickerCount = app.datePickers.count
        for label in labels {
            let form = app.collectionViews.containing(.datePicker, identifier: identifier).firstMatch
            assertUI(form.exists, "日期时间编辑页应提供来源表单。")
            let sourceBounds = form.frame
            let button = field.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapBriefly()
            assertUI(app.popovers.firstMatch.exists || app.datePickers.count > pickerCount || app.pickerWheels.firstMatch.exists,
                     "日期或时间点击应打开系统选择器。")
            let nativePicker = app.datePickers.matching(NSPredicate(format: "identifier == %@", "")).firstMatch
            assertUI(nativePicker.exists, "系统选择器应暴露独立日期时间控件。")
            if app.pickerWheels.firstMatch.exists {
                for index in 0..<app.pickerWheels.count {
                    let wheel = app.pickerWheels.element(boundBy: index)
                    let original = wheel.value as? String ?? ""
                    let downward = original.hasPrefix("59") || original.hasPrefix("23") || original.hasPrefix("下午")
                    let start = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    start.press(forDuration: 0.1,
                                thenDragTo: start.withOffset(CGVector(dx: 0, dy: downward ? 44 : -44)),
                                withVelocity: .fast, thenHoldForDuration: 0.1)
                    assertUI(waitUntil(NSPredicate(format: "value != %@", original), on: wheel), "第\(index + 1)列时间滚轮应响应滑动。")
                    let selection = original.first?.isNumber == true
                        ? String(original.prefix(while: { $0.isNumber })) : original
                    wheel.adjust(toPickerWheelValue: selection)
                    waitForValue(original, of: wheel)
                }
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
    private func exerciseSystemCalendar(_ picker: XCUIElement) {
        let month = picker.buttons.matching(NSPredicate(format: "identifier IN %@", ["DatePicker.Show", "DatePicker.Hide"])).firstMatch
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
        let selected = picker.collectionViews.buttons.allElementsBoundByAccessibilityElement.first(where: { $0.isSelected })
        assertUI(selected != nil, "日期网格应标记当前选择。")
        selected!.tapBriefly()
    }

}
