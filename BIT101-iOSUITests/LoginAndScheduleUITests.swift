import XCTest
import CoreGraphics

nonisolated final class LoginAndScheduleUITests: XCTestCase {
    @MainActor var app: XCUIApplication!
    private let runIdentifier = "ui"

    @MainActor
    func testScheduleWeekButtonsAndSectionSwipes() {
        app = launchApp(resetStorage: true)
        tap("下一周")
        assertSelectedWeek(2)
        tap("上一周")
        assertSelectedWeek(1)
        tap("第3周")
        assertSelectedWeek(3)
        let area = app.descendants(matching: .any).matching(identifier: "schedule.blank-context-menu").firstMatch
        area.swipeLeft()
        assertUI(app.segmentedControls.buttons["DDL"].isSelected, "横滑应切换到 DDL。")
        app.swipeLeft()
        assertUI(app.segmentedControls.buttons["空教室"].isSelected, "横滑应切换到空教室。")
        closeAlertIfPresent()
        app.swipeRight()
        assertUI(app.segmentedControls.buttons["DDL"].isSelected, "反向横滑应恢复 DDL。")
        app.segmentedControls.buttons.element(boundBy: 0).tap()
        assertUI(app.buttons["schedule.add-content"].exists, "分栏切换应恢复课表交互。")
    }

    @MainActor
    private func assertSelectedWeek(_ week: Int) {
        let button = app.buttons["第\(week)周"]
        if button.isSelected { return }
        let selected = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: button)
        assertUI(XCTWaiter.wait(for: [selected], timeout: 5) == .completed, "周次选择应更新为第 \(week) 周。")
    }

    @MainActor
    func testScheduleDayHolidayAndTransferConfirmationCancellation() {
        app = launchApp(resetStorage: true)
        tap("第1周")
        let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1周，周一，")).firstMatch
        assertUI(day.appears(timeout: 5), "每日表头应提供调整入口。")
        day.tap()
        assertUI(app.navigationBars["调休 / 放假"].appears(timeout: 5), "每日表头应打开日期调整。")
        app.segmentedControls.buttons["放假"].tap()
        tap("确定")
        assertUI(app.alerts["确认放假"].appears(timeout: 5), "放假应展示确认。")
        app.alerts.buttons["取消"].tap()
        app.segmentedControls.buttons["调至某天"].tap()
        assertUI(app.datePickers.firstMatch.exists, "调休应提供目标日期选择。")
        tap("确定")
        assertUI(app.alerts["确认调课"].appears(timeout: 5), "调休应展示确认。")
        app.alerts.buttons["取消"].tap()
        tap("取消")
        assertUI(app.buttons["schedule.add-content"].exists, "取消日期调整应恢复课表。")
    }

    @MainActor
    func testLinearScheduleTimelineScrollAndPinch() {
        app = launchApp(resetStorage: true)
        openSettings("calendar")
        assertInteractiveLabelIsColored("时间轴")
        choose("时间轴", option: "线性")
        back()
        app.tabBars.buttons["app.tab.schedule"].tap()
        let timeline = app.scrollViews["schedule.linear.timeline"]
        assertUI(timeline.appears(timeout: 5), "线性模式应提供可缩放的时间轴。")
        let initial = timeline.value as? String
        timeline.pinch(withScale: 1.5, velocity: 1)
        let zoomed = expectation(for: NSPredicate(format: "value != %@", initial ?? ""), evaluatedWith: timeline)
        assertUI(XCTWaiter.wait(for: [zoomed], timeout: 5) == .completed, "双指展开应放大时间轴，当前值：\(String(describing: timeline.value))，\(timeline.label)。")
        let enlarged = timeline.value as? String
        timeline.swipeUp()
        timeline.swipeDown()
        timeline.pinch(withScale: 0.8, velocity: -1)
        assertUI(timeline.value as? String != enlarged, "双指收拢应缩小时间轴。")
        assertUI(timeline.isHittable, "缩放和滚动后时间轴应可交互。")
    }

    @MainActor
    func testMapCampusLayerPanAndZoomPersist() {
        app = launchApp(resetStorage: true)
        app.tabBars.buttons["app.tab.map"].tap()
        let layer = app.buttons["切换地图图层"]
        assertUI(layer.appears(timeout: 5), "地图应提供图层入口。")
        let original = layer.value as? String
        layer.tap()
        assertUI(layer.value as? String != original, "切换图层应改变地图模式。")
        for campus in ["良乡校区", "中关村校区", "珠海校区"] {
            let button = app.buttons["切换到\(campus)"]
            button.tap()
            assertUI(button.isSelected, "校区切换应更新选中状态：\(campus)")
        }
        let map = app.maps.firstMatch
        assertUI(map.exists, "地图应暴露可交互的地图区域。")
        map.swipeLeft()
        map.pinch(withScale: 1.5, velocity: 1)
        assertUI(layer.isHittable, "平移和缩放后地图操作仍可触达。")
        app.terminate()
        app = launchApp(resetStorage: false)
        app.tabBars.buttons["app.tab.map"].tap()
        assertUI(app.buttons["切换地图图层"].value as? String != original, "重启应保留图层设置。")
        assertUI(app.buttons["切换到珠海校区"].isSelected, "重启应保留校区。")
    }

    @MainActor
    func testCalendarSettingsPickersTogglesAndRenamePersist() {
        app = launchApp(resetStorage: true)
        openSettings("calendar")
        choose("时间轴", option: "线性")
        choose("时间轴", option: "节次")
        choose("课程显示方式", option: "全学期叠加")
        choose("课程显示方式", option: "按周显示")
        for option in ["名称", "地点", "名称和地点"] {
            choose("显示内容", option: option)
        }
        let savedSwitches = Dictionary(uniqueKeysWithValues: ["显示周六", "显示周日", "显示考试安排"].map { ($0, toggle($0)) })
        let nameRow = app.buttons["schedule.settings.primary-name"]
        reveal(nameRow, description: "课表名称")
        nameRow.tap()
        let name = app.textFields["schedule.rename.name"]
        assertUI(name.appears(timeout: 5), "重命名应展示输入框。")
        replaceText("测试课表名称", in: name)
        tap("确定")
        assertUI(textElement("测试课表名称").appears(timeout: 5), "重命名应更新设置行。")
        app.terminate()
        app = launchApp(resetStorage: false)
        assertUI(app.segmentedControls.buttons["测试课表名称"].exists, "重启应保留课表名称。")
        openSettings("calendar")
        for title in ["显示周六", "显示周日", "显示考试安排"] {
            let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            reveal(control, description: title)
            assertUI(control.value as? String == savedSwitches[title], "重启应保留开关：\(title)")
            toggle(title)
        }
    }

    @MainActor
    func testCalendarSettingsEditorsAndConfirmationCancellation() {
        app = launchApp(resetStorage: true)
        openSettings("calendar")
        tap("时间表")
        assertUI(app.navigationBars["设置时间表"].appears(timeout: 5), "时间表入口应打开编辑页。")
        assertUI(app.textViews.firstMatch.exists, "时间表应支持文本编辑。")
        tap("取消")
        tap("学期起始日期")
        assertUI(app.datePickers.firstMatch.appears(timeout: 5), "学期日期应可选择。")
        tap("完成")
        tap("当前学期")
        assertUI(app.navigationBars["切换学期"].appears(timeout: 5), "当前学期应打开选择页。")
        closeAlertIfPresent()
        back()
        tap("导入到系统日历")
        assertUI(app.alerts["导入当前学期到系统日历？"].appears(timeout: 5), "日历导入应展示确认。")
        app.alerts.buttons["取消"].tap()
        tap("删除已导入的日历")
        assertUI(app.alerts["删除 BIT101 导入的日历事件？"].appears(timeout: 5), "日历删除应展示确认。")
        app.alerts.buttons["取消"].tap()
        tap("分享课表")
        app.alerts["当前课表为空"].buttons["确定"].tap()
        assertUI(app.navigationBars["分享课表"].appears(timeout: 5), "分享应打开编码面板。")
        tap("取消")
        tap("导入课表")
        app.alerts["导入分享课表提示"].buttons["知道了"].tap()
        assertUI(app.textViews["schedule.import.code"].appears(timeout: 5), "导入提示确认后应打开编码输入。")
        tap("取消")
    }

    @MainActor
    func testCustomScheduleEditingDeletionAndCancellation() {
        app = launchApp(resetStorage: true)
        addCustomSchedule("可编辑测试日程", in: app)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "schedule.entry.custom-")).firstMatch.tap()
        assertUI(app.buttons["编辑"].appears(timeout: 5), "点击自定义日程应打开详情和编辑入口。")
        tap("编辑")
        let title = app.textFields["schedule.custom.title"]
        assertUI(title.appears(timeout: 5), "编辑应恢复标题字段。")
        replaceText("修改后的日程", in: title)
        dismissKeyboard()
        app.buttons["schedule.custom.save"].tap()
        let entry = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "修改后的日程")).firstMatch
        assertUI(entry.appears(timeout: 5), "保存修改后应展示新标题。")
        entry.tap()
        tap("删除")
        assertUI(!entry.exists, "确认删除后应移除日程。")
        app.buttons["schedule.add-content"].tap()
        tap("添加日程")
        tap("取消")
        assertUI(app.buttons["schedule.add-content"].exists, "取消新增应返回课表。")
    }

    @MainActor
    func testSharedScheduleCopyImportRenameCycleAndSwipeDelete() {
        app = launchApp(resetStorage: true)
        openSettings("calendar")
        tap("分享课表")
        assertUI(app.alerts["当前课表为空"].appears(timeout: 5), "空课表分享应先提示确认。")
        app.alerts["当前课表为空"].buttons["确定"].tap()
        tap("复制到剪贴板")
        assertUI(app.alerts["已复制"].appears(timeout: 5), "复制编码应展示成功提示。")
        app.alerts["已复制"].buttons["知道了"].tap()
        tap("取消")
        tap("导入课表")
        assertUI(app.alerts["导入分享课表提示"].appears(timeout: 5), "首次导入应展示说明。")
        app.alerts["导入分享课表提示"].buttons["知道了"].tap()
        tap("粘贴剪贴板")
        let code = app.textViews["schedule.import.code"]
        assertUI(!(code.value as? String ?? "").isEmpty, "粘贴应恢复刚导出的编码。")
        tap("导入")
        closeAlertIfPresent()
        let shared = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "schedule.settings.shared.")).firstMatch
        reveal(shared, description: "分享课表名称")
        shared.tap()
        replaceText("测试分享课表", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("确定")
        let renamed = expectation(for: NSPredicate(format: "label CONTAINS %@", "测试分享课表"), evaluatedWith: shared)
        assertUI(XCTWaiter.wait(for: [renamed], timeout: 5) == .completed, "保存应更新分享课表名称。")
        back()
        app.tabBars.buttons["app.tab.schedule"].tap()
        let sharedSegment = app.segmentedControls.buttons["测试分享课表"]
        assertUI(sharedSegment.appears(timeout: 5), "导入和改名应增加课表分栏。")
        let area = app.descendants(matching: .any).matching(identifier: "schedule.blank-context-menu").firstMatch
        area.swipeUp()
        assertUI(app.segmentedControls.buttons.element(boundBy: 0).label == "课表", "向上滑动应从分享课表循环到主课表。")
        area.swipeDown()
        assertUI(app.segmentedControls.buttons.element(boundBy: 0).label == "测试分享课表", "向下滑动应恢复分享课表。")
        openSettings("calendar")
        reveal(shared, description: "分享课表名称")
        shared.swipeLeft()
        tap("删除")
        assertUI(!shared.exists, "左滑删除应移除分享课表。")
    }

    @MainActor
    func testManualDDLCreateEditCompleteAndDelete() {
        app = launchApp(resetStorage: true)
        app.segmentedControls.buttons["DDL"].tap()
        tap("添加待办")
        let title = app.textFields["ddl.editor.title"]
        assertUI(title.appears(timeout: 5), "DDL 编辑器应展示标题。")
        title.tap()
        title.typeText("手动测试待办\n")
        app.buttons["ddl.editor.save"].tap()
        let event = app.staticTexts["手动测试待办"]
        assertUI(event.appears(timeout: 5), "新增待办应出现在列表。")
        tap("标记为已完成")
        assertUI(app.buttons["标记为未完成"].exists, "完成操作应更新状态。")
        tap("标记为未完成")
        event.tap()
        tap("编辑")
        replaceText("修改后的待办", in: app.textFields["ddl.editor.title"])
        dismissKeyboard()
        app.buttons["ddl.editor.save"].tap()
        let edited = app.staticTexts["修改后的待办"]
        assertUI(edited.appears(timeout: 5), "编辑待办应更新标题。")
        edited.tap()
        tap("删除")
        assertUI(!edited.exists, "删除待办应移除列表记录。")
        tap("添加待办")
        tap("取消")
        assertUI(app.buttons["添加待办"].exists, "取消新增应恢复 DDL 列表。")
    }

    @MainActor
    func testDDLSettingsWheelSaveCancelAndPersistence() {
        app = launchApp(resetStorage: true)
        openSettings("ddl")
        tap("变色天数")
        let wheel = app.pickerWheels.firstMatch
        assertUI(wheel.appears(timeout: 5), "变色天数应使用滚轮选择。")
        wheel.adjust(toPickerWheelValue: "7 天")
        tap("完成")
        tap("滞留天数")
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "10 天")
        tap("取消")
        tap("滞留天数")
        assertUI(app.pickerWheels.firstMatch.value as? String != "10 天", "取消应保留原值。")
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "5 天")
        tap("完成")
        app.terminate()
        app = launchApp(resetStorage: false)
        openSettings("ddl")
        tap("变色天数")
        assertUI(app.pickerWheels.firstMatch.value as? String == "7 天", "重启应保留变色天数。")
        tap("取消")
        tap("滞留天数")
        assertUI(app.pickerWheels.firstMatch.value as? String == "5 天", "重启应保留滞留天数。")
        tap("取消")
    }

    @MainActor
    func testClassroomSectionMultiSelectionAndClear() {
        app = launchApp(resetStorage: true)
        app.segmentedControls.buttons["空教室"].tap()
        closeAlertIfPresent()
        tap("刷新空教室")
        closeAlertIfPresent()
        tap("节次筛选")
        assertUI(app.navigationBars["节次筛选"].appears(timeout: 5), "空教室应支持节次筛选。")
        tap("全选")
        assertUI(app.buttons["全不选"].exists, "全选应更新批量操作。")
        tap("全不选")
        assertUI(app.buttons["全选"].exists, "全不选应清空选择。")
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1节")).firstMatch
        option.tap()
        waitForValue("已选择", of: option)
        assertUI(option.value as? String == "已选择", "单选应更新选择状态。")
        back()
        closeAlertIfPresent()
        tap("清除节次筛选")
        closeAlertIfPresent()
        tap("节次筛选")
        assertUI(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1节")).firstMatch.value as? String == "未选择", "清除应同步到选择页。")
    }

    @MainActor
    func testGallerySettingsValidationTogglesAndPersistence() {
        app = launchApp(resetStorage: true)
        openSettings("gallery")
        for title in ["隐藏机器人帖子", "隐藏匿名内容", "使用网页话廊"] { toggle(title) }
        let ids = app.textFields["屏蔽用户 UID（逗号分隔）"]
        ids.tap()
        ids.typeText("abc\n")
        assertUI(app.alerts["UID 格式错误"].appears(timeout: 5), "无效 UID 应给出校验提示。")
        closeAlertIfPresent()
        replaceText("12,34", in: ids)
        ids.typeText("\n")
        dismissKeyboard()
        app.terminate()
        app = launchApp(resetStorage: false)
        openSettings("gallery")
        assertUI(app.textFields["屏蔽用户 UID（逗号分隔）"].value as? String == "12,34", "重启应保留屏蔽 UID。")
        for title in ["隐藏机器人帖子", "隐藏匿名内容", "使用网页话廊"] { toggle(title) }
    }

    @MainActor
    func testAboutLicenseUpdateAndResetConfirmation() {
        app = launchApp(resetStorage: true)
        openSettings("about")
        tap("开源声明")
        assertUI(app.navigationBars["开源声明"].appears(timeout: 5), "开源声明应打开正文。")
        app.swipeUp()
        back()
        toggle("自动检查更新")
        tap("检查更新")
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "离线更新检查应给出结果提示。")
        closeAlertIfPresent()
        tap("删除所有文稿与数据")
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "重置应要求确认。")
        app.alerts.buttons["取消"].tap()
        assertUI(app.tabBars.buttons["app.tab.mine"].exists, "取消重置应保留当前会话。")
    }

    @MainActor
    func testScoreVerificationValidationFiltersSortingAndDetail() {
        app = launchApp(resetStorage: true)
        app.tabBars.buttons["app.tab.home"].tap()
        app.buttons["score.query"].tap()
        let code = app.textFields["verification.code"]
        assertUI(code.appears(timeout: 5), "成绩查询应打开短信面板。")
        let submit = app.buttons["验证并查询成绩"]
        assertUI(!submit.isEnabled, "空验证码应禁用提交。")
        code.tap()
        code.typeText("000000")
        tap("验证并查询成绩")
        assertUI(app.staticTexts["测试验证码错误。"].appears(timeout: 5), "错误验证码应展示可重试提示。")
        replaceText("123456", in: code)
        tap("验证并查询成绩")
        assertUI(app.staticTexts["自动化测试课程"].appears(timeout: 5), "有效验证码应展示成绩。")
        for title in ["学期", "种类"] {
            tap(title)
            tap("全不选")
            assertUI(app.buttons["全选"].exists, "筛选应支持清空。")
            tap("全选")
            back()
        }
        tap("排序")
        assertUI(app.navigationBars["成绩排序"].appears(timeout: 5), "排序入口应打开索引和方向设置。")
        for title in ["名称", "成绩", "均分", "学分", "学期", "种类"] {
            let index = app.collectionViews.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
            reveal(index, description: title)
            index.tap()
            let selected = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND selected == true", title)).firstMatch
            assertUI(selected.exists, "排序索引应更新选中状态：\(title)")
        }
        let order = app.buttons["排序方向"]
        let initial = order.value as? String
        order.tap()
        assertUI(order.value as? String != initial, "排序方向应切换。")
        back()
        tap("自动化测试课程")
        assertUI(app.navigationBars["成绩详情"].appears(timeout: 5), "成绩行应打开详情。")
    }

    @MainActor
    func testGalleryFeedsSearchMessagesAndComposerDraft() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "固定服务应展示真实话题列表。")
        for title in ["关注", "最新", "最热", "机器人", "推荐"] {
            app.segmentedControls.buttons[title].tap()
            assertUI(app.segmentedControls.buttons[title].isSelected, "话题分栏应可选择：\(title)")
        }
        tap("搜索话廊")
        let search = app.textFields.firstMatch
        search.tap()
        search.typeText("测试\n")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "搜索应显示结果。")
        tap("清除搜索")
        assertUI(search.value as? String != "测试", "清除应重置搜索词。")
        tap("取消")
        tap("消息")
        for title in ["评论", "点赞", "关注", "系统"] {
            let segment = app.segmentedControls.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            segment.tap()
            assertUI(segment.isSelected, "消息分类应切换：\(title)")
        }
        tap("全部已读")
        tap("取消")
        tap("发布话题")
        tap("发布")
        assertUI(app.alerts["发布失败"].appears(timeout: 5), "空帖子应提示必填字段。")
        closeAlertIfPresent()
        let title = app.textFields["标题"]
        title.tap()
        title.typeText("测试草稿\n")
        tap("取消")
        tap("保存草稿")
        tap("发布话题")
        tap("加载草稿")
        assertUI(app.textFields["标题"].value as? String == "测试草稿", "重开编辑器应恢复草稿。")
        tap("取消")
        tap("不保存")
    }

    @MainActor
    func testGalleryPosterLikeCommentAndEditEntry() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        tap("自动化测试话题")
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "话题应打开详情。")
        tap("点赞帖子")
        assertUI(app.buttons["取消帖子点赞"].appears(timeout: 5), "点赞应更新操作状态。")
        tap("取消帖子点赞")
        tap("评论帖子")
        let field = app.textFields.firstMatch
        field.tap()
        field.typeText("测试新增评论\n")
        dismissKeyboard()
        tap("发送")
        assertUI(textElement("测试新增评论").appears(timeout: 5), "发送后应显示评论。")
        tap("编辑帖子")
        assertUI(app.navigationBars["编辑帖子"].appears(timeout: 5), "本人帖子应支持编辑。")
        tap("取消")
    }

    @MainActor
    func testGalleryComposerTagsSettingsPublishAndDelete() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        tap("发布话题")
        tap("活动")
        tap("聊天")
        tap("自定义")
        replaceText("临时标签\n", in: app.textFields["自定义标签"])
        dismissKeyboard()
        tap("删除标签")
        assertUI(!app.textFields["自定义标签"].exists, "删除应移除自定义标签输入行。")
        toggle("匿名发布")
        toggle("公开显示")
        toggle("公开显示")
        replaceText("测试发布的话题\n", in: app.textFields["标题"])
        replaceText("测试发布正文", in: app.textFields["正文"])
        dismissKeyboard()
        tap("发布")
        let poster = textElement("测试发布的话题")
        assertUI(poster.appears(timeout: 5), "发布应更新话廊列表。")
        poster.tap()
        tap("更多操作")
        tap("删除帖子")
        app.alerts.buttons["取消"].tap()
        assertUI(app.navigationBars["帖子详情"].exists, "取消删除应保留详情。")
        tap("更多操作")
        tap("删除帖子")
        app.alerts.buttons["删除"].tap()
        let deleted = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: poster)
        assertUI(XCTWaiter.wait(for: [deleted], timeout: 5) == .completed, "删除应移除刚发布的话题。")
    }

    @MainActor
    func testPosterReportAndCommentContextActions() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        tap("自动化测试话题")
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
        app.alerts.buttons["知道了"].tap()
        comment.press(forDuration: 1)
        tap("删除评论")
        app.alerts.buttons["取消"].tap()
        assertUI(comment.exists, "取消删除应保留评论。")
        comment.press(forDuration: 1)
        tap("删除评论")
        app.alerts.buttons["删除"].tap()
        let deleted = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: comment)
        assertUI(XCTWaiter.wait(for: [deleted], timeout: 5) == .completed, "确认删除应移除评论。")
    }

    @MainActor
    func testPaperPublishEditCommentAndDelete() {
        app = launchApp(resetStorage: true, content: true, animations: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        app.segmentedControls.buttons["文章"].tap()
        tap("发布文章")
        let paperComposer = app.navigationBars["发布文章"]
        for (title, text) in [("标题", "测试发布文章"), ("简介", "文章发布测试简介"), ("正文", "文章发布测试正文")] {
            replaceText(text, in: app.textFields[title])
            dismissKeyboard()
        }
        tap("发布")
        let published = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: paperComposer)
        assertUI(XCTWaiter.wait(for: [published], timeout: 5) == .completed, "文章发布后应关闭编辑窗口。")
        let paper = textElement("测试发布文章")
        assertUI(paper.appears(timeout: 5), "发布应更新文章列表。")
        paper.tap()
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5), "刚发布的文章应打开详情。")
        tap("评论文章")
        let commentComposer = app.navigationBars["发表评论"]
        assertUI(commentComposer.appears(timeout: 5), "评论入口应打开输入窗口。")
        replaceText("测试文章评论", in: app.textFields.firstMatch)
        dismissKeyboard()
        tap("发布")
        let commentSubmitted = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: commentComposer)
        assertUI(XCTWaiter.wait(for: [commentSubmitted], timeout: 5) == .completed, "评论提交后应关闭输入窗口。")
        reveal(textElement("测试文章评论"), description: "测试文章评论")
        assertUI(textElement("测试文章评论").exists, "提交应更新文章评论。")
        tap("更多操作")
        app.buttons["paper.detail.edit"].tap()
        let editor = app.navigationBars["编辑文章"]
        assertUI(editor.appears(timeout: 5), "文章菜单应打开编辑器。")
        assertUI(app.textFields["标题"].value as? String == "测试发布文章", "编辑应恢复文章标题。")
        assertUI(app.textFields["简介"].value as? String == "文章发布测试简介", "编辑应恢复文章简介。")
        assertUI(app.textFields["正文"].value as? String == "文章发布测试正文", "编辑应恢复详情页已解析的正文。")
        replaceText("测试修改文章", in: app.textFields["标题"])
        dismissKeyboard()
        tap("保存")
        let saved = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)
        assertUI(XCTWaiter.wait(for: [saved], timeout: 5) == .completed, "保存文章应返回详情。")
        assertUI(textElement("测试修改文章").appears(timeout: 5), "保存应更新文章详情。")
        assertUI(textElement("文章发布测试正文").exists, "修改标题应保留完整正文。")
        tap("更多操作")
        app.buttons["paper.detail.edit"].tap()
        assertUI(editor.appears(timeout: 5), "已保存文章应支持再次编辑。")
        replaceText("取消的文章修改", in: app.textFields["标题"])
        dismissKeyboard()
        tap("取消")
        let cancelled = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)
        assertUI(XCTWaiter.wait(for: [cancelled], timeout: 5) == .completed, "取消编辑应返回文章详情。")
        assertUI(textElement("测试修改文章").exists, "取消应保留已保存的文章标题。")
        tap("更多操作")
        tap("删除文章")
        app.alerts.buttons["取消"].tap()
        tap("更多操作")
        tap("删除文章")
        app.alerts.buttons["删除"].tap()
        assertUI(app.buttons["发布文章"].appears(timeout: 5), "删除应返回文章列表。")
        let article = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@", "测试修改文章", "测试发布文章"
        )).firstMatch
        let deleted = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: article)
        assertUI(XCTWaiter.wait(for: [deleted], timeout: 5) == .completed, "文章列表应移除删除的文章。")
    }

    @MainActor
    func testPaperSearchDetailLikeAndComposer() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        app.segmentedControls.buttons["文章"].tap()
        assertUI(textElement("自动化测试文章").appears(timeout: 5), "文章分区应展示固定文章。")
        tap("搜索文章")
        let search = app.textFields.firstMatch
        search.tap()
        search.typeText("文章\n")
        tap("清除搜索")
        tap("取消")
        tap("自动化测试文章")
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5), "文章行应打开详情。")
        tap("点赞文章")
        assertUI(app.buttons["取消文章点赞"].appears(timeout: 5), "文章点赞应更新状态。")
        tap("取消文章点赞")
        back()
        tap("发布文章")
        tap("发布")
        assertUI(app.alerts["发布失败"].appears(timeout: 5), "空文章应提示必填字段。")
        closeAlertIfPresent()
        assertUI(app.textFields["标题"].exists && app.textFields["简介"].exists, "文章编辑器应提供标题和简介。")
        toggle("匿名发布")
        tap("取消")
    }

    @MainActor
    func tap(_ title: String) {
        let exact = app.buttons.matching(NSPredicate(format: "label == %@", title))
        let matches = exact.firstMatch.exists ? exact : app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
        if let visible = matches.allElementsBoundByIndex.first(where: { isReadyForTap($0) }) {
            visible.tap()
            return
        }
        let button = matches.firstMatch
        reveal(button, description: title)
        button.tap()
    }

    @MainActor
    func testAccountSensitiveFieldsAndEditors() {
        app = launchApp(resetStorage: true, content: true)
        openSettings("account")
        let student = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "学号")).firstMatch
        assertUI(student.appears(timeout: 5), "固定账号应提供学号显示开关。")
        assertUI(student.value as? String == "已隐藏", "账号标识默认隐藏。")
        student.tap()
        waitForValue("ui-test-student", of: student)
        assertUI(student.value as? String == "ui-test-student", "点击后应显示当前账号。")
        student.tap()
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
        assertUI(app.buttons["取消"].appears(timeout: 5), "头像入口应打开照片选择器。")
        tap("取消")
    }

    @MainActor
    func testSuggestionDraftRestoreAndDiscard() {
        app = launchApp(resetStorage: true)
        openSettings("suggestion")
        let text = app.textFields["建议内容"]
        assertUI(text.appears(timeout: 5), "建议页应展示内容字段。")
        assertUI(!app.buttons["提交"].isEnabled, "空建议应禁用提交。")
        text.tap()
        text.typeText("自动化测试建议")
        dismissKeyboard()
        let contact = app.textFields["联系方式"]
        contact.tap()
        contact.typeText("测试联系信息")
        dismissKeyboard()
        tap("取消")
        tap("保存草稿")
        openSettings("suggestion")
        tap("加载草稿")
        assertUI(app.textFields["建议内容"].value as? String == "自动化测试建议", "建议草稿应恢复正文。")
        assertUI(app.textFields["联系方式"].value as? String == "测试联系信息", "建议草稿应恢复联系信息。")
        tap("取消")
        tap("不保存")
    }

    @MainActor
    func testCourseEditorFieldsPickersSaveDetailAndDelete() {
        app = launchApp(resetStorage: true)
        app.buttons["schedule.add-content"].tap()
        tap("添加课程")
        for (title, value) in [("课程名称", "测试补录课程"), ("教师", "测试教师"), ("教室", "文萃A101"), ("周次（如 1-16,18）", "1-3")] {
            let field = app.textFields[title]
            assertUI(field.exists, "课程编辑应支持字段：\(title)")
            replaceText(value, in: field)
            dismissKeyboard()
        }
        choose("星期", option: "周2")
        tap("开始节次")
        tap("第1节")
        tap("结束节次")
        tap("第2节")
        tap("确定")
        let course = textElement("测试补录课程")
        assertUI(course.appears(timeout: 5), "补录课程应显示在课表。")
        course.tap()
        tap("调这门课")
        assertUI(app.navigationBars["调这门课"].appears(timeout: 5), "调课应打开安排编辑器。")
        assertUI(app.textFields["房间号"].exists, "调课应支持地点编辑。")
        tap("取消")
        tap("删除这门课")
        app.alerts.buttons["取消"].tap()
        assertUI(app.buttons["删除这门课"].exists, "取消删除应保留课程详情。")
        tap("删除这门课")
        app.alerts.buttons["删除"].tap()
        assertUI(!course.exists, "确认删除应移除课程。")
        app.buttons["schedule.add-content"].tap()
        tap("添加课程")
        tap("取消")
        assertUI(app.buttons["schedule.add-content"].exists, "取消课程编辑应返回课表。")
    }

    @MainActor
    func testImportInvalidCodeReportsErrorAndKeepsEditor() {
        app = launchApp(resetStorage: true)
        let area = app.descendants(matching: .any).matching(identifier: "schedule.blank-context-menu").firstMatch
        area.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        tap("导入课表")
        let code = app.textViews["schedule.import.code"]
        assertUI(code.appears(timeout: 5), "导入应打开编码编辑器。")
        code.tap()
        code.typeText("invalid-code")
        dismissKeyboard()
        tap("导入")
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "无效编码应给出校验结果。")
        closeAlertIfPresent()
        assertUI(code.value as? String == "invalid-code", "校验失败应保留输入以供修改。")
        tap("取消")
    }

    @MainActor
    func testCourseSearchHistoryLikeAndRatingComposer() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.home"].tap()
        app.segmentedControls.buttons.element(boundBy: 1).tap()
        let search = app.textFields.firstMatch
        assertUI(search.appears(timeout: 5), "课程评价应提供搜索字段。")
        search.tap()
        search.typeText("测试\n")
        tap("自动化测试课程")
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "课程搜索应打开详情。")
        tap("点赞课程")
        assertUI(app.buttons["取消课程点赞"].appears(timeout: 5), "课程点赞应更新操作。")
        tap("取消课程点赞")
        tap("评论课程")
        let field = app.textFields.firstMatch
        assertUI(field.appears(timeout: 5), "课程评论应展示输入字段。")
        tap("评分 3.5 星")
        field.tap()
        field.typeText("测试课程评价\n")
        dismissKeyboard()
        tap("发送")
        let sent = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["发送"])
        assertUI(XCTWaiter.wait(for: [sent], timeout: 5) == .completed, "提交成功后应关闭评价窗口。")
        reveal(textElement("测试课程评价"), description: "测试课程评价")
        assertUI(textElement("测试课程评价").appears(timeout: 5), "提交评价应更新评论区。")
    }

    @MainActor
    func testMineFollowersFollowingsAndPosterRoutes() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.mine"].tap()
        assertUI(textElement("自动化测试用户").appears(timeout: 5), "我的页应加载固定资料。")
        for (entry, destination) in [("粉丝", "我的粉丝"), ("关注", "我的关注"), ("帖子", "我的帖子")] {
            tap(entry)
            assertUI(app.navigationBars[destination].appears(timeout: 5), "资料统计应打开对应列表：\(destination)")
            if entry == "粉丝" {
                tap("自动化测试用户")
                let follow = app.buttons["关注"]
                assertUI(follow.appears(timeout: 5), "用户行应打开可关注的公开主页。")
                follow.tap()
                assertUI(app.buttons["已关注"].appears(timeout: 5), "关注应更新主页状态。")
            }
            back()
        }
    }

    @MainActor
    func reveal(_ element: XCUIElement, description: String = "交互控件") {
        if isReadyForTap(element) { return }
        for _ in 0..<8 {
            let scroll: XCUIElement = app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable })
                ?? app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable })
                ?? app
            let upward = !element.exists || element.frame.minY >= app.windows.firstMatch.frame.midY
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: upward ? 0.1 : 0.9))
            start.press(forDuration: 0.01, thenDragTo: end)
            if isReadyForTap(element) { return }
        }
        assertUI(false, "滚动后目标应可触达：\(description)。\(focusedAccessibilitySnapshot(app, matching: [description, "Button", "Alert"]))")
    }

    @MainActor
    private func isReadyForTap(_ element: XCUIElement) -> Bool {
        guard element.exists && element.isHittable else { return false }
        let center = element.frame.midY
        let navigationBars = app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }
        let navigationBar = navigationBars.last
        let tabBar = app.tabBars.firstMatch
        let window = app.windows.firstMatch.frame
        let isPresentedPage = navigationBars.count > 1
        let top = navigationBar?.frame.maxY ?? window.minY
        let bottom = isPresentedPage ? window.maxY : (tabBar.exists && tabBar.isHittable ? tabBar.frame.minY : window.maxY)
        if center >= top && center <= bottom { return true }
        let predicate = NSPredicate(format: "label == %@", element.label)
        return navigationBar?.buttons.matching(predicate).firstMatch.exists == true
            || (!isPresentedPage && app.tabBars.buttons.matching(predicate).firstMatch.exists)
    }

    @MainActor
    func openSettings(_ route: String) {
        app.tabBars.buttons["app.tab.mine"].tap()
        let entry = app.buttons["settings.route.\(route)"]
        reveal(entry)
        entry.tap()
    }

    @MainActor
    func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }

    @MainActor
    func textElement(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    func waitForValue(_ value: String, of element: XCUIElement) {
        if element.value as? String == value { return }
        let updated = expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
        assertUI(XCTWaiter.wait(for: [updated], timeout: 5) == .completed, "交互应更新为\(value)，实际值：\(String(describing: element.value))。")
    }

    @MainActor @discardableResult
    func toggle(_ title: String) -> String {
        let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        reveal(control, description: title)
        let initial = control.value as? String
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        if control.value as? String == initial {
            let changed = expectation(for: NSPredicate(format: "value != %@", initial ?? ""), evaluatedWith: control)
            assertUI(XCTWaiter.wait(for: [changed], timeout: 5) == .completed, "开关应改变状态：\(title)")
        }
        return control.value as? String ?? ""
    }

    @MainActor
    func choose(_ title: String, option: String) {
        tap(title)
        tap(option)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        if row.label.hasSuffix(option) || row.value as? String == option { return }
        let selected = expectation(for: NSPredicate(format: "label ENDSWITH %@ OR value == %@", option, option), evaluatedWith: row)
        assertUI(XCTWaiter.wait(for: [selected], timeout: 5) == .completed, "选择应更新\(title)为\(option)。")
    }

    @MainActor
    func replaceText(_ text: String, in field: XCUIElement) {
        assertUI(field.appears(timeout: 5), "输入操作应等待字段出现。")
        reveal(field, description: field.placeholderValue ?? "文本输入")
        field.tap()
        if !app.keyboards.firstMatch.exists {
            let nextKeyboard = app.buttons.matching(NSPredicate(format: "label IN %@", ["下一个键盘", "Next keyboard"])).firstMatch
            if nextKeyboard.exists { nextKeyboard.tap() }
        }
        assertUI(app.keyboards.firstMatch.appears(timeout: 5), "文本输入应使用系统键盘。")
        let value = field.value as? String ?? ""
        if !value.isEmpty && value != field.placeholderValue {
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        app.typeText(text)
        let expected = text.trimmingCharacters(in: .newlines)
        if field.value as? String == expected { return }
        let entered = expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: field)
        assertUI(XCTWaiter.wait(for: [entered], timeout: 5) == .completed, "输入应完整替换文本，当前值：\(String(describing: field.value))。")
    }

    @MainActor
    func dismissKeyboard() {
        let button = app.buttons["keyboard.dismiss"]
        if button.exists {
            button.tap()
        } else if app.keyboards.firstMatch.exists,
                  let bar = app.navigationBars.allElementsBoundByIndex.last(where: { $0.isHittable }) {
            let window = app.windows.firstMatch
            let point = CGVector(dx: 0.01, dy: (bar.frame.maxY + 8 - window.frame.minY) / window.frame.height)
            window.coordinate(withNormalizedOffset: point).tap()
        }
        if app.keyboards.firstMatch.exists,
           let list = app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable }) {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.2))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        if app.keyboards.firstMatch.exists {
            let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
            assertUI(XCTWaiter.wait(for: [dismissed], timeout: 5) == .completed, "完成输入后键盘应收起。")
        }
    }

    @MainActor
    func closeAlertIfPresent() {
        guard app.alerts.firstMatch.appears(timeout: 2) else { return }
        let alert = app.alerts.firstMatch
        let close = alert.buttons["知道了"]
        if close.exists { close.tap() } else { alert.buttons.element(boundBy: 0).tap() }
    }

    @MainActor
    func testLoginFormTracksRequiredCredentialsAndOpensSchedule() throws {
        app = launchApp(resetStorage: true, account: nil)

        let studentID = app.textFields["login.student-id"]
        let password = app.secureTextFields["login.password"]
        let submit = app.buttons["login.submit"]

        assertUI(studentID.appears(timeout: 10), "登录页应展示学号输入框。")
        assertUI(password.exists, "登录页应展示密码输入框。")
        assertUI(!submit.isEnabled, "凭据完整前登录按钮应保持禁用。")

        replaceAccount("ui-test-student", in: studentID)
        studentID.typeText("\n")
        assertUI(!submit.isEnabled, "仅输入学号时登录按钮应保持禁用。")

        password.typeText("ui-test-password")
        assertUI(submit.isEnabled, "完整填写账号信息后，登录按钮应启用。")
        password.typeText("\n")
        dismissCredentialSavePrompt(in: app)
        let scheduleTab = app.tabBars.buttons["app.tab.schedule"]
        assertUI(scheduleTab.appears(timeout: 10), "登录后应进入日程页。")
        assertUI(scheduleTab.isSelected, "日程 Tab 应处于选中状态。")
    }

    @MainActor
    func testSchoolDDLSourcesAndCompletionPersistAcrossAppRelaunch() throws {
        app = launchApp(resetStorage: true, ddlFixture: "sources")
        let ddl = app.segmentedControls.buttons["DDL"]
        assertUI(ddl.appears(timeout: 10), "日程页应展示 DDL 分页。")
        ddl.tap()
        let eclass = app.staticTexts["课程中心测试作业"]
        assertUI(eclass.appears(timeout: 5), "DDL 页应展示课程中心作业。")
        assertUI(app.staticTexts["乐学测试日程"].exists, "DDL 页应展示乐学日程。")
        let completion = app.buttons["ddl.done.eclass:ui"]
        assertUI(completion.exists, "课程中心作业应提供完成状态操作。")
        completion.tap()
        assertUI(completion.value as? String == "已完成", "点击后应保存完成状态。")
        eclass.tap()
        assertUI(app.navigationBars["DDL 详情"].appears(timeout: 5), "课程中心作业应打开详情。")
        assertUI(app.staticTexts["课程中心"].exists, "详情应显示中文来源。")
        assertUI(!app.buttons["编辑"].exists && !app.buttons["删除"].exists, "学校作业应按同步来源展示。")
        app.buttons["取消"].tap()
        app.terminate()
        app = launchApp(resetStorage: false)
        app.segmentedControls.buttons["DDL"].tap()
        let restored = app.buttons["ddl.done.eclass:ui"]
        assertUI(restored.appears(timeout: 5), "重新启动后应恢复课程中心作业。")
        assertUI(restored.value as? String == "已完成", "重新启动后应恢复完成状态。")
    }

    @MainActor
    func testDDLEmptyStateExplainsTheRetentionWindow() throws {
        app = launchApp(resetStorage: true, ddlFixture: "overdue")
        app.segmentedControls.buttons["DDL"].tap()
        let explanation = app.staticTexts["1 条日程已超出显示范围。当前滞留天数为 0 天，可在 DDL 设置调整。"]
        assertUI(explanation.appears(timeout: 5), "过期日程的空列表应说明当前显示范围。")
    }

    @MainActor
    func testLongPressOpensScheduleContextMenuAndImportSheet() throws {
        app = launchApp(resetStorage: true)

        let contextArea = app.descendants(matching: .any)
            .matching(identifier: "schedule.blank-context-menu")
            .firstMatch
        assertUI(contextArea.appears(timeout: 10), "日程页面应展示可操作的空白课表区域。")
        contextArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)

        let shareAction = app.buttons["分享课表"]
        let importAction = app.buttons["导入课表"]
        assertUI(
            shareAction.appears(timeout: 5),
            "长按课表区域后应展示分享操作。\(focusedAccessibilitySnapshot(app, matching: ["分享", "导入", "课表", "menu"]))"
        )
        assertUI(importAction.exists, "长按课表区域后应展示导入操作。")

        importAction.tap()
        assertUI(app.navigationBars["导入课表"].appears(timeout: 5), "点按导入后应打开导入课表面板。")
        assertUI(app.textViews["schedule.import.code"].exists, "导入面板应展示课表编码编辑区。")
    }

    @MainActor
    func testManualSchedulePersistsAcrossAppRelaunch() throws {
        app = launchApp(resetStorage: true)

        addCustomSchedule("自动化测试日程", in: app)

        app.terminate()
        app = launchApp(resetStorage: false)
        assertUI(app.tabBars.buttons["app.tab.schedule"].appears(timeout: 10), "重新启动后应恢复测试登录会话。")
        let savedSchedule = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "自动化测试日程"))
            .firstMatch
        assertUI(
            savedSchedule.appears(timeout: 10),
            "重新启动后应恢复已保存的自定义日程。\(focusedAccessibilitySnapshot(app, matching: ["自动化测试日程", "课表"]))"
        )
    }

    @MainActor
    func testCustomSchedulesAreIsolatedBetweenAccounts() throws {
        app = launchApp(resetStorage: true, account: "ui-test-account-a")
        addCustomSchedule("A 账户专属日程", in: app)

        app.tabBars.buttons["app.tab.mine"].tap()
        let accountRoute = app.buttons["settings.route.account"]
        assertUI(accountRoute.appears(timeout: 10), "我的页面应展示账号设置入口。")
        accountRoute.tap()

        let logout = app.buttons["settings.account.logout"]
        assertUI(logout.appears(timeout: 5), "账号设置应展示退出操作。")
        logout.tap()

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
    func addCustomSchedule(_ titleText: String, in application: XCUIApplication) {
        let addContent = application.buttons["schedule.add-content"]
        assertUI(addContent.appears(timeout: 10), "课表页应展示添加内容入口。")
        assertUI(
            addContent.isHittable,
            "添加入口应处于可点击位置。frame=\(addContent.frame); \(focusedAccessibilitySnapshot(application, matching: ["Window", "Alert", "Sheet", "Menu", "添加", "课表", "保存", "密码", "之后", "稍后", "现在"]))"
        )
        addContent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let addSchedule = application.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "添加日程"))
            .firstMatch
        assertUI(
            addSchedule.appears(timeout: 5),
            "添加菜单应展示自定义日程操作。\(focusedAccessibilitySnapshot(application, matching: ["添加", "日程"]))"
        )
        addSchedule.tap()

        let title = application.textFields["schedule.custom.title"]
        assertUI(title.appears(timeout: 5), "自定义日程面板应展示标题输入框。")
        title.tap()
        title.typeText("\(titleText)\n")

        let save = application.buttons["schedule.custom.save"]
        assertUI(save.appears(timeout: 5), "自定义日程面板应展示保存操作。")
        save.tap()
        let savedSchedule = application.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", titleText))
            .firstMatch
        assertUI(
            savedSchedule.appears(timeout: 10),
            "保存后课表应展示新建的自定义日程。\(focusedAccessibilitySnapshot(application, matching: [titleText, "保存", "确定", "日程", "课表"]))"
        )
    }

    @MainActor
    func testMainTabsNavigateWithOfflineServices() throws {
        app = launchApp(resetStorage: true)

        for identifier in ["app.tab.schedule", "app.tab.map", "app.tab.home", "app.tab.gallery", "app.tab.mine"] {
            let tab = app.tabBars.buttons[identifier]
            assertUI(tab.appears(timeout: 10), "App 主 Tab 应可交互：\(identifier)")
            tab.tap()
            assertUI(
                tab.isSelected,
                "点按后应选中对应的 App Tab：\(identifier)。\(focusedAccessibilitySnapshot(app, matching: ["登录", "我的", "个人", "账号", "失败"]))"
            )
            if identifier == "app.tab.gallery" {
                let offlineAlert = app.alerts["加载话廊失败"]
                assertUI(offlineAlert.appears(timeout: 10), "离线话廊请求应展示可关闭的失败提示。")
                let close = offlineAlert.buttons["知道了"]
                assertUI(close.exists, "话廊失败提示应提供关闭操作。")
                close.tap()
            }
        }
    }

    @MainActor
    func testMainTabsRemainAccessibleAtAccessibilityDynamicType() throws {
        for style in ["Light", "Dark"] {
            app = launchApp(
                resetStorage: true,
                accessibilityTextSize: true,
                userInterfaceStyle: style
            )
            assertMainTabsRemainAccessible(style: style)
            app.terminate()
        }
    }

    @MainActor
    private func assertMainTabsRemainAccessible(style: String) {
        let window = app.windows.firstMatch
        for identifier in ["app.tab.schedule", "app.tab.map", "app.tab.home", "app.tab.gallery", "app.tab.mine"] {
            let tab = app.tabBars.buttons[identifier]
            assertUI(tab.appears(timeout: 10), "辅助功能大字号下主 Tab 应可见：\(identifier)")
            tab.tap()
            assertUI(tab.isSelected, "辅助功能大字号下点按后应选中对应 Tab：\(identifier)")
            if identifier == "app.tab.gallery" {
                let offlineAlert = app.alerts["加载话廊失败"]
                assertUI(offlineAlert.appears(timeout: 10), "离线话廊请求应展示失败提示。")
                offlineAlert.buttons["知道了"].tap()
            }
            let tabFrame = tab.frame
            let windowFrame = window.frame
            let tabIsHittable = tab.isHittable
            let tabLabel = tab.label
            assertUI(
                window.exists && tabIsHittable && windowFrame.contains(tabFrame) && tabLabel.count > 0,
                "辅助功能大字号下 Tab 应保持可见、可触达并具有名称：\(identifier)；window=\(windowFrame)，tab=\(tabFrame)，hittable=\(tabIsHittable)，label=\(tabLabel)"
            )
            let contentTarget: XCUIElement?
            let contentDescription: String
            switch identifier {
            case "app.tab.schedule":
                contentTarget = app.descendants(matching: .any)
                    .matching(identifier: "schedule.blank-context-menu")
                    .firstMatch
                contentDescription = "课表空白操作区"
            case "app.tab.home":
                contentTarget = app.buttons["score.query"]
                contentDescription = "成绩查询操作"
            case "app.tab.mine":
                contentTarget = app.buttons["settings.route.account"]
                contentDescription = "账号设置入口"
            default:
                contentTarget = nil
                contentDescription = ""
            }
            if let contentTarget {
                assertUI(
                    contentTarget.appears(timeout: 10),
                    "辅助功能大字号与\(style)外观下应展示\(contentDescription)"
                )
                let contentFrame = contentTarget.frame
                assertUI(
                    contentTarget.isHittable && windowFrame.contains(contentFrame),
                    "\(contentDescription)应位于可见窗口且保持可触达：\(contentFrame)"
                )
            }
        }
    }

    @MainActor
    func testScoreChallengeContinuesAfterSMSVerification() throws {
        app = launchApp(resetStorage: true)
        let scoreTab = app.tabBars.buttons["app.tab.home"]
        scoreTab.tap()
        assertUI(
            scoreTab.isSelected,
            "成绩 Tab 应在点按后选中。\(focusedAccessibilitySnapshot(app, matching: ["成绩", "日程", "查询", "刷新", "Selected"]))"
        )
        let queryScores = app.buttons["score.query"]
        assertUI(
            queryScores.appears(timeout: 10),
            "成绩页应展示查询操作。\(focusedAccessibilitySnapshot(app, matching: ["成绩", "查询", "刷新", "短信", "失败", "错误"]))"
        )
        queryScores.tap()

        let verificationCode = app.textFields["verification.code"]
        assertUI(
            verificationCode.appears(timeout: 10),
            "成绩查询遇到二次验证时应展示验证码输入框。\(focusedAccessibilitySnapshot(app, matching: ["验证", "短信", "成绩", "查询", "失败", "错误"]))"
        )
        verificationCode.typeText("123456")

        let verify = app.buttons["验证并查询成绩"]
        assertUI(verify.appears(timeout: 5), "短信验证面板应展示继续查询操作。")
        tap("验证并查询成绩")
        assertUI(app.staticTexts["自动化测试课程"].appears(timeout: 10), "短信验证后成绩列表应展示测试课程。")
    }

    @MainActor
    func signIn(_ application: XCUIApplication, studentID inputStudentID: String = "ui-test-student") {
        let studentID = application.textFields["login.student-id"]
        let password = application.secureTextFields["login.password"]
        let submit = application.buttons["login.submit"]
        assertUI(studentID.appears(timeout: 10), "测试启动后应展示登录页。")

        replaceAccount(inputStudentID, in: studentID)
        studentID.typeText("\n")
        password.typeText("ui-test-password")
        assertUI(submit.isEnabled, "完整填写账号信息后，登录按钮应启用。")
        password.typeText("\n")
        dismissCredentialSavePrompt(in: application)
        assertUI(
            application.tabBars.buttons["app.tab.schedule"].appears(timeout: 10),
            "登录后应进入日程页。"
        )
        let scheduleReady = application.descendants(matching: .any)
            .matching(identifier: "schedule.blank-context-menu")
            .firstMatch
        assertUI(scheduleReady.appears(timeout: 10), "日程缓存与课表网格应完成首屏加载。")
    }

    @MainActor
    private func replaceAccount(_ value: String, in field: XCUIElement) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let existingValue = field.value as? String ?? ""
        if !existingValue.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingValue.count))
        }
        field.typeText(value)
        assertUI(field.value as? String == value, "账号输入框应完整替换为指定测试账号。")
    }

    @MainActor
    private func dismissCredentialSavePrompt(in application: XCUIApplication) {
        let prompt = application.sheets["保存密码？"]
        guard prompt.exists else { return }
        let nonSavingActions = ["取消", "不保存", "稍后", "暂不", "以后", "以后再说", "稍后再说", "关闭"]
        let buttons = prompt.buttons.allElementsBoundByIndex
        guard let dismissAction = buttons.first(where: { nonSavingActions.contains($0.label) }) else {
            let labels = buttons.map(\.label).joined(separator: "、")
            assertUI(false, "系统密码提示应提供安全关闭操作。按钮：\(labels)")
            return
        }
        dismissAction.tap()
        assertUI(!prompt.exists, "合成测试凭据的系统保存提示应自动收起。")
    }

    @MainActor
    func assertUI(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !condition() else { return }
        var diagnostics = ""
        if let application = app {
            let hierarchy = XCTAttachment(string: application.debugDescription)
            hierarchy.name = "失败时的界面元素树"
            add(hierarchy)
            if application.state == .runningForeground {
                let screenshot = XCTAttachment(screenshot: application.screenshot())
                screenshot.name = "失败时的界面截图"
                add(screenshot)
            }
            diagnostics = focusedAccessibilitySnapshot(application, matching: ["Alert", "NavigationBar", "TextField"])
        }
        XCTFail("\(message()) \(diagnostics)", file: file, line: line)
    }

    @MainActor
    private func assertInteractiveLabelIsColored(_ title: String) {
        let label = app.staticTexts[title]
        assertUI(label.appears(timeout: 5), "交互行应展示左侧标题：\(title)")
        let screenshot = app.screenshot().image.cgImage!
        let window = app.windows.firstMatch.frame
        let scale = CGFloat(screenshot.width) / window.width
        let bounds = label.frame
        let rectangle = CGRect(x: (bounds.minX - window.minX) * scale, y: (bounds.minY - window.minY) * scale,
                               width: bounds.width * scale, height: bounds.height * scale).integral
        guard let glyphs = screenshot.cropping(to: rectangle) else {
            assertUI(false, "左侧标题应位于可见截图中：\(title)")
            return
        }
        let width = glyphs.width
        let height = glyphs.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colored = pixels.withUnsafeMutableBytes { bytes -> Int in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(glyphs, in: CGRect(x: 0, y: 0, width: width, height: height))
            return stride(from: 0, to: bytes.count, by: 4).filter { offset in
                let channels = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
                return channels.max()! - channels.min()! > 50
            }.count
        }
        assertUI(colored >= 10, "\(title)的左侧字形应包含页面主题色或警示色，当前彩色像素：\(colored)。")
    }

    @MainActor
    private func focusedAccessibilitySnapshot(
        _ application: XCUIApplication,
        matching terms: [String]
    ) -> String {
        let lines = application.debugDescription.split(separator: "\n")
        var seen = Set<Substring>()
        let matches = terms.flatMap { term in
            lines.filter { $0.contains(term) && seen.insert($0).inserted }
        }.prefix(24)
        return matches.isEmpty ? "界面元素树中未检索到目标文案。" : matches.joined(separator: " | ")
    }

    @MainActor
    func launchApp(
        resetStorage: Bool,
        account: String? = "ui-test-student",
        accessibilityTextSize: Bool = false,
        userInterfaceStyle: String? = nil,
        ddlFixture: String? = nil,
        content: Bool = false,
        animations: Bool = false,
        school: Bool = false,
        media: Bool = false,
        failureOnce: Bool = false,
        update: String? = nil,
        schoolSMS: Bool = false
    ) -> XCUIApplication {
        continueAfterFailure = false
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing"]
        if accessibilityTextSize {
            application.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityL",
            ]
        }
        if let userInterfaceStyle {
            application.launchArguments += ["-UIUserInterfaceStyle", userInterfaceStyle]
        }
        application.launchEnvironment["BIT101_UI_TESTING"] = "1"
        application.launchEnvironment["BIT101_UI_TEST_CONTENT"] = content ? "1" : "0"
        application.launchEnvironment["BIT101_UI_TEST_ANIMATIONS"] = animations ? "1" : "0"
        application.launchEnvironment["BIT101_UI_TEST_SCHOOL"] = school ? "1" : "0"
        application.launchEnvironment["BIT101_UI_TEST_MEDIA"] = media ? "1" : "0"
        application.launchEnvironment["BIT101_UI_TEST_FAILURE_ONCE"] = failureOnce ? "1" : "0"
        if let update { application.launchEnvironment["BIT101_UI_TEST_UPDATE"] = update }
        application.launchEnvironment["BIT101_UI_TEST_SCHOOL_SMS"] = schoolSMS ? "1" : "0"
        application.launchEnvironment["BIT101_UI_TEST_RUN_ID"] = runIdentifier
        application.launchEnvironment["BIT101_UI_TEST_RESET_STORAGE"] = resetStorage ? "1" : "0"
        if let ddlFixture { application.launchEnvironment["BIT101_UI_TEST_DDL_FIXTURE"] = ddlFixture }
        if resetStorage, let account {
            application.launchEnvironment["BIT101_UI_TEST_ACCOUNT"] = account
        }
        application.launch()
        app = application
        if account != nil {
            let scheduleReady = application.descendants(matching: .any)
                .matching(identifier: "schedule.blank-context-menu").firstMatch
            assertUI(scheduleReady.appears(timeout: 10), "测试会话与课表应完成加载。")
        }
        return application
    }
}


@MainActor
extension XCUIElement {
    func appears(timeout: TimeInterval) -> Bool {
        exists || waitForExistence(timeout: timeout)
    }
}
