import XCTest
import CoreGraphics

nonisolated final class CommunityInteractionUITests: UIAutomationTestCase {
    @MainActor
    @objc func testPosterSubscriptionsPersistAndAppearInFavorites() {
        app = configureApp(resetStorage: true, content: true, initialTab: "gallery")
        tap("我的收藏")
        assertUI(textElement("加载收藏失败").appears(timeout: 5), "收藏请求失败应提供重试。")
        tap("重试")
        assertUI(textElement("还没有收藏").appears(timeout: 5), "空列表应解释收藏入口。")
        pullToRefresh()
        tap("完成")
        tap("自动化测试话题")
        let bookmark = app.buttons["插眼收藏"]
        assertUI(bookmark.appears(timeout: 5), "话题详情应提供插眼入口。")
        for level in ["悄悄收藏", "订阅更新", "订阅更新与评论"] {
            tapHeader(bookmark)
            tap(level)
            assertUI(waitUntil(NSPredicate(format: "value == %@", level), on: bookmark, timeout: 5), "插眼应保存所选订阅级别。")
        }
        back()
        tap("我的收藏")
        tap("加载更多收藏")
        tap("自动化测试话题")
        assertUI(waitUntil(NSPredicate(format: "value == %@", "订阅更新与评论"), on: bookmark, timeout: 5), "从收藏重开详情应读取服务端状态。")
        tapHeader(bookmark)
        tap("取消插眼")
        assertUI(waitUntil(NSPredicate(format: "value == %@", "尚未插眼"), on: bookmark, timeout: 5), "取消后应恢复空心收藏状态。")
        back()
        assertUI(textElement("还没有收藏").appears(timeout: 5), "取消插眼后收藏列表应同步移除话题。")
        tap("完成")
        tap("消息")
        tapHeader(app.segmentedControls.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "插眼")).firstMatch)
        assertUI(textElement("自动化测试消息").appears(timeout: 5), "消息中心应展示插眼更新。")
        tap("取消")
    }

    @MainActor
    @objc func testGalleryBlockingUpdatesLoadedFeedsAndUnblockingRestoresThem() {
        app = configureApp(resetStorage: true, content: true, initialTab: "gallery")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "首页应展示已加载的话题。")
        openSettings("gallery")
        replaceText("1\n", in: app.textFields["屏蔽用户 UID（逗号分隔）"])
        back()
        app.mainTab("话廊").tapBriefly()
        assertUI(textElement("暂无话题").appears(timeout: 5), "屏蔽作者后已加载的列表应更新过滤状态。")
        openSettings("gallery")
        replaceText("\n", in: app.textFields["屏蔽用户 UID（逗号分隔）"])
        back()
        app.mainTab("话廊").tapBriefly()
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "解除屏蔽后应重新加载被过滤的话题。")
    }

    @MainActor
    @objc func testPaperImagePreviewCommentsSortAndShare() {
        app = configureApp(resetStorage: true, content: true, animations: true, media: true, initialTab: "gallery")
        tapHeader(app.sectionTab("文章"))
        tap("自动化测试文章")
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5), "点击卡片应打开文章。")
        back()
        let summary = app.descendants(matching: .any)["paper.summary.1"]
        assertUI(summary.performAccessibilityAction(named: "打开文章"), "文章卡片应提供可执行的 VoiceOver 动作。")
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5), "VoiceOver 动作应打开文章详情。")
        let richText = app.textViews.matching(identifier: "paper.body.rich-text").firstMatch
        assertUI(richText.appears(timeout: 5), "文章正文加载完成后应提供原生富文本内容。")
        reveal(richText)
        richText.tapBriefly()
        assertUI(app.navigationBars["文章详情"].exists, "富文本正文应保留文章详情上下文。")
        let link = app.links.matching(identifier: "正文链接").firstMatch
        reveal(link)
        link.tapBriefly()
        assertOpenedURL("github.com/BIT101-dev/BIT101-iOS")
        let image = app.buttons["文章图片：测试图片"]
        reveal(image)
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapBriefly()
        closeImagePreview()
        tapLink("阅读完整原文")
        assertOpenedURL("https://bit101.cn/paper/1", exact: true)
        let footerLike = app.buttons["paper.detail.footer-like"]
        reveal(footerLike)
        footerLike.tapBriefly()
        let headerLike = app.buttons["paper.detail.header-like"]
        assertUI(waitUntil(NSPredicate(format: "label == %@", "取消文章点赞"), on: headerLike, timeout: 5), "正文末尾点赞应同步顶部状态。")
        footerLike.tapBriefly()
        assertUI(waitUntil(NSPredicate(format: "label == %@", "点赞文章"), on: headerLike, timeout: 5), "正文末尾取消点赞应同步顶部状态。")
        tapHeader(headerLike)
        assertUI(app.buttons["取消文章点赞"].appears(timeout: 5), "顶部点赞入口应更新文章状态。")
        tapHeader(headerLike)
        tap("排序")
        tap("高赞")
        assertUI(textElement("自动化测试评论").appears(timeout: 5), "文章排序接入应显示对应评论结果。")
        tap("点赞评论")
        assertUI(app.buttons["取消评论点赞"].appears(timeout: 5), "文章评论应支持点赞。")
        tap("取消评论点赞")
        tap("回复")
        replaceText("文章回复内容", in: app.textFields.firstMatch)
        dismissKeyboard()
        tap("发布")
        reveal(textElement("文章回复内容"))
        assertUI(textElement("文章回复内容").exists, "文章回复应显示正文。")
        tap("更多操作")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "界面截图：文章更多菜单"; screenshot.lifetime = .keepAlways; add(screenshot)
        tap("分享文章")
        dismissShareSheet()
        tap("评论文章")
        tap("取消")
        assertUI(app.navigationBars["文章详情"].exists, "取消评论应恢复文章详情。")
    }

    @MainActor
    @objc func testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare() {
        app = configureApp(resetStorage: true, content: true, animations: true, media: true, initialTab: "home")
        tapHeader(app.segmentedControls.buttons["课程"])
        replaceText("测试\n", in: app.textFields.firstMatch)
        tap("清除搜索")
        tap("自动化测试课程")
        tap("点赞课程")
        assertUI(app.buttons["取消课程点赞"].appears(timeout: 5), "课程点赞应更新操作。")
        tap("取消课程点赞")
        let cleaning = app.buttons["数据清洗"]
        reveal(cleaning)
        let original = cleaning.value as? String
        cleaning.tapBriefly()
        assertUI(waitUntil(NSPredicate(format: "value == %@", original == "全部显示" ? "隐藏疑似补考" : "全部显示"), on: cleaning, timeout: 5), "数据清洗应改变历史成绩展示策略。")
        cleaning.tapBriefly()
        tap("评论课程")
        app.buttons["发送"].assertDisabled("评分选择提示对应发送按钮禁用。")
        let ratingControl = app.steppers["ui.course-comment-composer-sheet.rating"]
        assertUI(ratingControl.appears(timeout: 5), "课程评分应提供原生增减操作。")
        let decreaseRating = ratingControl.buttons.element(boundBy: 0)
        let increaseRating = ratingControl.buttons.element(boundBy: 1)
        for _ in 0..<10 { increaseRating.tapBriefly() }
        assertUI((ratingControl.value as? String)?.contains("5.0") == true, "评分增加应覆盖全部半星值。")
        for _ in 0..<10 { decreaseRating.tapBriefly() }
        assertUI(app.staticTexts["请选择评分"].appears(timeout: 5), "评分归零应恢复选择提示。")
        app.buttons["发送"].assertDisabled("清空评分后发送按钮回到禁用状态。")
        for _ in 0..<7 { increaseRating.tapBriefly() }
        app.buttons["发送"].assertDisabled("评分与评论正文共同决定发送状态。")
        toggle("匿名评论")
        replaceTextWithKeyboard("本次发布课程评价", in: app.textFields.firstMatch)
        let keyboardDone = app.buttons["keyboard.dismiss"]
        assertUI(keyboardDone.appears(timeout: 5), "键盘应展示完成操作。")
        keyboardDone.press(forDuration: 0.01)
        assertUI(app.keyboards.firstMatch.disappears(timeout: 5), "点击完成应收起系统键盘。")
        tap("发送")
        assertUI(app.navigationBars["发表评论"].disappears(timeout: 5), "发送完成应关闭评论编辑。")
        reveal(textElement("本次发布课程评价"), description: "本次发布课程评价")
        assertUI(textElement("本次发布课程评价").exists, "提交评价应更新课程评论区。")
        tap("评论课程")
        assertUI(app.navigationBars["发表评论"].appears(timeout: 5), "再次评论应打开新的编辑页面。")
        tap("取消")
        tap("点赞评论")
        assertUI(app.buttons["取消评论点赞"].appears(timeout: 5), "课程评论应支持点赞。")
        tap("取消评论点赞")
        tapImage("查看第1张图片")
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
        app = configureApp(resetStorage: true, content: true, reportFailureOnce: true, initialTab: "gallery")
        tap("更多操作")
        tap("举报帖子")
        assertUI(app.buttons["ui.gallery-report-sheet.reload"].appears(timeout: 5), "分类读取失败应提供重新加载入口。")
        let submit = app.descendants(matching: .any).matching(identifier: "ui.gallery-report-sheet.submit").firstMatch
        reveal(submit)
        submit.assertDisabled("分类读取失败时提交等待重试。")
        tap("重新加载")
        choose("类型", option: "其他")
        tap("取消")
        assertUI(app.buttons["发布话题"].appears(timeout: 5), "取消卡片举报应返回列表。")
        tap("自动化测试话题")
        tap("更多操作")
        tap("举报帖子")
        replaceText("帖子举报说明", in: app.textFields["请描述举报原因"])
        dismissKeyboard()
        tap("提交举报")
        assertUI(app.alerts["举报已提交"].appears(timeout: 5), "详情举报应展示提交结果。")
        tap("知道了")
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "举报完成应返回详情。")
    }

    @MainActor
    @objc func testExternalLinksFromAboutAndCourseResources() {
        app = configureApp(resetStorage: true, content: true, initialSettings: "about")
        for (entry, url) in [("项目仓库", "github.com/BIT101-dev/BIT101-iOS"), ("QQ交流群", "jq.qq.com"),
                             ("邮箱", "mailto:systemd@linux.do"), ("ICP备案", "beian.miit.gov.cn")] {
            tapLink(entry)
            assertOpenedURL(url)
        }
        back()
        app.mainTab("成绩").tapBriefly()
        tapHeader(app.segmentedControls.buttons["课程"])
        tap("自动化测试课程")
        tap("共享资料")
        assertOpenedURL("http")
    }

}

