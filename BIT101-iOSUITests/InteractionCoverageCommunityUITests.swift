import CoreGraphics
import XCTest

nonisolated final class CommunityInteractionUITests: UIAutomationTestCase {
    @MainActor
    @objc func testPosterSubscriptionsPersist() {
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
            assertUI(
                waitUntil(NSPredicate(format: "value == %@", level), on: bookmark, timeout: 5),
                "插眼应保存所选订阅级别。")
        }
        back()
        tap("我的收藏")
        tap("加载更多收藏")
        tap("自动化测试话题")
        assertUI(
            waitUntil(NSPredicate(format: "value == %@", "订阅更新与评论"), on: bookmark, timeout: 5),
            "从收藏重开详情应读取服务端状态。")
        tapHeader(bookmark)
        tap("取消插眼")
        assertUI(
            waitUntil(NSPredicate(format: "value == %@", "尚未插眼"), on: bookmark, timeout: 5),
            "取消后应恢复空心收藏状态。")
        back()
        assertUI(textElement("还没有收藏").appears(timeout: 5), "取消插眼后收藏列表应同步移除话题。")
        tap("完成")
        tap("消息")
        tapHeader(
            app.segmentedControls.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "插眼"))
                .firstMatch)
        assertUI(textElement("自动化测试消息").appears(timeout: 5), "消息中心应展示插眼更新。")
        tap("取消")
    }

    @MainActor
    @objc func testGalleryBlockingUpdatesLoadedFeeds() {
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
        app = configureApp(
            resetStorage: true, content: true, animations: true, media: true, initialTab: "gallery")
        tapHeader(app.sectionTab("文章"))
        tap("自动化测试文章")
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5), "点击卡片应打开文章。")
        back()
        let summary = app.descendants(matching: .any)["paper.summary.1"]
        assertUI(
            summary.elementType == .button && summary.performAccessibilityAction(),
            "文章卡片应提供可执行的 VoiceOver 默认动作。")
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
        assertUI(
            waitUntil(NSPredicate(format: "label == %@", "取消文章点赞"), on: headerLike, timeout: 5),
            "正文末尾点赞应同步顶部状态。")
        footerLike.tapBriefly()
        assertUI(
            waitUntil(NSPredicate(format: "label == %@", "点赞文章"), on: headerLike, timeout: 5),
            "正文末尾取消点赞应同步顶部状态。")
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
        screenshot.name = "界面截图：文章更多菜单"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        tap("分享文章")
        dismissShareSheet()
        tap("评论文章")
        tap("取消")
        assertUI(app.navigationBars["文章详情"].exists, "取消评论应恢复文章详情。")
    }

    @MainActor
    @objc func testCourseCommentPublishSearch() {
        app = configureApp(
            resetStorage: true, content: true, animations: true, media: true, initialTab: "home")
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
        assertUI(
            waitUntil(
                NSPredicate(format: "value == %@", original == "全部显示" ? "隐藏疑似补考" : "全部显示"),
                on: cleaning, timeout: 5), "数据清洗应改变历史成绩展示策略。")
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
        let commentEntry = app.buttons.matching(NSPredicate(format: "label == %@", "评论课程"))
            .firstMatch
        reveal(commentEntry, description: "评论课程")
        commentEntry.tapBriefly()
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
    @objc func testPosterReportSelectionCancel() {
        app = configureApp(
            resetStorage: true, content: true, reportFailureOnce: true, initialTab: "gallery")
        tap("更多操作")
        tap("举报帖子")
        assertUI(
            app.buttons["ui.gallery-report-sheet.reload"].appears(timeout: 5), "分类读取失败应提供重新加载入口。")
        let submit = app.descendants(matching: .any).matching(
            identifier: "ui.gallery-report-sheet.submit"
        ).firstMatch
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
    @objc func testExternalLinksAbout() {
        app = configureApp(resetStorage: true, content: true, initialSettings: "about")
        for (entry, url) in [
            ("项目仓库", "github.com/BIT101-dev/BIT101-iOS"), ("QQ交流群", "jq.qq.com"),
            ("邮箱", "mailto:systemd@linux.do"), ("ICP备案", "beian.miit.gov.cn"),
        ] {
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
    @objc func testManualUpdatePromptAllActions() {
        app = configureApp(
            resetStorage: true, animations: true, update: "new", initialSettings: "about")
        app.native.typeKey(XCUIKeyboardKey.shift, modifierFlags: [])
        for action in ["本次忽略", "忽略此版本", "前往 App Store"] {
            tap("检查更新")
            assertUI(app.alerts["发现新版本 999.0"].appears(timeout: 5), "更新响应应展示新版本。")
            tap(action)
            if action == "前往 App Store" {
                assertOpenedURL("apps.apple.com/cn/app/bit101/id6761147125")
            }
        }
        tap("检查更新")
        assertUI(app.alerts["发现新版本 999.0"].appears(timeout: 5), "键盘验收应展示更新提示。")
        app.alerts.buttons["ui.app-prompt-host-modifier.default-action"].pressReturnKey()
        assertOpenedURL("apps.apple.com/cn/app/bit101/id6761147125")
        assertUI(app.alerts["发现新版本 999.0"].disappears(timeout: 5), "Return 应完成当前更新提示并恢复页面。")
        app = configureApp(
            resetStorage: true, animations: true, update: "current", initialSettings: "about")
        tap("检查更新")
        assertUI(app.alerts["已是最新版本"].appears(timeout: 5), "当前版本响应应展示检查结果。")
        closeAlertIfPresent()
    }

    @MainActor
    @objc func testOfflineRecoveryRetry() {
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
        dismissKeyboard()
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
    @objc func testCommunityFailedRequestsRetryState() {
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
    @objc func testSuggestionSuccessfulDiscardSavedDraft() {
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
        assertUI(
            waitUntil(NSPredicate(format: "exists == false"), on: page, timeout: 5), "提交成功应关闭建议页。")
        openSettings("suggestion")
        assertUI(!app.alerts["加载草稿？"].exists, "提交成功应清理建议草稿。")
        tap("取消")
    }

    @MainActor
    @objc func testSuggestionSubmissionProtectsPayload() {
        app = configureApp(resetStorage: true, content: true, animations: true, feedbackHold: true)
        openSettings("suggestion")
        replaceText("提交期间保留建议", in: app.textFields["建议内容"])
        dismissKeyboard()
        replaceText("测试联系信息", in: app.textFields["联系方式"])
        dismissKeyboard()
        tap("提交")
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    UITestControlClient.request(["command": "request-state", "key": "feedback"])
                        == "pending"
                }, on: app),
            "建议请求应进入受控的等待状态。")
        app.textFields["建议内容"].assertDisabled("等待提交结果期间应保护建议正文。")
        app.textFields["联系方式"].assertDisabled("等待提交结果期间应保护联系方式。")
        app.buttons["ui.developer-suggestion-page.插入图片"].assertDisabled("等待提交结果期间应保护附件。")
        app.buttons["取消"].assertDisabled("等待提交结果期间应保留编辑器。")
        let page = app.navigationBars["向开发者提建议"]
        swipeSheetHeader(page)
        assertUI(
            page.exists && app.textFields["建议内容"].value as? String == "提交期间保留建议",
            "下滑应保留等待中的建议与结果上下文。")
        assertUI(
            UITestControlClient.request(["command": "release-request", "key": "feedback"])
                == "released", "传输夹具应完成原请求。")
        assertUI(page.disappears(timeout: 5), "提交成功应完成建议流程。")
    }

    @MainActor
    @objc func testRecoveredSuggestionPreservesContent() {
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
        assertUI(
            app.navigationBars["向开发者提建议"].disappears(timeout: 5), "恢复的文字、联系方式和可用图片应以新的提交身份成功发送。")
    }

    @MainActor
    @objc func testSchoolSmsCourseSyncValidationCancel() {
        app = configureApp(resetStorage: true, animations: true, school: true, schoolSMS: true)
        tapHeader(app.sectionTab("空教室"))
        tapHeader(app.sectionTab("课表"))
        let refresh = app.descendants(matching: .any)["schedule.refresh-status"].buttons[
            "app.refresh-status.action"]
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
    @objc func testSchoolSsoddlVerifyCancel() {
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
