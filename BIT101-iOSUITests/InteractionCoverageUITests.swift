import CoreGraphics
import XCTest

nonisolated final class InteractionCoverageUITests: UIAutomationTestCase {
    @MainActor
    @objc func testSettingsRecoveryPreservesSchedule() {
        app = configureApp(resetStorage: true, content: true)
        addCustomSchedule("设置恢复保留日程", in: app)
        app = configureApp(
            resetStorage: false, content: true, settingsRecovery: true, initialSettings: "gallery")
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
            let inventory = try? JSONSerialization.jsonObject(with: Data(coverage.utf8))
                as? [String: Any],
            let observed = inventory["observedControls"] as? [String]
        {
            let confirmations = observed.filter {
                $0.contains("恢复当前账号的设置？") && $0.contains("settings.storage.confirm-recovery")
            }
            XCTAssertEqual(confirmations.count, 2, "两次确认框应各捕获一个恢复按钮。")
        } else {
            XCTFail("恢复操作应提供控件观察证据。")
        }
        let value = toggle("隐藏机器人帖子")
        app = configureApp(resetStorage: false, content: true, initialSettings: "gallery")
        let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "隐藏机器人帖子"))
            .firstMatch
        reveal(control)
        waitForValue(value, of: control)
        back()
        app.mainTab("日程").tapBriefly()
        assertUI(textElement("设置恢复保留日程").appears(timeout: 5), "恢复设置后应保留登录账号与原日程。")
    }

    @MainActor
    @objc func testCommunityCommentLikesRepliesSorts() {
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
        assertUI(
            app.buttons["测试"].appears(timeout: 5) && app.buttons["自动化"].exists, "编辑应显示帖子原有的自定义标签。")
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
        assertUI(
            waitUntil(NSPredicate(format: "exists == false"), on: comment, timeout: 5), "确认删除应移除评论。"
        )
    }

    @MainActor
    @objc func testBotFeedContinuesAcrossEmptyScanBatches() {
        app = configureApp(
            resetStorage: true, content: true, botPaging: true, initialTab: "gallery")
        tapHeader(app.segmentedControls.buttons["机器人"])
        let continuation = app.buttons["community.pagination.retry"]
        continuation.tapBriefly()
        assertUI(
            waitUntil(NSPredicate(format: "exists == true"), on: continuation), "空批完成后应恢复继续查询入口。")
        assertUI(textElement("机器人分页话题").exists == false, "首批续页保持空状态和继续入口。")
        continuation.tapBriefly()
        assertUI(textElement("机器人分页话题").appears(timeout: 5), "继续查询应展示后续源页中的机器人帖子。")
    }

    @MainActor
    @objc func testPaperSortSurvivesSwitchingTopics() throws {
        app = configureApp(
            resetStorage: true, content: true, animations: true, pagination: true,
            initialTab: "gallery")
        tapHeader(app.sectionTab("文章"))
        assertUI(app.sectionTab("文章").isSelected, "顶部选择应切换至文章分区。")
        assertUI(
            app.segmentedControls.buttons.matching(NSPredicate(format: "label == %@", "最新"))
                .allElementsBoundByIndex.filter(\.isHittable).count == 1,
            "文章页面应展示当前分区的排序控件。")
        assertUI(app.mainTab("日程").isHittable, "分区容器应保留 App 底部导航。")
        var feed: UIElement { visiblePaperFeed() }
        feed.swipeRight()
        assertUI(app.sectionTab("话题").isSelected, "文章首项向前滑动应返回话题。")
        tapHeader(app.sectionTab("文章"))
        assertUI(visibleSegment("最新").isSelected, "返回文章应保留最新排序。")
        var positions: [String: CGFloat] = [:]
        for title in ["高赞", "热评"] {
            tapHeader(visibleSegment(title))
            assertUI(visibleSegment(title).isSelected, "文章应选中\(title)。")
            let author = feed.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "自动化测试用户")
            ).firstMatch
            assertUI(author.appears(timeout: 10), "\(title)排序应完成作者信息加载。")
            let article = feed.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "分页文章 10")
            ).firstMatch
            reveal(article)
            let position = article.frame.minY
            positions[title] = position
            tapHeader(app.sectionTab("话题"))
            tapHeader(app.sectionTab("文章"))
            assertUI(visibleSegment(title).isSelected, "返回文章应保留\(title)排序。")
            assertUI(article.isHittable, "返回文章应保留当前阅读条目。")
            assertUI(abs(article.frame.minY - position) < 2, "返回文章应保留滚动位置。")
        }
        feed.swipeLeft()
        assertUI(app.sectionTab("文章").isSelected, "文章末项向外滑动应停留文章。")
        assertUI(visibleSegment("热评").isSelected, "文章末项应保持热评排序。")
        var article: UIElement {
            feed.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "分页文章 10")
            ).firstMatch
        }
        let position = try XCTUnwrap(positions["高赞"])
        feed.swipeRight()
        assertUI(visibleSegment("高赞").isSelected, "文章滑动应切回高赞。")
        assertUI(article.isHittable, "返回已访问排序应保留阅读条目。")
        assertUI(abs(article.frame.minY - position) < 2, "排序之间应分别保留滚动位置。")
        feed.swipeLeft()
        assertUI(visibleSegment("热评").isSelected, "文章滑动应恢复热评。")
        tapHeader(app.sectionTab("话题"))
        let topics = app.descendants(matching: .any)["gallery.feed-surface"]
        tapHeader(visibleSegment("关注"))
        topics.swipeRight()
        assertUI(app.sectionTab("话题").isSelected, "话题首项向外滑动应停留话题。")
        assertUI(visibleSegment("关注").isSelected, "话题首项应保持关注分类。")
        tapHeader(visibleSegment("最热"))
        topics.swipeLeft()
        assertUI(app.sectionTab("文章").isSelected, "话题末项向后滑动应进入文章。")
        tapHeader(app.sectionTab("话题"))
        assertUI(visibleSegment("最热").isSelected, "返回话题应保持最热分类。")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "界面截图"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    @objc func testGalleryFeed() {
        app = configureApp(resetStorage: true, content: true, initialTab: "gallery")
        assertUI(!visibleSegment("机器人").exists, "隐藏机器人时顶部分栏应同步隐藏。")
        openSettings("gallery")
        _ = toggle("隐藏机器人帖子")
        back()
        app.mainTab("话廊").tapBriefly()
        for title in ["关注", "最新", "最热", "机器人", "推荐"] {
            tapHeader(visibleSegment(title))
            assertUI(visibleSegment(title).isSelected, "话题分类应选中：\(title)。")
        }
        tapHeader(visibleSegment("机器人"))
        openSettings("gallery")
        _ = toggle("隐藏机器人帖子")
        back()
        app.mainTab("话廊").tapBriefly()
        assertUI(
            !visibleSegment("机器人").exists
                && visibleSegment("推荐").isSelected,
            "隐藏当前机器人分栏应选中推荐。")
        pullToRefresh()
        assertUI(textElement("自动化测试话题").exists, "话题列表刷新应保留服务结果。")
        assertUI(visibleSegment("推荐").isSelected, "竖向刷新应保留话题分类。")
        let feed = app.descendants(matching: .any)["gallery.feed-surface"]
        feed.swipeLeft()
        assertUI(visibleSegment("最新").isSelected, "话题横滑应切换分类。")
        feed.swipeRight()
        assertUI(visibleSegment("推荐").isSelected, "反向横滑应恢复分类。")
        tap("消息")
        assertUI(textElement("自动化测试消息").appears(timeout: 5), "消息面板应完成首屏加载。")
        pullToRefresh()
        assertUI(textElement("自动化测试消息").exists, "消息刷新应保留服务结果。")
        app.descendants(matching: .any)["gallery.message-surface"].swipeLeft()
        let likes = app.segmentedControls.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "点赞")
        ).firstMatch
        assertUI(likes.isSelected, "消息横滑应切换到点赞分类。")
        app.descendants(matching: .any)["gallery.message-surface"].swipeRight()
        let comments = app.segmentedControls.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "评论")
        ).firstMatch
        assertUI(comments.isSelected, "消息反向横滑应恢复评论分类。")
        let message = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "自动化测试消息"))
            .firstMatch
        reveal(message)
        message.tapBriefly()
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "消息行应打开关联帖子。")
        pullToRefresh()
        assertUI(textElement("自动化测试话题正文").exists, "帖子详情刷新应恢复正文。")
        back()
        for title in ["评论", "点赞", "关注", "系统"] {
            let segment = app.segmentedControls.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", title)
            ).firstMatch
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
        tapHeader(app.sectionTab("文章"))
        pullToRefresh()
        assertUI(textElement("自动化测试文章").exists, "文章列表刷新应恢复数据。")
        for title in ["最新", "高赞", "热评"] {
            tapHeader(visibleSegment(title))
            assertUI(visibleSegment(title).isSelected, "文章排序应更新选中项。")
        }
        tapHeader(visibleSegment("最新"))
        var paper: UIElement { visiblePaperFeed() }
        paper.swipeLeft()
        assertUI(visibleSegment("高赞").isSelected, "文章横滑应切换点赞排序。")
        paper.swipeLeft()
        assertUI(visibleSegment("热评").isSelected, "连续横滑应切换评论排序。")
        paper.swipeRight()
        assertUI(visibleSegment("高赞").isSelected, "反向横滑应恢复文章排序。")
        paper.swipeRight()
        assertUI(visibleSegment("最新").isSelected, "反向横滑应返回首个文章排序。")
        paper.swipeRight()
        assertUI(app.sectionTab("话题").isSelected, "文章首个排序向前横滑应返回话题。")
        tapHeader(visibleSegment("关注"))
        feed.swipeRight()
        assertUI(app.sectionTab("话题").isSelected, "话题首个分类向外横滑应保持话题。")
        tapHeader(app.sectionTab("文章"))
        tapHeader(visibleSegment("热评"))
        paper.swipeLeft()
        assertUI(app.sectionTab("文章").isSelected, "文章末尾排序向外横滑应保持文章。")
        tapHeader(app.sectionTab("话题"))
        tapHeader(visibleSegment("最热"))
        feed.swipeLeft()
        assertUI(app.sectionTab("文章").isSelected, "话题末尾分类向后横滑应进入文章。")
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
        app = configureApp(resetStorage: true, initialTab: "mine")
        openSettings("account")
        assertUI(app.alerts["加载资料失败"].appears(timeout: 5), "资料首读失败应提供明确提示。")
        closeAlertIfPresent()
        assertUI(textElement("个人信息加载失败").appears(timeout: 5), "账号页应保留资料重试入口。")
        tap("重试")
        assertUI(app.alerts["加载资料失败"].appears(timeout: 5), "原位重试应重新执行资料读取。")
        closeAlertIfPresent()
        app = configureApp(resetStorage: true, content: true, animations: true, initialTab: "mine")
        assertUI(textElement("自动化测试用户").appears(timeout: 5), "个人主页应先完成资料加载。")
        openSettings("account")
        let student = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "学号"))
            .firstMatch
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
        assertUI(
            textElement("保存后的昵称").appears(timeout: 5) && textElement("保存后的签名").exists,
            "设置保存后返回主页应更新资料卡。")
        pullToRefresh()
        assertUI(textElement("保存后的昵称").exists, "主页下拉刷新应保留已保存资料。")
        openSettings("account")
        tap("登录状态检查")
        assertUI(textElement("已登录").appears(timeout: 5), "登录检查应保留有效测试会话。")
        tap("退出登录")
        assertUI(app.textFields["login.student-id"].appears(timeout: 5), "退出应返回登录页。")
        signIn(app)
        assertUI(app.buttons["schedule.add-content"].appears(timeout: 5), "退出后应支持重新登录。")
    }

    @MainActor
    @objc func testSuggestionMissingContactSubmitFailure() {
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
    @objc func testCacheLimitPersistenceReset() {
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
    @objc func testCommunityMediaPreviewsDraftRetry() {
        app = configureApp(
            resetStorage: true, content: true, animations: true, media: true, initialTab: "gallery")
        tapImage("查看第1张图片")
        let preview = app.otherElements["QLPreviewControllerView"]
        assertUI(preview.appears(timeout: 30), "卡片图片应进入系统 Quick Look。")
        app = configureApp(
            resetStorage: false, content: true, animations: true, media: true, initialTab: "gallery"
        )
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
        let discard = app.alerts["放弃帖子修改？"]
        assertUI(discard.appears(timeout: 5), "退出编辑应确认待保存的帖子修改。")
        discard.buttons["gallery.editor.discard.cancel"].tapBriefly()
        assertUI(
            app.navigationBars["编辑帖子"].exists && !app.buttons["移除原有图片"].exists, "继续编辑应保留待保存的帖子修改。")
        tap("取消")
        discard.buttons["gallery.editor.discard.confirm"].tapBriefly()
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
        let photos = platform.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["照片", "Photos"])
        ).firstMatch
        assertUI(photos.appears(timeout: 30), "图片入口应呈现系统照片选择器。")
        let cancel = platform.buttons.matching(identifier: "Cancel").firstMatch
        assertUI(cancel.appears(timeout: 5), "系统照片选择器应提供取消操作。")
        cancel.tap()
        assertUI(photos.disappears(timeout: 5), "取消图片选择应关闭系统选择器。")
    }

}
