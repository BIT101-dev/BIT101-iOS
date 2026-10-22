import XCTest

nonisolated final class CommunityRecoveryUITests: UIAutomationTestCase {
    @MainActor
    @objc func testIdenticalFeedRefreshKeepsThePaginationPosition() {
        app = configureApp(resetStorage: true, content: true, media: true, pagination: true, initialTab: "gallery")
        tapHeader(app.segmentedControls.buttons["最新"])
        assertUI(textElement("分页话题 1").appears(timeout: 5), "信息流应提供稳定的首屏内容。")
        assertUI(UITestControlClient.request(["command": "hold-request", "key": "posters"]) == "queued", "刷新请求应进入受控等待。")
        defer { _ = UITestControlClient.request(["command": "release-request", "key": "posters"]) }
        pullToRefresh()
        assertUI(waitUntil(NSPredicate { _, _ in
            UITestControlClient.request(["command": "request-state", "key": "posters"]) == "pending"
        }, on: app), "下拉刷新应请求相同首屏。")
        _ = UITestControlClient.request(["command": "release-request", "key": "posters"])
        _ = UITestControlClient.request(["command": "hold-request", "key": "posters", "query.page": "1"])
        for _ in 1...8 {
            if UITestControlClient.request(["command": "request-state", "key": "posters"]) == "pending" { break }
            app.swipeUp()
        }
        assertUI(UITestControlClient.request(["command": "request-state", "key": "posters"]) == "pending", "列表尾部应请求下一页。")
        let loading = app.descendants(matching: .any).matching(identifier: "community.pagination.loading").firstMatch
        reveal(loading, description: "分页进度")
        _ = UITestControlClient.request(["command": "release-request", "key": "posters"])
        assertUI(loading.disappears(timeout: 5), "下一页完成后应结束分页进度。")
        assertUI(!textElement("分页话题 1").isHittable, "分页追加后应保持用户所在的列表尾部。")
        let nextPage = textElement("分页话题 9")
        reveal(nextPage, description: "追加的话题")
        assertUI(nextPage.isHittable, "下一页应追加可用内容。")
    }

    @MainActor
    @objc func testMessageReadStorageRecoveryKeepsMessagesAvailable() {
        app = configureApp(resetStorage: true, content: true, messageStorageRecovery: true, initialTab: "gallery")
        tap("消息")
        assertUI(app.alerts["消息状态同步受阻"].appears(timeout: 5), "已读存储受损应保留读取原因。")
        closeAlertIfPresent()
        assertUI(app.buttons["messages.storage.recover"].appears(timeout: 5), "消息正文旁应提供已读状态恢复入口。")
        assertUI(textElement("自动化测试消息").exists, "已读存储受损时应继续展示消息正文。")
        tap("messages.storage.retry")
        assertUI(app.alerts["消息状态同步受阻"].appears(timeout: 5), "重试应继续保留原始记录并展示结果。")
        closeAlertIfPresent()
        tap("messages.storage.recover")
        let confirmation = app.alerts["恢复消息已读状态？"]
        assertUI(confirmation.appears(timeout: 5), "恢复入口应展示当前账号已读记录的影响确认。")
        confirmation.buttons["取消"].tapBriefly()
        assertUI(app.buttons["messages.storage.recover"].exists, "取消恢复应保留原始已读记录。")
        tap("messages.storage.recover")
        assertUI(confirmation.appears(timeout: 5), "再次恢复应展示确认。")
        confirmation.buttons["恢复已读状态"].tapBriefly()
        assertUI(app.buttons["messages.storage.recover"].disappears(timeout: 5), "确认恢复应重建当前账号已读状态。")
        assertUI(textElement("自动化测试消息").exists, "恢复已读状态后应继续展示消息正文。")
        assertUI(app.buttons["取消"].exists, "恢复后应继续展示消息页面。")
        tap("取消")
    }

    @MainActor
    @objc func testDuplicatePagesKeepTheVisibleTailLoading() {
        for (tab, section, title) in [("home", "课程", "分页课程"), ("gallery", "文章", "分页文章"), ("mine", "", "分页话题")] {
            app = configureApp(resetStorage: true, content: true, pagination: true, duplicatePages: true, initialTab: tab)
            if tab == "mine" { tap("帖子") }
            else { tapHeader(app.segmentedControls.buttons[section]) }
            assertUI(textElement("\(title) 1").appears(timeout: 5), "首屏应展示分页夹具。")
            let next = textElement("\(title) 9")
            reveal(next, description: "重复页之后的内容")
            assertUI(next.isHittable, "跳过重复页后应继续加载新内容。")
        }
    }

    @MainActor
    @objc func testMessagePaginationRetriesAtTheVisibleTail() {
        app = configureApp(resetStorage: true, content: true, messagePagingFailureOnce: true, initialTab: "gallery")
        tap("消息")
        assertUI(app.alerts["加载更多失败"].appears(timeout: 10), "后续消息读取故障应展示原因。")
        closeAlertIfPresent()
        let retry = app.buttons["community.pagination.retry"]
        reveal(retry, description: "消息页尾重试")
        retry.tapBriefly()
        assertUI(textElement("重试后的消息").appears(timeout: 5), "原位重试应追加后续消息。")
        assertUI(textElement("分页首屏消息").exists, "重试应保留已加载消息。")
        tap("取消")
    }

    @MainActor
    @objc func testCommentReviewContinuesTheConfirmedSubmission() {
        app = configureApp(resetStorage: true, content: true, commentOutcomeUnknownOnce: true, initialTab: "gallery")
        tapHeader(app.segmentedControls.buttons["文章"])
        tap("自动化测试文章")
        tap("评论文章")
        replaceText("人工核对评论", in: app.textFields.firstMatch)
        dismissKeyboard()
        tap("发布")
        assertUI(app.alerts["发送结果待确认"].appears(timeout: 5), "发送结果待确认时应保留输入。")
        closeAlertIfPresent()
        assertUI(app.textFields.firstMatch.value as? String == "人工核对评论", "取消再次发送应保留输入。")
        tap("取消")
        tap("放弃输入")
        assertUI(textElement("人工核对评论").exists == false, "核对列表时应显示当前已确认的评论。")
        tap("评论文章")
        replaceText("人工核对评论", in: app.textFields.firstMatch)
        dismissKeyboard()
        tap("community.comment.review")
        assertUI(textElement("人工核对评论").appears(timeout: 5), "人工核对后应完成同一评论发送。")
    }

    @MainActor
    @objc func testLaterPreviewPageRecoversThroughTheNativeRetryButton() {
        app = configureApp(resetStorage: true, content: true, animations: true, media: true,
            mediaRecovery: true, initialTab: "gallery")
        assertUI(textElement("+1").appears(timeout: 5), "恢复场景应提供两张预览图片。")
        tap("查看第1张图片")
        assertUI(waitForImagePreview(visible: true, timeout: 15), "首张图片应打开系统预览。")
        _ = imagePreviewCloseButton()
        let failure = app.alerts["图片预览失败"]
        for _ in 0..<2 {
            swipeImagePreview(towardEnd: true)
            if failure.appears(timeout: 2) { break }
        }
        assertUI(failure.exists, "后续页故障应展示图片恢复提示。")
        closeAlertIfPresent()
        let retry = UIElement(app.native).buttons["media.preview.retry"]
        assertUI(retry.appears(timeout: 10), "后续页加载失败应提供原生重试按钮。")
        retry.tapBriefly()
        assertUI(retry.disappears(timeout: 10), "重试成功后应恢复图片并收起重试按钮。")
        assertUI(waitForImagePreview(visible: true, timeout: 5), "恢复图片应保留系统预览。")
        closeImagePreview()
    }

    @MainActor
    @objc func testMessagesAndFavoritesOpenNativeResources() {
        app = configureApp(resetStorage: true, content: true, resourceRoutes: true, initialTab: "gallery")
        tap("消息")
        tap("课程更新")
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "课程消息应打开原生课程详情。")
        back()
        tap("文章更新")
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5), "文章消息应打开原生文章详情。")
        back()
        tap("取消")
        tap("我的收藏")
        assertUI(textElement("加载收藏失败").appears(timeout: 5), "收藏首次故障应提供恢复入口。")
        tap("重试")
        tap("收藏课程")
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "课程收藏应打开原生课程详情。")
    }

    @MainActor
    @objc func testCommunityPaginationRetriesFromTheVisibleTail() {
        for (tab, section, title, search) in [("home", "课程", "分页课程", false), ("gallery", "文章", "分页文章", false),
            ("gallery", "最新", "分页话题", false), ("gallery", "文章", "分页文章", true)] {
            app = configureApp(resetStorage: true, content: true, pagination: true,
                paginationFailureOnce: !search, initialTab: tab)
            tapHeader(app.segmentedControls.buttons[section])
            if search {
                tap("搜索文章")
                _ = UITestControlClient.request(["command": "fail-request", "key": "papers", "query.page": "1", "query.search": "分页文章"])
                replaceText("分页文章\n", in: app.textFields.firstMatch)
            }
            let retry = app.buttons["community.pagination.retry"]
            let failure = app.alerts["加载更多失败"]
            for _ in 1...8 {
                if failure.exists { break }
                app.swipeUp()
            }
            assertUI(failure.appears(timeout: 5), "分页故障应展示当前请求的失败原因。")
            closeAlertIfPresent()
            reveal(retry, description: "分页原位重试")
            assertUI(retry.appears(timeout: 5), "分页故障应保留当前位置的重试入口。")
            retry.tapBriefly()
            let nextPage = textElement("\(title) 9")
            reveal(nextPage, description: "重试后第二页")
            assertUI(nextPage.isHittable, "重试应继续原游标并展示后续内容。")
        }
    }

    @MainActor
    @objc func testCourseLookupFailureKeepsTheSearchIdentity() {
        app = configureApp(resetStorage: true, content: true, school: true, courseLookupFailureOnce: true)
        tap("学校测试课程")
        tap("查看课程评价")
        assertUI(app.alerts["课程评价加载失败"].appears(timeout: 5), "两路检索故障应展示恢复原因。")
        closeAlertIfPresent()
        app.buttons["course.evaluation.search"].tapBriefly()
        assertUI(app.segmentedControls.buttons["课程"].appears(timeout: 5), "恢复入口应进入原生课程搜索。")
        assertUI(app.textFields["在这里搜索课程哦"].value as? String == "学校测试课程", "搜索应保留原课程名称。")
        assertUI(textElement("学校测试课程").appears(timeout: 5), "恢复后的搜索应展示可选择的课程。")
    }
}
