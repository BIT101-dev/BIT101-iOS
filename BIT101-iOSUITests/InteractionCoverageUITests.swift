import XCTest
import CoreGraphics

nonisolated extension LoginAndScheduleUITests {
    @MainActor
    @objc func testCalendarReminderCloudSwitchesAndLeadTimePersistence() {
        app = launchApp(resetStorage: true)
        openSettings("calendar")
        let sync = toggle("iCloud 多端同步")
        let preferences = toggle("同步设置与使用偏好（实验性）")
        let reminderControl = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "显示灵动岛提醒（实验性）")).firstMatch
        reveal(reminderControl)
        reminderControl.tap()
        app.alerts["实验性功能提醒"].buttons["取消"].tap()
        waitForValue("0", of: reminderControl)
        reminderControl.tap()
        app.alerts["实验性功能提醒"].buttons["继续打开"].tap()
        waitForValue("1", of: reminderControl)
        let reminder = reminderControl.value as? String ?? ""
        tap("提前显示阈值")
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "15 分钟")
        tap("取消")
        tap("提前显示阈值")
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "20 分钟")
        tap("完成")
        app.terminate()
        app = launchApp(resetStorage: false)
        openSettings("calendar")
        for (title, value) in [("iCloud 多端同步", sync), ("同步设置与使用偏好（实验性）", preferences)] {
            let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            reveal(control)
            waitForValue(value, of: control)
            toggle(title)
        }
        let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "显示灵动岛提醒（实验性）")).firstMatch
        reveal(control)
        waitForValue(reminder, of: control)
        tap("提前显示阈值")
        waitForValue("20 分钟", of: app.pickerWheels.firstMatch)
        tap("取消")
    }

    @MainActor
    @objc func testTimeTableValidationSaveCancelAndRenameCancellation() {
        app = launchApp(resetStorage: true)
        openSettings("calendar")
        tap("时间表")
        let editor = app.textViews.firstMatch
        replaceText("invalid", in: editor)
        dismissKeyboard()
        tap("确定")
        assertUI(app.alerts["保存失败"].appears(timeout: 5), "错误时间表应展示校验结果。")
        closeAlertIfPresent()
        replaceText("08:00,08:45\n09:00,09:45", in: editor)
        dismissKeyboard()
        tap("确定")
        tap("时间表")
        assertUI((editor.value as? String ?? "").contains("08:00"), "保存应恢复新时间表。")
        replaceText("10:00,10:45", in: editor)
        dismissKeyboard()
        tap("取消")
        tap("时间表")
        assertUI((editor.value as? String ?? "").contains("08:00"), "取消应保留已保存时间表。")
        tap("取消")
        let name = app.buttons["schedule.settings.primary-name"]
        reveal(name)
        name.tap()
        replaceText("取消的名称", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("取消")
        assertUI(!name.label.contains("取消的名称"), "取消改名应保留课表名称。")
    }

    @MainActor
    @objc func testSchoolTermsClassroomPickersRefreshAndDDLRefresh() {
        app = launchApp(resetStorage: true, school: true)
        openSettings("calendar")
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
        app.tabBars.buttons["app.tab.schedule"].tap()
        app.segmentedControls.buttons["空教室"].tap()
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
        app.tabBars.buttons["app.tab.schedule"].tap()
        app.segmentedControls.buttons["DDL"].tap()
        tap("课程中心测试作业")
        assertUI(textElement("刷新后的学校详情").appears(timeout: 5), "学校刷新应更新详情正文。")
        tap("取消")
    }

    @MainActor
    @objc func testCourseArrangementSelectionsSaveAndOccurrenceDeletion() {
        app = launchApp(resetStorage: true, school: true)
        tap("学校测试课程")
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
        app.alerts.buttons["取消"].tap()
        assertUI(app.buttons["删除这节课"].exists, "取消应保留课节。")
        tap("删除这节课")
        app.alerts.buttons["删除"].tap()
        tap("第3周")
        assertUI(textElement("学校测试课程").appears(timeout: 5), "删除单节应保留其余周次。")
    }

    @MainActor
    @objc func testCourseAndExamSystemCalendarActions() {
        app = launchApp(resetStorage: true, school: true)
        tap("学校测试课程")
        for (action, result) in [("导入这节课到日历", "已导入系统日历"), ("移除这节课日历事件", "已移除系统日历事件"),
                                 ("导入这门课到日历", "已导入系统日历"), ("移除这门课日历事件", "已移除系统日历事件"),
                                 ("移除这门课日历事件", "无需移除")] {
            tap(action)
            assertUI(app.alerts[result].appears(timeout: 5), "日历动作应展示对应结果：\(action)。")
            closeAlertIfPresent()
        }
        tap("取消")
        tap("考试，测试考试")
        tap("导入考试到日历")
        assertUI(app.alerts["已导入系统日历"].appears(timeout: 5), "考试应支持日历导入。")
        closeAlertIfPresent()
        tap("移除考试日历事件")
        assertUI(app.alerts["已移除系统日历事件"].appears(timeout: 5), "考试应支持日历移除。")
        closeAlertIfPresent()
        tap("取消")
        openSettings("calendar")
        tap("导入到系统日历")
        app.alerts.buttons["导入并替换本学期旧事件"].tap()
        assertUI(app.alerts["导入成功"].appears(timeout: 5), "整学期导入确认应展示成功结果。")
        closeAlertIfPresent()
        tap("删除已导入的日历")
        app.alerts.buttons["删除"].tap()
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "整学期移除应展示结果。")
        closeAlertIfPresent()
    }

    @MainActor
    @objc func testCustomScheduleDetailsValidationAndCalendarActions() {
        app = launchApp(resetStorage: true)
        app.buttons["schedule.add-content"].tap()
        tap("添加日程")
        tap("确定")
        assertUI(app.alerts["保存失败"].appears(timeout: 5), "空标题应展示日程校验结果。")
        closeAlertIfPresent()
        replaceText("详细测试日程", in: app.textFields["schedule.custom.title"])
        replaceText("测试地点", in: app.textFields["副标题（通常为地点）"])
        replaceText("测试描述", in: app.textFields["描述（详情页显示）"])
        dismissKeyboard()
        tap("确定")
        tap("自定义日程，详细测试日程")
        assertUI(textElement("测试描述").appears(timeout: 5), "详情应恢复描述。")
        tap("导入到系统日历")
        assertUI(app.alerts["已导入系统日历"].appears(timeout: 5), "自定义日程应支持日历导入。")
        closeAlertIfPresent()
        tap("移除日历事件")
        assertUI(app.alerts["已移除系统日历事件"].appears(timeout: 5), "自定义日程应支持日历移除。")
        closeAlertIfPresent()
        tap("取消")
    }

    @MainActor
    @objc func testScoreIndividualFiltersRefreshCancelAndPendingDetail() {
        app = launchApp(resetStorage: true, content: true, school: true)
        app.tabBars.buttons["app.tab.home"].tap()
        app.buttons["score.query"].tap()
        tap("取消")
        assertUI(app.buttons["score.query"].isEnabled, "取消短信应恢复查询入口。")
        app.buttons["score.query"].tap()
        replaceText("123456", in: app.textFields["verification.code"])
        tap("验证并查询成绩")
        assertUI(textElement("自动化测试课程").appears(timeout: 5), "短信提交应加载成绩。")
        for (route, option) in [("学期", "ui-test-term"), ("种类", "必修")] {
            tap(route)
            let item = app.buttons.matching(NSPredicate(format: "label == %@", option)).firstMatch
            item.tap()
            waitForValue("未选", of: item)
            back()
            reveal(textElement("当前筛选条件下暂无成绩。"))
            assertUI(textElement("当前筛选条件下暂无成绩。").exists, "取消单项选择应过滤成绩。")
            tap(route)
            item.tap()
            waitForValue("已选", of: item)
            back()
        }
        app.buttons["score.query"].tap()
        replaceText("123456", in: app.textFields["verification.code"])
        tap("验证并查询成绩")
        assertUI(textElement("自动化测试课程").appears(timeout: 5), "已有成绩刷新应恢复成绩列表。")
        tap("学校测试课程")
        assertUI(app.navigationBars["成绩详情"].appears(timeout: 5), "未出分课程应打开详情。")
        back()
        tap("自动化测试课程")
        tap("课程评价")
        assertUI(app.segmentedControls.buttons["课程"].isSelected, "成绩详情应进入课程搜索。")
    }

    @MainActor
    @objc func testTrustedTranscriptSMSRetryPreviewAndCancellation() {
        app = launchApp(resetStorage: true)
        app.tabBars.buttons["app.tab.home"].tap()
        tap("申请可信成绩单")
        tap("取消")
        tap("重试")
        let code = app.textFields["verification.code"]
        replaceText("000000", in: code)
        tap("验证并申请成绩单")
        assertUI(textElement("测试验证码错误。").appears(timeout: 5), "成绩单短信应支持错误重试。")
        replaceText("123456", in: code)
        tap("验证并申请成绩单")
        tap("可信成绩单第1页")
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["完成", "Done"])).firstMatch
        assertUI(done.appears(timeout: 5), "成绩单图片应打开系统预览。")
        app.swipeLeft()
        app.swipeRight()
        done.tap()
        assertUI(app.navigationBars["可信成绩单"].appears(timeout: 5), "关闭预览应返回成绩单。")
        reveal(app.buttons["可信成绩单第2页"])
        app.buttons["可信成绩单第2页"].tap()
        assertUI(done.appears(timeout: 5), "第二页应可独立预览。")
        done.tap()
    }

    @MainActor
    @objc func testGalleryEditSaveClaimAndDiscardedDraft() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        tap("自动化测试话题")
        tap("编辑帖子")
        replaceText("保存后的测试话题", in: app.textFields["标题"])
        replaceText("保存后的话题正文", in: app.textFields["正文"])
        dismissKeyboard()
        choose("声明", option: "日常")
        tap("保存")
        assertUI(textElement("保存后的测试话题").appears(timeout: 5), "保存应刷新详情标题。")
        assertUI(textElement("保存后的话题正文").exists, "保存应刷新正文。")
        back()
        tap("发布话题")
        replaceText("待丢弃草稿", in: app.textFields["标题"])
        dismissKeyboard()
        tap("取消")
        tap("保存草稿")
        tap("发布话题")
        tap("不加载")
        assertUI(app.textFields["标题"].value as? String != "待丢弃草稿", "丢弃草稿应保留空编辑器。")
        tap("取消")
    }

    @MainActor
    @objc func testCommunityCommentLikesRepliesSortsAndPhotoPicker() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        tap("自动化测试话题")
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
        app.segmentedControls.buttons["文章"].tap()
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
    }

    @MainActor
    @objc func testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        app.segmentedControls.buttons["推荐"].tap()
        let list = app.scrollViews.firstMatch
        list.swipeLeft()
        assertUI(app.segmentedControls.buttons["关注"].isSelected, "话题横滑应切换分类。")
        list.swipeRight()
        assertUI(app.segmentedControls.buttons["推荐"].isSelected, "反向横滑应恢复分类。")
        tap("消息")
        assertUI(textElement("自动化测试消息").appears(timeout: 5), "消息面板应完成首屏加载。")
        app.collectionViews.firstMatch.swipeLeft()
        let likes = app.segmentedControls.buttons.matching(NSPredicate(format: "label CONTAINS %@", "点赞")).firstMatch
        assertUI(likes.isSelected, "消息横滑应切换到点赞分类。")
        app.collectionViews.firstMatch.swipeRight()
        let comments = app.segmentedControls.buttons.matching(NSPredicate(format: "label CONTAINS %@", "评论")).firstMatch
        assertUI(comments.isSelected, "消息反向横滑应恢复评论分类。")
        tap("自动化测试消息")
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "消息行应打开关联帖子。")
        back()
        tap("取消")
        tap("搜索话廊")
        replaceText("测试\n", in: app.textFields.firstMatch)
        tap("自动化测试话题")
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "搜索结果应打开详情。")
        back()
        tap("取消")
        app.segmentedControls.buttons["文章"].tap()
        for title in ["最新", "高赞", "热评"] {
            app.segmentedControls.buttons[title].tap()
            assertUI(app.segmentedControls.buttons[title].isSelected, "文章排序应更新选中项。")
        }
        tap("搜索文章")
        replaceText("文章\n", in: app.textFields.firstMatch)
        tap("自动化测试文章")
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5), "文章搜索结果应打开详情。")
    }

    @MainActor
    @objc func testAccountProfileSaveLoginCheckAndLogout() {
        app = launchApp(resetStorage: true, content: true)
        openSettings("account")
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
        app = launchApp(resetStorage: true)
        openSettings("suggestion")
        tap("插入图片")
        tap("取消")
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
        app = launchApp(resetStorage: true)
        addCustomSchedule("重置测试日程", in: app)
        openSettings("gallery")
        replaceText("64", in: app.textFields["缓存上限"])
        dismissKeyboard()
        app.terminate()
        app = launchApp(resetStorage: false)
        openSettings("gallery")
        let limit = app.textFields["缓存上限"]
        reveal(limit)
        waitForValue("64", of: limit)
        back()
        openSettings("about")
        tap("清理缓存")
        assertUI(app.alerts["清理完成"].appears(timeout: 5), "缓存清理应展示结果。")
        closeAlertIfPresent()
        tap("删除所有文稿与数据")
        app.alerts.buttons["删除"].tap()
        assertUI(app.textFields["login.student-id"].appears(timeout: 10), "确认重置应返回登录页。")
        signIn(app)
        assertUI(!textElement("重置测试日程").exists, "重置应移除隔离账号日程。")
    }

    @MainActor
    @objc func testCommunityMediaPreviewsDraftRetryAndRemoval() {
        app = launchApp(resetStorage: true, content: true, media: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        tap("查看第1张图片")
        closeImagePreview()
        tap("自动化测试话题")
        tap("图片 1")
        closeImagePreview()
        tap("查看评论图片，第1张，共1张")
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
        tap("取消")
        tap("取消")
        tap("不保存")
        openSettings("suggestion")
        tap("加载草稿")
        tap("移除图片")
        assertUI(!app.buttons["移除图片"].exists, "建议草稿应支持移除图片。")
        tap("取消")
        tap("不保存")
        app.tabBars.buttons["app.tab.mine"].tap()
        tap("查看头像")
        closeImagePreview()
    }

    @MainActor
    private func closeImagePreview() {
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["完成", "Done"])).firstMatch
        assertUI(done.appears(timeout: 5), "图片交互应进入系统 Quick Look。")
        done.tap()
    }

    @MainActor
    @objc func testPaperImagePreviewCommentsSortAndShare() {
        app = launchApp(resetStorage: true, content: true, media: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        app.segmentedControls.buttons["文章"].tap()
        tap("自动化测试文章")
        let link = app.links["正文链接"]
        reveal(link)
        link.tap()
        assertOpenedURL("github.com/BIT101-dev/BIT101-iOS")
        tap("文章图片：测试图片")
        closeImagePreview()
        let footerLike = app.buttons["paper.detail.footer-like"]
        reveal(footerLike)
        footerLike.tap()
        let headerLike = app.buttons["paper.detail.header-like"]
        let liked = expectation(for: NSPredicate(format: "label == %@", "取消文章点赞"), evaluatedWith: headerLike)
        assertUI(XCTWaiter.wait(for: [liked], timeout: 5) == .completed, "正文末尾点赞应同步顶部状态。")
        footerLike.tap()
        let unliked = expectation(for: NSPredicate(format: "label == %@", "点赞文章"), evaluatedWith: headerLike)
        assertUI(XCTWaiter.wait(for: [unliked], timeout: 5) == .completed, "正文末尾取消点赞应同步顶部状态。")
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
        app = launchApp(resetStorage: true, content: true, media: true)
        app.tabBars.buttons["app.tab.home"].tap()
        app.segmentedControls.buttons["课程"].tap()
        replaceText("测试\n", in: app.textFields.firstMatch)
        tap("清除搜索")
        tap("自动化测试课程")
        let cleaning = app.buttons["数据清洗"]
        let original = cleaning.value as? String
        cleaning.tap()
        assertUI(cleaning.value as? String != original, "数据清洗应改变历史成绩展示策略。")
        cleaning.tap()
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
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
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
        app = launchApp(resetStorage: true, account: nil, content: true)
        tap("京ICP备")
        assertOpenedURL("beian.miit.gov.cn")
        signIn(app)
        openSettings("about")
        for (entry, url) in [("项目仓库", "github.com/BIT101-dev/BIT101-iOS"), ("QQ交流群", "jq.qq.com"),
                             ("邮箱", "mailto:systemd@linux.do"), ("ICP备案", "beian.miit.gov.cn"),
                             ("如果你也想加入", "mailto:systemd@linux.do")] {
            tap(entry)
            assertOpenedURL(url)
        }
        back()
        app.tabBars.buttons["app.tab.home"].tap()
        app.segmentedControls.buttons["课程"].tap()
        tap("自动化测试课程")
        tap("共享资料")
        assertOpenedURL("http")
    }

    @MainActor
    private func assertOpenedURL(_ target: String) {
        let alert = app.alerts["打开链接"]
        assertUI(alert.appears(timeout: 5), "链接操作应发出页面选定的地址。")
        assertUI(alert.staticTexts.allElementsBoundByIndex.contains { $0.label.contains(target) }, "链接地址应匹配\(target)。")
        alert.buttons["知道了"].tap()
    }

    @MainActor
    private func dismissShareSheet() {
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["关闭", "Close"])).firstMatch
        assertUI(close.appears(timeout: 5), "分享入口应打开系统分享面板。")
        close.tap()
    }

    @MainActor
    @objc func testManualUpdatePromptAllActionsAndCurrentVersion() {
        app = launchApp(resetStorage: true, update: "new")
        openSettings("about")
        for action in ["本次忽略", "忽略此版本", "前往 App Store"] {
            tap("检查更新")
            assertUI(app.alerts["发现新版本 999.0"].appears(timeout: 5), "更新响应应展示新版本。")
            tap(action)
            if action == "前往 App Store" { assertOpenedURL("apps.apple.com/cn/app/bit101/id6761147125") }
        }
        app.terminate()
        app = launchApp(resetStorage: true, update: "current")
        openSettings("about")
        tap("检查更新")
        assertUI(app.alerts["已是最新版本"].appears(timeout: 5), "当前版本响应应展示检查结果。")
        closeAlertIfPresent()
    }

    @MainActor
    @objc func testOfflineRecoveryRetryAndErrorReportEditor() {
        app = launchApp(resetStorage: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        closeAlertIfPresent()
        tap("重试")
        assertUI(textElement("加载失败").appears(timeout: 5), "离线重试应恢复失败状态。")
        tap("向开发者分享错误信息")
        assertUI(app.navigationBars["分享错误信息"].appears(timeout: 5), "诊断入口应打开报告编辑器。")
        tap("原始网络响应")
        replaceText("测试复现步骤", in: app.textFields["可补充问题现象或复现步骤"])
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
        assertUI(app.tabBars.buttons["app.tab.gallery"].exists, "取消报告应返回话廊。")
    }

    @MainActor
    @objc func testCommunityFailedRequestsRetryToLoadedState() {
        app = launchApp(resetStorage: true, content: true, failureOnce: true)
        app.tabBars.buttons["app.tab.home"].tap()
        app.segmentedControls.buttons["课程"].tap()
        closeAlertIfPresent()
        tap("重新加载")
        assertUI(textElement("自动化测试课程").appears(timeout: 5), "课程重试应恢复加载结果。")
        app.tabBars.buttons["app.tab.gallery"].tap()
        closeAlertIfPresent()
        tap("重试")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "话廊重试应恢复列表。")
        app.segmentedControls.buttons["文章"].tap()
        closeAlertIfPresent()
        tap("重试")
        assertUI(textElement("自动化测试文章").appears(timeout: 5), "文章重试应恢复列表。")
    }

    @MainActor
    @objc func testSuggestionSuccessfulSubmissionAndDiscardSavedDraft() {
        app = launchApp(resetStorage: true, content: true)
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
        let submitted = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: page)
        assertUI(XCTWaiter.wait(for: [submitted], timeout: 5) == .completed, "提交成功应关闭建议页。")
        openSettings("suggestion")
        assertUI(!app.alerts["加载草稿？"].exists, "提交成功应清理建议草稿。")
        tap("取消")
    }

    @MainActor
    @objc func testSchoolSMSCourseSyncValidationCancelAndContinuation() {
        app = launchApp(resetStorage: true, school: true, schoolSMS: true)
        tap("刷新")
        assertUI(app.navigationBars["短信验证"].appears(timeout: 5), "课表刷新应呈现学校验证码。")
        tap("取消")
        tap("刷新")
        let field = app.textFields["verification.code"]
        replaceText("000000", in: field)
        tap("验证并同步课表")
        assertUI(textElement("测试学校验证码错误。").appears(timeout: 5), "学校错误验证码应支持修改。")
        replaceText("123456", in: field)
        tap("验证并同步课表")
        assertUI(app.buttons["schedule.add-content"].appears(timeout: 5), "验证成功应继续课表刷新。")
        assertUI(textElement("学校测试课程").exists, "继续同步应保存学校课程。")
    }

    @MainActor
    @objc func testSchoolSSODDLVerificationCancelAndContinuation() {
        app = launchApp(resetStorage: true, school: true, schoolSMS: true)
        app.segmentedControls.buttons["DDL"].tap()
        tap("刷新学校日程")
        assertUI(app.buttons["验证并继续"].appears(timeout: 5), "学校日程应展示 SSO 短信面板。")
        tap("取消")
        tap("刷新学校日程")
        replaceText("123456", in: app.textFields.firstMatch)
        tap("验证并继续")
        assertUI(textElement("课程中心测试作业").appears(timeout: 5), "SSO 验证成功应恢复学校日程请求。")
    }

    @MainActor
    @objc func testHolidayAndTransferConfirmedMutations() {
        app = launchApp(resetStorage: true, school: true)
        let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1周，周一，")).firstMatch
        day.tap()
        app.segmentedControls.buttons["放假"].tap()
        tap("确定")
        app.alerts["确认放假"].buttons["确定"].tap()
        assertUI(!app.buttons["学校测试课程"].exists, "确认放假应移除当日课程。")
        tap("第2周")
        assertUI(app.buttons["学校测试课程"].exists, "放假应保留其它周次课程。")
        let nextDay = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第2周，周一，")).firstMatch
        nextDay.tap()
        app.segmentedControls.buttons["调至某天"].tap()
        openAndDismissDatePicker("schedule.adjustment.date")
        tap("确定")
        app.alerts["确认调课"].buttons["确定"].tap()
        assertUI(app.buttons["schedule.add-content"].appears(timeout: 5), "确认调休应关闭调整窗口。")
        assertUI(!app.buttons["学校测试课程"].exists, "确认调休应移出原日期课程。")
        tap("第1周")
        assertUI(app.buttons["学校测试课程"].exists, "调休应在目标日期显示课程。")
    }

    @MainActor
    @objc func testScheduleWeekStripScrollAndCourseLongPressShare() {
        app = launchApp(resetStorage: true, content: true, school: true)
        let week = app.buttons["第1周"]
        let start = week.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -100, dy: 0)))
        let changed = expectation(for: NSPredicate(format: "selected == false"), evaluatedWith: week)
        assertUI(XCTWaiter.wait(for: [changed], timeout: 5) == .completed, "滑动周次栏应更新选择周。")
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
        app.buttons["schedule.export.share"].tap()
        dismissShareSheet()
        tap("取消")
    }

    @MainActor
    @objc func testCourseHistoryChartSelectionAndHomeSurfaceSwipes() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.home"].tap()
        app.collectionViews.firstMatch.swipeLeft()
        assertUI(app.segmentedControls.buttons["课程"].isSelected, "成绩页横滑应切换课程分区。")
        app.collectionViews.firstMatch.swipeRight()
        assertUI(app.segmentedControls.buttons["成绩"].isSelected, "反向横滑应恢复成绩分区。")
        app.segmentedControls.buttons["课程"].tap()
        tap("自动化测试课程")
        let chart = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "历史成绩图")).firstMatch
        reveal(chart)
        let left = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let right = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        right.press(forDuration: 0.2, thenDragTo: left)
        let firstTerm = expectation(for: NSPredicate(format: "value CONTAINS %@", "2025-2026-1"), evaluatedWith: chart)
        assertUI(XCTWaiter.wait(for: [firstTerm], timeout: 5) == .completed, "向左滑动历史图应选中第一学期。")
        left.press(forDuration: 0.2, thenDragTo: right)
        let lastTerm = expectation(for: NSPredicate(format: "value CONTAINS %@", "2025-2026-2"), evaluatedWith: chart)
        assertUI(XCTWaiter.wait(for: [lastTerm], timeout: 5) == .completed, "向右滑动历史图应选中第二学期。")
    }

    @MainActor
    @objc func testPullToRefreshCommunityListsDetailsAndSearch() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        pullToRefresh()
        tap("自动化测试话题")
        pullToRefresh()
        assertUI(textElement("自动化测试话题正文").exists, "下拉刷新应重新加载帖子详情。")
        back()
        tap("消息")
        pullToRefresh()
        assertUI(textElement("自动化测试消息").exists, "消息下拉刷新应保留记录。")
        tap("取消")
        app.segmentedControls.buttons["文章"].tap()
        pullToRefresh()
        tap("自动化测试文章")
        pullToRefresh()
        assertUI(textElement("自动化测试文章正文").exists, "文章详情下拉刷新应重新加载正文。")
        back()
        tap("搜索文章")
        replaceText("文章\n", in: app.textFields.firstMatch)
        pullToRefresh()
        assertUI(textElement("自动化测试文章").exists, "搜索结果下拉刷新应保留匹配文章。")
        tap("取消")
        app.tabBars.buttons["app.tab.mine"].tap()
        for route in ["粉丝", "关注", "帖子"] {
            tap(route)
            pullToRefresh()
            assertUI(textElement(route == "帖子" ? "自动化测试话题" : "自动化测试用户").exists, "个人列表下拉刷新应恢复数据。")
            back()
        }
    }

    @MainActor
    private func pullToRefresh() {
        let scroll = app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable })
            ?? app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable })
        assertUI(scroll != nil, "刷新场景应提供可滚动区域。")
        let area = scroll!
        let start = area.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.2))
        let end = area.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.9))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    @MainActor
    @objc func testMinePublicProfileUnfollowAndPostDeletion() {
        app = launchApp(resetStorage: true, content: true, media: true)
        app.tabBars.buttons["app.tab.mine"].tap()
        tap("关注")
        tap("自动化测试用户")
        tap("关注")
        tap("已关注")
        assertUI(app.buttons["关注"].appears(timeout: 5), "取消关注应恢复关注入口。")
        tap("查看头像")
        closeImagePreview()
        for route in ["粉丝", "关注", "帖子"] {
            tap(route)
            assertUI(textElement(route == "帖子" ? "自动化测试话题" : "自动化测试用户").appears(timeout: 5), "公开主页统计应打开对应列表。")
            back()
        }
        back()
        back()
        tap("帖子")
        tap("自动化测试话题")
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "个人帖子行应打开详情。")
        back()
        tap("更多操作")
        tap("删除帖子")
        app.alerts.buttons["取消"].tap()
        tap("更多操作")
        tap("删除帖子")
        app.alerts.buttons["删除"].tap()
        let poster = textElement("自动化测试话题")
        let removed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: poster)
        assertUI(XCTWaiter.wait(for: [removed], timeout: 5) == .completed, "个人列表删除应移除帖子。")
    }

    @MainActor
    @objc func testMapLocationAndScheduleLocationRoute() {
        app = launchApp(resetStorage: true, content: true, school: true)
        tap("学校测试课程")
        tap("查看上课地点")
        assertUI(app.tabBars.buttons["app.tab.map"].isSelected, "课程地点应切换至地图。")
        let location = app.buttons["定位到我的位置"]
        location.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.firstMatch
        if permission.appears(timeout: 2) {
            let allow = permission.buttons.matching(NSPredicate(format: "label IN %@", ["允许一次", "Allow Once"])).firstMatch
            assertUI(allow.exists, "定位权限应提供单次授权。")
            allow.tap()
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
    @objc func testSearchSortingMenusAndArticleSortSwipes() {
        app = launchApp(resetStorage: true, content: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        tap("搜索话廊")
        replaceText("测试\n", in: app.textFields.firstMatch)
        var selected = "最新"
        for option in ["相似", "高赞", "最新"] {
            tap(selected)
            tap(option)
            selected = option
            assertUI(textElement("自动化测试话题").appears(timeout: 5), "话廊搜索排序应恢复结果。")
        }
        pullToRefresh()
        tap("取消")
        app.segmentedControls.buttons["文章"].tap()
        let list = app.scrollViews.firstMatch
        list.swipeLeft()
        assertUI(app.segmentedControls.buttons["高赞"].isSelected, "文章横滑应切换点赞排序。")
        list.swipeLeft()
        assertUI(app.segmentedControls.buttons["热评"].isSelected, "连续横滑应切换评论排序。")
        list.swipeRight()
        assertUI(app.segmentedControls.buttons["高赞"].isSelected, "反向横滑应恢复文章排序。")
        tap("搜索文章")
        replaceText("文章\n", in: app.textFields.firstMatch)
        selected = "最新"
        for option in ["高赞", "热评", "最新"] {
            tap(selected)
            tap(option)
            selected = option
            assertUI(textElement("自动化测试文章").appears(timeout: 5), "文章搜索排序应恢复结果。")
        }
        tap("取消")
    }

    @MainActor
    @objc func testNetworkDiagnosisProgressAndReport() {
        app = launchApp(resetStorage: true)
        openSettings("gallery")
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
        app = launchApp(resetStorage: true, content: true, school: true)
        tap("学校测试课程")
        tap("课程评价")
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "学校课程评价入口应打开匹配课程。")
        assertUI(textElement("学校测试课程").exists, "匹配后的课程详情应保留学校课程身份。")
        back()
        app.tabBars.buttons["app.tab.gallery"].tap()
        tap("自动化测试话题")
        tap("自动化测试用户")
        assertUI(app.buttons["关注"].appears(timeout: 5), "帖子作者应打开公开主页。")
        back()
        tap("分享话题")
        dismissShareSheet()
        let commentUser = app.buttons.matching(NSPredicate(format: "label == %@", "自动化测试用户")).allElementsBoundByIndex.last
        assertUI(commentUser != nil, "评论应提供用户主页入口。")
        reveal(commentUser!)
        commentUser!.tap()
        assertUI(app.buttons["关注"].appears(timeout: 5), "评论昵称应打开公开主页。")
    }

    @MainActor
    @objc func testEmptyShareAndImportGuideCancellationAndSheetSwipeDismissal() {
        app = launchApp(resetStorage: true)
        openSettings("calendar")
        tap("分享课表")
        app.alerts["当前课表为空"].buttons["取消"].tap()
        assertUI(app.buttons["schedule.settings.primary-name"].exists, "取消空课表分享应留在设置页。")
        tap("导入课表")
        app.alerts["导入分享课表提示"].buttons["取消"].tap()
        assertUI(!app.textViews["schedule.import.code"].exists, "取消导入说明应保留设置页。")
        back()
        app.tabBars.buttons["app.tab.schedule"].tap()
        app.buttons["schedule.add-content"].tap()
        tap("添加日程")
        let sheet = app.navigationBars["添加自定义日程"]
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        assertUI(app.buttons["schedule.add-content"].appears(timeout: 5), "下滑关闭应恢复课表入口。")
    }

    @MainActor
    @objc func testCustomScheduleDateTimePickersAndCancelEditing() {
        app = launchApp(resetStorage: true)
        app.buttons["schedule.add-content"].tap()
        tap("添加日程")
        for identifier in ["schedule.custom.date", "schedule.custom.begin", "schedule.custom.end"] {
            openAndDismissDatePicker(identifier)
        }
        replaceText("时间选择测试日程", in: app.textFields["schedule.custom.title"])
        dismissKeyboard()
        tap("确定")
        tap("自定义日程，时间选择测试日程")
        tap("编辑")
        replaceText("取消的日程修改", in: app.textFields["schedule.custom.title"])
        dismissKeyboard()
        tap("取消")
        assertUI(!textElement("取消的日程修改").exists, "取消日程修改应保留原内容。")
        assertUI(textElement("时间选择测试日程").exists, "取消应保留原日程。")
    }

    @MainActor
    @objc func testDDLEditorDetailsDatePickerValidationAndCancelEditing() {
        app = launchApp(resetStorage: true)
        app.segmentedControls.buttons["DDL"].tap()
        tap("添加待办")
        app.buttons["ddl.editor.save"].tap()
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "空待办标题应展示校验结果。")
        closeAlertIfPresent()
        replaceText("带详情的待办", in: app.textFields["ddl.editor.title"])
        replaceText("待办详细说明", in: app.textFields["详情"])
        dismissKeyboard()
        openAndDismissDatePicker("ddl.editor.date")
        app.buttons["ddl.editor.save"].tap()
        tap("带详情的待办")
        assertUI(textElement("待办详细说明").appears(timeout: 5), "待办详情应恢复输入正文。")
        tap("编辑")
        replaceText("取消的待办修改", in: app.textFields["ddl.editor.title"])
        dismissKeyboard()
        tap("取消")
        assertUI(textElement("带详情的待办").appears(timeout: 5), "取消待办编辑应保留原记录。")
    }

    @MainActor
    @objc func testFutureScheduleImportUpdateCancellationAndLink() {
        app = launchApp(resetStorage: true)
        openSettings("calendar")
        tap("导入课表")
        tap("知道了")
        let code = app.textViews["schedule.import.code"]
        replaceText("BIT101SCH99:test", in: code)
        dismissKeyboard()
        tap("导入")
        assertUI(app.alerts["需要更新 BIT101"].appears(timeout: 5), "较新编码应展示版本更新提示。")
        app.alerts.buttons["取消"].tap()
        assertUI(code.value as? String == "BIT101SCH99:test", "取消更新应保留编码输入。")
        tap("导入")
        tap("前往 App Store")
        assertOpenedURL("apps.apple.com/cn/app/bit101/id6761147125")
        tap("取消")
    }

    @MainActor
    @objc func testWebGallerySettingPersistenceScrollingAndNativeReturn() {
        app = launchApp(resetStorage: true, content: true)
        openSettings("gallery")
        let value = toggle("使用网页话廊")
        back()
        app.tabBars.buttons["app.tab.gallery"].tap()
        let web = app.webViews.firstMatch
        assertUI(web.appears(timeout: 10), "网页设置应打开 WebKit 页面。")
        web.swipeUp()
        web.swipeDown()
        app.terminate()
        app = launchApp(resetStorage: false, content: true)
        openSettings("gallery")
        let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "使用网页话廊")).firstMatch
        reveal(control)
        waitForValue(value, of: control)
        toggle("使用网页话廊")
        back()
        app.tabBars.buttons["app.tab.gallery"].tap()
        assertUI(app.buttons["发布话题"].appears(timeout: 5), "切回原生设置应恢复话题发布入口。")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "原生列表应加载测试帖子。")
    }

    @MainActor
    @objc func testErrorReportSanitizedSubmissionAndFailureRecovery() {
        app = launchApp(resetStorage: true, content: true, failureOnce: true)
        app.tabBars.buttons["app.tab.gallery"].tap()
        tap("向开发者分享错误信息")
        tap("原始网络响应")
        tap("脱敏调试信息")
        replaceText("合成错误报告复现步骤", in: app.textFields["可补充问题现象或复现步骤"])
        dismissKeyboard()
        tap("提交")
        tap("继续提交")
        let report = app.navigationBars["分享错误信息"]
        let submitted = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: report)
        assertUI(XCTWaiter.wait(for: [submitted], timeout: 5) == .completed, "反馈响应成功应关闭报告编辑器。")
        tap("重试")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "提交报告后重试应恢复帖子列表。")
    }

    @MainActor
    @objc func testLoginSubmitButtonAndKeyboardScrollDismissal() {
        app = launchApp(resetStorage: true, account: nil)
        replaceText("ui-test-student", in: app.textFields["login.student-id"])
        replaceText("ui-test-password", in: app.secureTextFields["login.password"])
        app.collectionViews.firstMatch.swipeUp()
        dismissKeyboard()
        let submit = app.buttons["login.submit"]
        assertUI(submit.isEnabled, "完整填写凭据应启用登录按钮。")
        submit.tap()
        assertUI(app.tabBars.buttons["app.tab.schedule"].appears(timeout: 10), "点击登录按钮应进入主界面。")
    }

    @MainActor
    private func openAndDismissDatePicker(_ identifier: String) {
        let field = app.datePickers[identifier]
        reveal(field)
        let buttons = field.buttons.allElementsBoundByIndex
        assertUI(!buttons.isEmpty, "日期时间控件应暴露系统选择入口。")
        for button in buttons {
            button.tap()
            assertUI(app.datePickers.count > 1 || app.pickerWheels.firstMatch.exists || app.collectionViews.count > 1,
                     "日期或时间点击应打开系统选择器。")
            if app.pickerWheels.firstMatch.exists {
                let wheel = app.pickerWheels.firstMatch
                let original = wheel.value as? String
                wheel.swipeUp()
                assertUI(wheel.value as? String != original, "时间滚轮应响应滑动。")
            }
            let bar = app.navigationBars.allElementsBoundByIndex.last(where: { $0.isHittable })!
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

}