nonisolated final class ServiceInteractionUITests: UIAutomationTestCase {
    @MainActor
    @objc func testManualUpdatePromptAllActionsAndCurrentVersion() {
        app = configureApp(resetStorage: true, animations: true, update: "new", initialSettings: "about")
        app.native.typeKey(XCUIKeyboardKey.shift, modifierFlags: [])
        for action in ["本次忽略", "忽略此版本", "前往 App Store"] {
            tap("检查更新")
            assertUI(app.alerts["发现新版本 999.0"].appears(timeout: 5), "更新响应应展示新版本。")
            tap(action)
            if action == "前往 App Store" { assertOpenedURL("apps.apple.com/cn/app/bit101/id6761147125") }
        }
        tap("检查更新")
        assertUI(app.alerts["发现新版本 999.0"].appears(timeout: 5), "键盘验收应展示更新提示。")
        app.alerts.buttons["ui.app-prompt-host-modifier.default-action"].pressReturnKey()
        assertOpenedURL("apps.apple.com/cn/app/bit101/id6761147125")
        assertUI(app.alerts["发现新版本 999.0"].disappears(timeout: 5), "Return 应完成当前更新提示并恢复页面。")
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
        assertUI(app.mainTab("话廊").exists, "取消报告应返回话廊。")
    }

    @MainActor
    @objc func testCommunityFailedRequestsRetryToLoadedState() {
        app = configureApp(resetStorage: true, content: true, failureOnce: true, initialTab: "home")
        tapHeader(app.segmentedControls.buttons["课程"])
        assertUI(app.alerts["加载课程失败"].appears(timeout: 5), "首次课程失败应展示错误提示。")
        closeAlertIfPresent()
        tap("重新加载")
        assertUI(textElement("自动化测试课程").appears(timeout: 5), "课程重试应恢复加载结果。")
        app.mainTab("话廊").tapBriefly()
        assertUI(app.alerts["加载话廊失败"].appears(timeout: 5), "首次话廊失败应展示错误提示。")
        closeAlertIfPresent()
        tap("重试")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "话廊重试应恢复列表。")
        tapHeader(app.sectionTab("文章"))
        assertUI(app.alerts["加载文章失败"].appears(timeout: 5), "首次文章失败应展示错误提示。")
        closeAlertIfPresent()
        tap("重试")
        assertUI(textElement("自动化测试文章").appears(timeout: 5), "文章重试应恢复列表。")
    }

    @MainActor
    @objc func testSuggestionSuccessfulSubmissionAndDiscardSavedDraft() {
        app = configureApp(resetStorage: true, content: true, feedbackResponseLostOnce: true)
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
        assertUI(app.alerts["提交失败"].appears(timeout: 5), "受理后的响应丢失应保留建议编辑器。")
        closeAlertIfPresent()
        assertUI(app.textFields["建议内容"].value as? String == "成功提交测试建议", "响应丢失应保留建议内容。")
        tap("提交")
        tap("继续提交")
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: page, timeout: 5), "提交成功应关闭建议页。")
        openSettings("suggestion")
        assertUI(!app.alerts["加载草稿？"].exists, "提交成功应清理建议草稿。")
        tap("取消")
    }

    @MainActor
    @objc func testSuggestionSubmissionProtectsThePendingPayload() {
        app = configureApp(resetStorage: true, content: true, animations: true, feedbackHold: true)
        openSettings("suggestion")
        replaceText("提交期间保留建议", in: app.textFields["建议内容"])
        dismissKeyboard()
        replaceText("测试联系信息", in: app.textFields["联系方式"])
        dismissKeyboard()
        tap("提交")
        assertUI(waitUntil(NSPredicate { _, _ in UITestControlClient.request(["command": "request-state", "key": "feedback"]) == "pending" }, on: app),
            "建议请求应进入受控的等待状态。")
        app.textFields["建议内容"].assertDisabled("等待提交结果期间应保护建议正文。")
        app.textFields["联系方式"].assertDisabled("等待提交结果期间应保护联系方式。")
        app.buttons["ui.developer-suggestion-page.插入图片"].assertDisabled("等待提交结果期间应保护附件。")
        app.buttons["取消"].assertDisabled("等待提交结果期间应保留编辑器。")
        let page = app.navigationBars["向开发者提建议"]
        swipeSheetHeader(page)
        assertUI(page.exists && app.textFields["建议内容"].value as? String == "提交期间保留建议", "下滑应保留等待中的建议与结果上下文。")
        assertUI(UITestControlClient.request(["command": "release-request", "key": "feedback"]) == "released", "传输夹具应完成原请求。")
        assertUI(page.disappears(timeout: 5), "提交成功应完成建议流程。")
    }

    @MainActor
    @objc func testRecoveredSuggestionPreservesContentAndConfirmsANewSubmission() {
        app = configureApp(resetStorage: true, content: true, suggestionRecovery: true)
        openSettings("suggestion")
        tap("加载草稿")
        assertUI(app.alerts["建议内容已部分恢复"].appears(timeout: 5), "待确认建议的附件缺失应说明恢复内容。")
        closeAlertIfPresent()
        assertUI(app.textFields["建议内容"].value as? String == "恢复建议草稿", "恢复建议应保留文字。")
        reveal(app.textFields["联系方式"], description: "恢复建议联系方式")
        assertUI(app.textFields["联系方式"].value as? String == "测试联系信息", "恢复建议应保留联系方式。")
        reveal(app.buttons["移除图片"], description: "恢复建议图片")
        assertUI(app.buttons["移除图片"].exists, "恢复建议应保留可用附件。")
        tap("suggestion.recovery.continue")
        assertUI(app.alerts["将恢复内容作为新建议？"].appears(timeout: 5), "继续编辑应说明上一份建议的发送状态。")
        tap("返回核对")
        assertUI(app.buttons["suggestion.recovery.continue"].exists, "返回核对应保留恢复选择。")
        tap("suggestion.recovery.continue")
        tap("继续编辑")
        tap("取消")
        tap("保存草稿")
        openSettings("suggestion")
        tap("加载草稿")
        assertUI(app.textFields["建议内容"].value as? String == "恢复建议草稿", "确认后的恢复内容应持续保存。")
        tap("提交")
        assertUI(app.navigationBars["向开发者提建议"].disappears(timeout: 5), "恢复的文字、联系方式和可用图片应以新的提交身份成功发送。")
    }

    @MainActor
    @objc func testSchoolSMSCourseSyncValidationCancelAndContinuation() {
        app = configureApp(resetStorage: true, animations: true, school: true, schoolSMS: true)
        tapHeader(app.sectionTab("空教室"))
        tapHeader(app.sectionTab("课表"))
        let refresh = app.descendants(matching: .any)["schedule.refresh-status"].buttons["app.refresh-status.action"]
        refresh.tapBriefly()
        assertUI(app.navigationBars["短信验证"].appears(timeout: 5), "课表刷新应呈现学校验证码。")
        assertUI(app.buttons["验证并继续"].exists, "短信验证应继续所属学校请求。")
        tap("取消")
        refresh.tapBriefly()
        let field = app.textFields["verification.code"]
        fillVerificationCode("123456", in: field)
        assertUI(app.buttons["schedule.add-content"].appears(timeout: 5), "验证成功应继续课表刷新。")
        assertUI(textElement("学校测试课程").exists, "继续同步应保存学校课程。")
        assertUI(app.alerts["课表已是最新"].appears(timeout: 5), "刷新完成后应展示课表核对结果。")
        closeAlertIfPresent()
    }

    @MainActor
    @objc func testSchoolSSODDLVerificationCancelAndContinuation() {
        app = configureApp(resetStorage: true, animations: true, school: true, schoolSMS: true)
        tapHeader(app.segmentedControls.buttons["DDL"])
        app.buttons["app.refresh-status.action"].tapBriefly()
        assertUI(app.buttons["验证并继续"].appears(timeout: 5), "学校日程应展示 SSO 短信面板。")
        tap("取消")
        app.buttons["app.refresh-status.action"].tapBriefly()
        fillVerificationCode("123456", in: app.textFields["verification.code"])
        let success = app.alerts["DDL 同步成功"]
        assertUI(success.appears(timeout: 5), "学校验证完成后应展示同步成功结果。")
        closeAlertIfPresent()
        assertUI(success.disappears(timeout: 5), "确认同步结果应关闭成功提示。")
        assertUI(textElement("课程中心测试作业").appears(timeout: 5), "SSO 验证成功应恢复学校日程请求。")
    }
}

