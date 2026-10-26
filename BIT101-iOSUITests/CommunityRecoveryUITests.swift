import XCTest

nonisolated final class LandscapeLayoutUITests: UIAutomationTestCase {
    @MainActor
    @objc func testCurrentWindowUsesAdaptivePanesAndReadableCards() {
        app = configureApp(resetStorage: true, content: true, school: true, pagination: true, initialTab: "mine")
        let frame = app.windows.firstMatch.frame
        if frame.height > frame.width {
            assertUI(!app.collectionViews["mine.sidebar"].exists, "竖向窗口应合并资料与设置入口。")
            assertUI(app.mainTab("我的").isHittable, "竖向窗口保留主导航。")
            return
        }
        func assertPanes(_ sidebarID: String, _ contentID: String) {
            let sidebar = app.descendants(matching: .any)[sidebarID]
            let content = app.descendants(matching: .any)[contentID]
            assertUI(waitUntil(NSPredicate { _, _ in
                sidebar.exists && content.exists && sidebar.frame.maxX <= content.frame.minX + 1
            }, on: app), "横屏应并排呈现侧栏和主体：\(sidebarID)。")
        }
        assertPanes("mine.sidebar", "interaction.MineRootViewScene.list")
        openSettings("account")
        tap("昵称")
        let input = app.textFields.firstMatch
        replaceText("横屏编辑草稿", in: input)
        dismissKeyboard()
        assertUI(input.value as? String == "横屏编辑草稿", "横屏编辑与键盘收起保留完整草稿。")
        tap("取消")
        back()
        app.mainTab("成绩").tapBriefly()
        assertPanes("score.sidebar", "interaction.ScoreListPage.list")
        reveal(textElement("加权 GPA"), description: "侧栏统计")
        app.mainTab("日程").tapBriefly()
        tapHeader(app.segmentedControls.buttons["空教室"])
        assertPanes("classroom.sidebar", "interaction.FreeClassroomTabView.list")
        tapHeader(app.segmentedControls.buttons["DDL"])
        assertUI(app.scrollViews["interaction.DDLScheduleTabView.grid"].appears(timeout: 5), "横屏待办应进入卡片网格。")
        assertUI(app.buttons["添加待办"].isHittable, "横屏待办保留添加入口。")
        app.mainTab("话廊").tapBriefly()
        tapHeader(app.segmentedControls.buttons["最新"])
        let first = app.descendants(matching: .any)["community.poster.card.1"]
        let second = app.descendants(matching: .any)["community.poster.card.2"]
        assertUI(waitUntil(NSPredicate { _, _ in
            first.exists && second.exists && first.frame.maxX <= second.frame.minX
                && first.frame.minY < second.frame.maxY && second.frame.minY < first.frame.maxY
        }, on: app), "横屏话题应使用并排卡片。")
        tapHeader(app.segmentedControls.buttons["文章"])
        let paper = textElement("分页文章 1"), nextPaper = textElement("分页文章 2")
        assertUI(waitUntil(NSPredicate { _, _ in
            paper.exists && nextPaper.exists && paper.frame.maxX <= nextPaper.frame.minX
                && paper.frame.minY < nextPaper.frame.maxY && nextPaper.frame.minY < paper.frame.maxY
        }, on: app), "横屏文章应使用并排卡片。")
        app.mainTab("地图").tapBriefly()
        let layer = app.buttons["切换地图图层"]
        assertUI(layer.appears(timeout: 5) && app.windows.firstMatch.frame.contains(layer.frame), "横屏地图应完整显示图层工具。")
        layer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapBriefly()
        waitForValue("卫星图", of: layer)
        app = configureApp(resetStorage: true, accessibilityTextSize: true, content: true, school: true, initialTab: "mine")
        assertUI(textElement("自动化测试用户").appears(timeout: 5), "大字号窗口保留资料内容。")
        assertUI(!app.collectionViews["mine.sidebar"].exists, "辅助功能字号采用完整宽度的单列内容。")
    }
}