nonisolated final class ScheduleNavigationUITests: UIAutomationTestCase {
    @MainActor
    @objc func testHolidayAndTransferConfirmedMutations() {
        app = configureApp(resetStorage: true, school: true)
        let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1周，周一，")).firstMatch
        day.tapBriefly()
        tapHeader(app.segmentedControls.buttons["放假"])
        tap("确定")
        app.alerts["确认放假"].buttons["确定"].tapBriefly()
        assertUI(!app.buttons["学校测试课程"].exists, "确认放假应移除当日课程。")
        tap("第2周")
        assertUI(app.buttons["学校测试课程"].exists, "放假应保留其它周次课程。")
        let nextDay = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第2周，周一，")).firstMatch
        nextDay.tapBriefly()
        tapHeader(app.segmentedControls.buttons["调至某天"])
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
        course.tapBriefly()
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "点按课程应打开课程详情。")
        tap("取消")
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
        app.descendants(matching: .any)["home.score-surface"].swipeLeft()
        assertUI(app.segmentedControls.buttons["课程"].isSelected, "成绩页横滑应切换课程分区。")
        app.descendants(matching: .any)["home.course-surface"].swipeRight()
        assertUI(app.segmentedControls.buttons["成绩"].isSelected, "反向横滑应恢复成绩分区。")
        tapHeader(app.segmentedControls.buttons["课程"])
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
    @objc func testMapLocationAndScheduleLocationRoute() {
        app = configureApp(resetStorage: true, content: true, school: true)
        tap("学校测试课程")
        tap("查看上课地点")
        assertUI(waitUntil(NSPredicate(format: "selected == true"), on: app.mainTab("地图")), "课程地点应切换至地图。")
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
    @objc func testNetworkDiagnosisProgressAndReport() {
        app = configureApp(resetStorage: true, content: true, school: true, initialSettings: "gallery")
        tap("测试网络并生成诊断报告")
        assertUI(app.alerts["网络诊断完成"].appears(timeout: 60), "诊断操作应汇总每个网络步骤。")
        for title in ["网络路径", "BIT101 首页", "话廊接口", "文章接口", "学校当前学期", "课表与考试", "DDL 接口", "可信成绩单"] {
            assertUI(app.alerts.staticTexts.allElementsBoundByIndex.contains { $0.label.contains(title) }, "诊断报告应包含\(title)。")
        }
        for title in ["话廊接口", "文章接口", "学校当前学期", "课表与考试", "DDL 接口"] {
            assertUI(app.alerts.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("\(title)：通过") },
                     "受控诊断服务应完成\(title)。")
        }
        assertUI(app.alerts.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("可信成绩单：需要短信验证") },
                 "成绩单诊断应保留受控服务的短信验证结果。")
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
        app.mainTab("话廊").tapBriefly()
        tap("自动化测试话题")
        tap("自动化测试用户")
        assertUI(app.buttons["关注"].appears(timeout: 5), "帖子作者应打开公开主页。")
        back()
        tap("分享话题")
        dismissShareSheet()
        guard let commentUser = app.buttons.matching(NSPredicate(format: "label == %@", "自动化测试用户")).allElementsBoundByIndex.last else {
            assertUI(false, "评论应提供用户主页入口。")
            return
        }
        reveal(commentUser)
        commentUser.tapBriefly()
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
        app.mainTab("日程").tapBriefly()
        app.buttons["schedule.add-content"].tapBriefly()
        tap("添加日程")
        let sheet = app.navigationBars["添加自定义日程"]
        swipeSheetHeader(sheet)
        assertUI(waitUntil(NSPredicate(format: "hittable == true"), on: app.buttons["schedule.add-content"], timeout: 5), "下滑关闭应恢复课表入口。")
    }


    @MainActor
    @objc func testDDLEditorDetailsDatePickerValidationAndCancelEditing() {
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
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "ddl.event.")).firstMatch
        assertUI(card.performAccessibilityAction(named: "打开详情"), "待办卡片应提供可执行的 VoiceOver 动作。")
        assertUI(textElement("待办详细说明").appears(timeout: 5), "待办详情应恢复输入正文。")
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
    @objc func testFutureScheduleImportUpdateCancellationAndLink() {
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
        assertUI(UITestControlClient.request(["command": "keyboard-state"]) == "hidden", "版本提示应释放编码编辑焦点。")
        app.alerts.buttons["前往 App Store"].pressReturnKey()
        assertOpenedURL("apps.apple.com/cn/app/bit101/id6761147125")
        assertUI(app.alerts["需要更新 BIT101"].disappears(timeout: 5), "Return 应关闭导入版本提示。")
        tap("取消")
    }

    @MainActor
    @objc func testWebGallerySettingPersistenceScrollingAndNativeReturn() {
        app = configureApp(resetStorage: true, content: true, initialSettings: "gallery")
        let value = toggle("使用网页话廊")
        back()
        app.mainTab("话廊").tapBriefly()
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
        app.mainTab("话廊").tapBriefly()
        assertUI(app.buttons["发布话题"].appears(timeout: 5), "切回原生设置应恢复话题发布入口。")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "原生列表应加载测试帖子。")
    }

    @MainActor
    @objc func testErrorReportSanitizedSubmissionAndFailureRecovery() {
        app = configureApp(resetStorage: true, content: true, failureOnce: true, initialTab: "gallery")
        tap("向开发者分享错误信息")
        let report = app.navigationBars["分享错误信息"]
        assertUI(report.appears(timeout: 5), "诊断入口应呈现报告编辑器。")
        app = configureApp(resetStorage: false, content: true, failureOnce: true, feedbackResponseLostOnce: true, initialTab: "gallery")
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
        let failure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "提交失败：")).firstMatch
        assertUI(failure.appears(timeout: 5), "受理后的响应丢失应呈现可重试结果。")
        assertUI(app.textFields["error-report.comment"].value as? String == "合成错误报告复现步骤", "响应丢失应保留错误报告内容。")
        tap("提交")
        tap("继续提交")
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: report, timeout: 5), "反馈响应成功应关闭报告编辑器。")
        tap("重试")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "提交报告后重试应恢复帖子列表。")
    }

    @MainActor
    @objc func testLoginSubmitButtonAndKeyboardScrollDismissal() {
        app = configureApp(resetStorage: true, account: nil, animations: true, nativeInteraction: true)
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
    func testRegistrationResetAndCommunityPasswordLogin() throws {
        for method in ["统一身份认证", "校园邮箱"] {
            app = configureApp(resetStorage: true, account: nil, animations: true, nativeInteraction: true)
            app.buttons["login.register"].tapBriefly()
            let submit = app.buttons["registration.submit"]
            submit.assertDisabled("注册需要完整密码及身份验证。")
            replaceTextWithKeyboard("1120260001", in: app.textFields["registration.student-id"])
            replaceTextWithKeyboard("community-password", in: app.secureTextFields["registration.password"])
            replaceTextWithKeyboard("different-password", in: app.secureTextFields["registration.confirmation"])
            dismissKeyboard()
            if method == "校园邮箱" { choose("验证方式", option: method) }
            if method == "统一身份认证" {
                replaceTextWithKeyboard("school-password", in: app.secureTextFields["registration.school-password"])
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
            replaceTextWithKeyboard("community-password", in: app.secureTextFields["registration.confirmation"])
            dismissKeyboard()
            reveal(submit)
            XCTAssertTrue(submit.native.isEnabled && submit.native.isHittable)
            let screenshot = XCTAttachment(screenshot: app.native.screenshot())
            screenshot.name = "界面截图"; screenshot.lifetime = .keepAlways; add(screenshot)
            submit.tapBriefly()
            assertUI(app.mainTab("日程").appears(timeout: 10), "注册或重置成功应进入已登录页面。")
        }
        app = configureApp(resetStorage: true, account: nil, animations: true, nativeInteraction: true)
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
        let types = [Int(XCUIElement.ElementType.link.rawValue), Int(XCUIElement.ElementType.button.rawValue)]
        let link = app.descendants(matching: .any)
            .matching(NSPredicate(format: "elementType IN %@ AND label CONTAINS %@", types, title)).firstMatch
        reveal(link, description: title)
        link.tap()
    }

    @MainActor
    func assertOpenedURL(_ target: String, exact: Bool = false) {
        var openedURL = ""
        assertUI(waitUntil(NSPredicate { _, _ in
            openedURL = UITestControlClient.request(["command": "consume-opened-url"]) ?? ""
            return !openedURL.isEmpty
        }, on: app), "链接操作应发出页面选定的地址。")
        assertUI(exact ? openedURL == target : openedURL.contains(target), "链接地址应匹配\(target)，实际地址：\(openedURL)。")
    }

    @MainActor
    func dismissShareSheet() {
        dismissNotificationBanner()
        let sheet = app.navigationBars["UIActivityContentView"]
        assertUI(sheet.appears(timeout: 30), "分享入口应打开系统分享面板。")
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
    func dismissSystemPopover(_ popover: UIElement, within bounds: CGRect? = nil) {
        let dismiss = app.buttons["PopoverDismissRegion"]
        let isSourceForm = bounds != nil
        let bounds = bounds ?? app.frame
        let panel = popover.frame
        let gaps = [
            CGRect(x: bounds.minX, y: bounds.minY, width: panel.minX - bounds.minX, height: bounds.height),
            CGRect(x: panel.maxX, y: bounds.minY, width: bounds.maxX - panel.maxX, height: bounds.height),
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: panel.minY - bounds.minY),
            CGRect(x: bounds.minX, y: panel.maxY, width: bounds.width, height: bounds.maxY - panel.maxY),
        ].filter { $0.size.width > 0 && $0.size.height > 0 }
            .map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        guard let gap = isSourceForm ? gaps.first : gaps.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            assertUI(false, "系统浮窗外应提供可点击的页面区域。")
            return
        }
        let origin = dismiss.exists ? dismiss.coordinate(withNormalizedOffset: .zero)
            : app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: gap.midX, dy: gap.midY)).tapBriefly()
        assertUI(popover.disappears(timeout: 5), "点击浮窗外应关闭系统浮窗。")
    }

    @MainActor
    func pullToRefresh() {
        guard let value = UITestControlClient.request(["command": "scroll-inventory"]),
              let data = value.data(using: .utf8),
              let views = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let viewport = views.last(where: { $0["hasRefreshControl"] as? Bool == true })?["viewport"] as? [Double],
              viewport.count == 4,
              let bounds = app.scrollGestureFrame(in: CGRect(x: viewport[0], y: viewport[1], width: viewport[2], height: viewport[3])) else {
            assertUI(false, "刷新场景应提供可滚动区域。")
            return
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: bounds.minX + bounds.width * 0.03, dy: bounds.minY + bounds.height * 0.2))
        let end = origin.withOffset(CGVector(dx: bounds.minX + bounds.width * 0.03, dy: bounds.minY + bounds.height * 0.9))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
        assertUI(waitUntil(NSPredicate { _, _ in
            guard let value = UITestControlClient.request(["command": "scroll-inventory"]),
                  let data = value.data(using: .utf8),
                  let views = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let scroll = views.last(where: { $0["hasRefreshControl"] as? Bool == true }) else { return false }
            return scroll["refreshing"] as? Bool == false && scroll["scrolling"] as? Bool == false
        }, on: app), "下拉刷新完成并停止滚动后应继续交互。")
    }

    @MainActor
    func swipeSheetHeader(_ header: UIElement) {
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.01,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
            withVelocity: .fast, thenHoldForDuration: 0.01)
    }

    @MainActor
    func dismissPosterSheet(returningTo title: String) {
        let detail = app.navigationBars["帖子详情"]
        swipeSheetHeader(detail)
        assertUI(waitUntil(NSPredicate { _, _ in !detail.native.exists }, on: detail), "下滑应关闭帖子详情。")
        assertUI(waitUntil(NSPredicate(format: "hittable == true"), on: app.navigationBars[title]), "关闭详情应恢复\(title)。")
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
        guard let fieldState = try? field.snapshot() else {
            assertUI(false, "日期时间控件应提供可读的界面状态。")
            return
        }
        var seen = Set<String>()
        let labels = fieldState.snapshots(matching: .button).compactMap { button -> String? in
            guard !button.frame.isEmpty,
                  button.children.allSatisfy({ $0.firstSnapshot(where: { $0.elementType == .button }) == nil }) else { return nil }
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
                  let button = currentField.firstSnapshot(where: { $0.elementType == .button && $0.label == label }) else {
                assertUI(false, "日期时间入口应保持可交互：\(label)。")
                return
            }
            origin.withOffset(CGVector(dx: button.frame.midX, dy: button.frame.midY)).tapBriefly()
            let nativePicker = app.datePickers.matching(NSPredicate(format: "identifier == %@", "")).firstMatch
            guard let pickerState = try? nativePicker.snapshot() else {
                assertUI(false, "日期或时间点击应打开独立的系统选择器。")
                return
            }
            let wheels = pickerState.snapshots(matching: .pickerWheel)
            if !wheels.isEmpty {
                let exercisedWheels = coverage == .contract ? wheels : Array(wheels.prefix(1))
                for (index, state) in exercisedWheels.enumerated() {
                    let wheel = nativePicker.pickerWheels.element(boundBy: index)
                    let original = state.value as? String ?? ""
                    let downward = original.hasPrefix("59") || original.hasPrefix("23") || original.hasPrefix("下午")
                    let start = origin.withOffset(CGVector(dx: state.frame.midX, dy: state.frame.midY))
                    start.press(forDuration: 0.1,
                                thenDragTo: start.withOffset(CGVector(dx: 0, dy: downward ? 44 : -44)),
                                withVelocity: .slow, thenHoldForDuration: 0.1)
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
    func exerciseSystemCalendar(_ picker: UIElement) {
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
        guard let selected = picker.collectionViews.buttons.allElementsBoundByIndex.first(where: { $0.isSelected }) else {
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
    func swipeImagePreview(towardEnd: Bool) {
        let preview = app.native.descendants(matching: .any)["QLPreviewControllerView"]
        if towardEnd { preview.swipeLeft(velocity: .slow) }
        else { preview.swipeRight(velocity: .slow) }
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
        let done = platform.buttons.matching(NSPredicate(format: "label IN %@", ["完成", "Done", "关闭", "Close"])).firstMatch
        let ready = NSPredicate { _, _ in done.exists && !done.frame.isEmpty }
        if !waitUntil(ready, on: done) {
            app.native.images.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25)).tap()
            UITestSnapshotReader.invalidate()
        }
        assertUI(waitUntil(ready, on: done, timeout: 10), "系统预览应完成关闭控件布局。")
        return done
    }
}