nonisolated final class AuthenticationLifecycleUITests: UIAutomationTestCase {
    @MainActor
    @objc func testLeavingRegistrationCancelsThePendingLoginActivation() {
        app = configureApp(resetStorage: true, account: nil)
        app.buttons["login.register"].tapBriefly()
        replaceTextWithKeyboard("1120260001", in: app.textFields["registration.student-id"])
        replaceTextWithKeyboard("community-password", in: app.secureTextFields["registration.password"])
        replaceTextWithKeyboard("community-password", in: app.secureTextFields["registration.confirmation"])
        replaceTextWithKeyboard("school-password", in: app.secureTextFields["registration.school-password"])
        dismissKeyboard()
        let verify = app.buttons["registration.verify"]
        reveal(verify)
        verify.tapBriefly()
        reveal(app.buttons["registration.submit"])
        _ = UITestControlClient.request(["command": "hold-request", "key": "registration-submit"])
        app.buttons["registration.submit"].tapBriefly()
        waitForRequest("registration-submit")
        back()
        releaseRequest("registration-submit")
        assertUI(waitUntil(NSPredicate { _, _ in
            UITestControlClient.request(["command": "request-state", "key": "registration-submit"]) == "completed"
        }, on: app), "已退出注册页面的响应应完成取消处理。")
        assertUI(app.textFields["login.student-id"].exists, "注册页面退出后应保留登录表单。")
        assertUI(!app.mainTab("日程").exists, "已退出的注册提交应结束自身的登录激活。")
    }
}

nonisolated final class CommunityRecoveryUITests: UIAutomationTestCase {
    @MainActor
    @objc func testPaperSearchRefreshKeepsItsQueryAndUsesTheOwnedRequest() {
        app = configureApp(resetStorage: true, content: true, pagination: true, initialTab: "gallery")
        tapHeader(app.segmentedControls.buttons["文章"])
        tap("搜索文章")
        assertUI(app.navigationBars["搜索"].appears(timeout: 5), "搜索入口应打开原生搜索页面。")
        replaceText("分页文章\n", in: app.textFields.firstMatch)
        dismissKeyboard()
        assertUI(textElement("分页文章 1").appears(timeout: 5), "搜索应先展示当前查询的结果。")
        _ = UITestControlClient.request(["command": "hold-request", "key": "papers", "query.page": "0", "query.search": "分页文章"])
        pullToRefresh()
        assertUI(app.navigationBars["搜索"].exists, "下拉刷新应保留搜索页面。")
        waitForRequest("papers")
        releaseRequest("papers")
        assertUI(app.textFields.firstMatch.value as? String == "分页文章", "刷新应保留搜索条件。")
        assertUI(textElement("分页文章 1").appears(timeout: 5), "刷新后应继续展示当前查询。")
    }

    @MainActor
    @objc func testLongPostAndCommentKeepACompleteNativeReadingPath() {
        app = configureApp(resetStorage: true, content: true, longText: true, initialTab: "gallery")
        tap("自动化测试话题")
        let readers = app.buttons.matching(identifier: "ui.community-linked-text.read-full")
        reveal(readers.firstMatch, description: "长帖完整阅读入口")
        readers.firstMatch.tapBriefly()
        let content = app.textViews["community.full-text"]
        assertUI(content.appears(timeout: 5), "全文应进入原生文本阅读视图。")
        assertUI((content.value as? String)?.hasSuffix("长帖末尾") == true, "完整阅读应保留长帖末尾内容。")
        content.tapBriefly()
        content.swipeUp()
        tap("完成")
        reveal(app.buttons["回复"], description: "长评论操作")
        guard let commentReader = readers.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            assertUI(false, "长评论应提供完整阅读入口。")
            return
        }
        commentReader.tapBriefly()
        assertUI(content.appears(timeout: 5), "长评论应进入原生文本阅读视图。")
        assertUI((content.value as? String)?.hasSuffix("长评末尾") == true, "完整阅读应保留长评论末尾内容。")
        content.tapBriefly()
        content.swipeUp()
        tap("完成")
    }

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
        assertUI(UITestControlClient.request(["command": "release-request", "key": "media-recovery"]) == "released",
                 "原生重试前应恢复图片传输。")
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
            app = configureApp(resetStorage: true, content: true, pagination: true, initialTab: "mine")
            if !search {
                let path = tab == "home" ? "courses" : section == "文章" ? "papers" : "posters"
                var failure = ["command": "fail-request", "key": path, "query.page": "1"]
                if path == "posters" { failure["query.order"] = "new" }
                _ = UITestControlClient.request(failure)
            }
            app.mainTab(tab == "home" ? "成绩" : "话廊").tapBriefly()
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

extension CommunityInteractionUITests {
    @MainActor
    @objc func testStableRowsPaginateAgainAfterRefreshingTheSameResults() {
        for (tab, section, title) in [("home", "课程", "分页课程"), ("gallery", "文章", "分页文章")] {
            app = configureApp(resetStorage: true, content: true, pagination: true, initialTab: tab)
            tapHeader(app.segmentedControls.buttons[section])
            let first = app.staticTexts["\(title) 1"]
            let secondPage = app.staticTexts["\(title) 9"]
            assertUI(first.appears(timeout: 5), "首屏应展示稳定身份的分页夹具。")
            reveal(secondPage, description: "首轮第二页")
            assertUI(secondPage.isHittable, "首轮滚动应加载第二页。")
            if tab == "home" {
                let readingY = secondPage.frame.minY
                tapHeader(app.segmentedControls.buttons["成绩"])
                tapHeader(app.segmentedControls.buttons["课程"])
                assertUI(secondPage.isHittable && abs(secondPage.frame.minY - readingY) < 1, "切换成绩与课程应保留课程阅读位置。")
            }
            let request = tab == "home" ? "courses" : "papers"
            _ = UITestControlClient.request(["command": "hold-request", "key": request, "query.page": "0"])
            for _ in 0..<8 {
                if first.exists && first.isHittable { break }
                pullToRefresh()
            }
            assertUI(first.isHittable, "刷新前应回到首屏。")
            for _ in 0..<3 {
                if UITestControlClient.request(["command": "request-state", "key": request]) == "pending" { break }
                pullToRefresh()
            }
            waitForRequest(request)
            releaseRequest(request)
            assertUI(first.appears(timeout: 5), "刷新应保留相同的首屏对象。")
            reveal(secondPage, description: "刷新后第二页")
            assertUI(secondPage.isHittable, "刷新相同结果后应继续加载第二页。")
        }
    }
}

nonisolated final class MineInteractionUITests: UIAutomationTestCase {
    @MainActor
    @objc func testMinePublicProfileFollowAndPostDeletion() {
        app = configureApp(resetStorage: true, initialTab: "mine")
        assertUI(textElement("个人信息加载失败").appears(timeout: 5), "离线个人页应完成服务加载并展示恢复入口。")
        app = configureApp(resetStorage: true, content: true, animations: true, media: true, minePagingFailureOnce: true, initialTab: "mine")
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
        _ = imagePreviewCloseButton()
        app.native.descendants(matching: .any)["QLPreviewControllerView"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        UITestSnapshotReader.invalidate()
        assertUI(waitForImagePreview(visible: true, timeout: 5), "点击预览画布应保留当前头像预览。")
        app.native.images.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25)).tap()
        UITestSnapshotReader.invalidate()
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
        tap("编辑帖子")
        replaceText("个人列表更新后的话题", in: app.textFields["标题"])
        dismissKeyboard()
        tap("保存")
        assertUI(textElement("个人列表更新后的话题").appears(timeout: 5), "编辑应刷新话题详情。")
        dismissPosterSheet(returningTo: "我的帖子")
        assertUI(textElement("个人列表更新后的话题").appears(timeout: 5), "个人列表应同步编辑结果。")
        tap("更多操作")
        tap("删除帖子")
        app.alerts.buttons["取消"].tapBriefly()
        tap("更多操作")
        tap("删除帖子")
        app.alerts.buttons["删除"].tapBriefly()
        let poster = textElement("自动化测试话题")
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: poster, timeout: 5), "个人列表删除应移除帖子。")
        assertUI(textElement("暂无可显示的帖子").appears(timeout: 5), "删除末条帖子应展示空态。")
        pullToRefresh()
        assertUI(textElement("暂无可显示的帖子").exists, "成功空态应继续支持下拉刷新。")
    }
}
