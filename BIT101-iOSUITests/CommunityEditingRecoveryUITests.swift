import XCTest

nonisolated final class CommunityEditingRecoveryUITests: UIAutomationTestCase {
    @MainActor
    @objc func testPosterImageWhitespaceOpensDetailsAndImageKeepsPreview() {
        app = configureApp(resetStorage: true, content: true, media: true, portraitMedia: true, initialTab: "gallery")
        let image = app.buttons["查看第1张图片"]
        assertUI(image.appears(timeout: 5), "话题卡片应展示图片。")
        let imageFrame = image.frame
        let rightEdge = app.frame.maxX - 16
        assertUI(imageFrame.maxX < rightEdge - 10, "单图右侧应保留可点击空白。")
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: rightEdge, dy: imageFrame.midY)).tapBriefly()
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "图片右侧空白应打开帖子详情。")
        back()
        image.tapBriefly()
        assertUI(waitForImagePreview(visible: true, timeout: 15), "图片点击应打开原生图片预览。")
        closeImagePreview()
        assertUI(!app.navigationBars["帖子详情"].exists, "看图结束应返回原话题列表。")
    }

    @MainActor
    @objc func testPosterCommentsRetryInPlaceAfterInitialFailure() {
        app = configureApp(resetStorage: true, content: true, initialTab: "gallery")
        assertUI(textElement("自动化测试话题").appears(timeout: 5), "话廊应先展示话题入口。")
        assertUI(UITestControlClient.request(["command": "fail-request", "key": "reaction/comments"]) == "queued",
                 "场景应准备评论首屏读取故障。")
        tap("自动化测试话题")
        assertUI(app.alerts["加载评论失败"].appears(timeout: 5), "评论故障应保留话题正文并呈现提示。")
        closeAlertIfPresent()
        tap("ui.app-failure-state.retry")
        assertUI(textElement("自动化测试评论").appears(timeout: 5), "评论区域重试应恢复内容。")
        assertUI(app.navigationBars["帖子详情"].exists, "恢复过程应保留当前话题详情。")
    }

    @MainActor
    @objc func testCommentEditorsProtectInputUntilConfirmedDiscard() {
        for kind in ["poster", "course", "paper"] {
            openDetail(kind)
            tap(kind == "poster" ? "评论帖子" : kind == "course" ? "评论课程" : "评论文章")
            let content = "保留\(kind)评论输入"
            replaceText(content, in: app.textFields.firstMatch)
            dismissKeyboard()
            let page = app.navigationBars["发表评论"]
            swipeSheetHeader(page)
            assertUI(app.textFields.firstMatch.value as? String == content, "下滑应保留当前评论输入。")
            tap("取消")
            let confirmation = app.alerts["放弃当前输入？"]
            assertUI(confirmation.appears(timeout: 5), "有输入的评论应展示明确的放弃选择。")
            confirmation.buttons["继续编辑"].tapBriefly()
            assertUI(app.textFields.firstMatch.value as? String == content, "继续编辑应保留评论正文。")
            tap("取消")
            confirmation.buttons["放弃输入"].tapBriefly()
            assertUI(page.disappears(timeout: 5), "确认放弃应完成评论编辑关闭。")
        }
    }

    @MainActor
    @objc func testCommentBodiesShareLinksImagesAndNativePreview() {
        for kind in ["poster", "course", "paper"] {
            openDetail(kind, mediaLinks: true)
            let like = app.buttons.matching(NSPredicate(format: "label IN %@", ["点赞评论", "取消评论点赞"])).firstMatch
            reveal(like, description: "评论操作")
            assertUI(like.frame.width.rounded() >= 44 && like.frame.height.rounded() >= 44,
                "评论点赞应提供完整触控区域：\(like.frame)。")
            like.native.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            assertUI(app.buttons["取消评论点赞"].appears(timeout: 5), "触控区域边缘应执行评论点赞。")
            let image = app.buttons["查看第1张图片"]
            reveal(image, description: "评论图片")
            image.tapBriefly()
            assertUI(waitForImagePreview(visible: true, timeout: 15), "各类评论图片应进入原生预览。")
            closeImagePreview()
            tapLink("example.com/comment")
            assertOpenedURL("example.com/comment")
        }
    }

    @MainActor
    @objc func testCourseCommentsRecoverWhileHistoryLoadsIndependently() {
        app = configureApp(resetStorage: true, content: true, courseCommentRecovery: true, initialTab: "home")
        tapHeader(app.segmentedControls.buttons["课程"])
        tap("自动化测试课程")
        waitForRequest("course-comments")
        assertUI(app.descendants(matching: .any)["course.history.chart"].appears(timeout: 5), "慢评论请求期间应展示已取得的历史成绩。")
        reveal(textElement("正在加载评论"))
        releaseRequest("course-comments")
        assertUI(app.alerts["加载评论失败"].appears(timeout: 5), "评论读取失败应保留错误原因。")
        closeAlertIfPresent()
        tap("重试")
        assertUI(textElement("自动化测试评论").appears(timeout: 5), "评论区域的重试应恢复正文。")
        reveal(app.buttons["点赞课程"])
        app.scrollViews["interaction.CourseDetailViewScene.scroll"].swipeDown()
        assertUI(app.navigationBars["课程详情"].exists, "详情下拉刷新应保留当前课程页面。")
    }

    @MainActor
    @objc func testFailedPaperSortKeepsTheDisplayedConditionVisible() {
        app = configureApp(resetStorage: true, content: true, initialTab: "gallery")
        tapHeader(app.segmentedControls.buttons["文章"])
        assertUI(textElement("自动化测试文章").appears(timeout: 5), "文章首屏应完成加载。")
        assertUI(UITestControlClient.request(["command": "fail-request", "key": "papers"]) == "queued", "场景应准备下一次文章读取故障。")
        tapHeader(app.segmentedControls.buttons["高赞"])
        assertUI(app.alerts["刷新文章失败"].appears(timeout: 5), "切换排序失败应保留已加载的文章。")
        closeAlertIfPresent()
        assertUI(textElement("当前显示：全部文章 · 最新").exists, "页面应标明保留结果的实际排序。")
        assertUI(textElement("自动化测试文章").exists, "排序故障期间应继续阅读已有内容。")
        tapHeader(app.segmentedControls.buttons["热评"])
        assertUI(textElement("当前显示：全部文章 · 最新").disappears(timeout: 5), "新条件完成读取后应更新结果上下文。")
    }

    @MainActor
    @objc func testUploadedCommentImageCanBePreviewedAndRemoved() {
        openDetail("poster", mediaLinks: true)
        tap("评论帖子")
        replaceText("移除误选评论图片", in: app.textFields.firstMatch)
        dismissKeyboard()
        tap("添加评论图片")
        selectFirstPhoto()
        assertUI(textElement("已添加 1 张图片").appears(timeout: 30), "系统照片导入完成后应将图片加入附件列表。")
        let retry = app.buttons["重试"]
        assertUI(retry.appears(timeout: 5), "上传故障应保留原选图并提供重试。")
        assertUI(textElement("已添加 1 张图片").exists, "失败图片应继续留在附件列表。")
        retry.tapBriefly()
        assertUI(textElement("已上传").appears(timeout: 10), "重试应直接完成原选图上传。")
        tap("预览第1张评论图片")
        closeImagePreview()
        tap("移除第1张评论图片")
        assertUI(textElement("已添加 1 张图片").disappears(timeout: 5), "移除应更新当前评论附件。")
        assertUI(app.textFields.firstMatch.value as? String == "移除误选评论图片", "图片编辑应保留评论文字。")
        tap("取消")
        tap("放弃输入")
    }

    @MainActor
    @objc func testSuggestionSaveWaitsForSelectedImageImport() {
        app = configureApp(resetStorage: true, content: true, imageImportHold: true)
        openSettings("suggestion")
        replaceText("等待图片导入的建议", in: app.textFields["建议内容"])
        dismissKeyboard()
        tap("插入图片")
        selectFirstPhoto()
        waitForRequest("image-import")
        tap("取消")
        tap("保存草稿")
        app.textFields["建议内容"].assertDisabled("保存应在当前图片导入期间保护正文。")
        assertUI(app.navigationBars["向开发者提建议"].exists, "草稿应等待已选择图片导入完成。")
        releaseRequest("image-import")
        assertUI(app.navigationBars["向开发者提建议"].disappears(timeout: 10), "图片导入与保存完成后应关闭编辑器。")
        openSettings("suggestion")
        tap("加载草稿")
        assertUI(app.textFields["建议内容"].value as? String == "等待图片导入的建议", "重新装载应恢复建议文字。")
        assertUI(app.buttons["移除图片"].appears(timeout: 5), "保存的草稿应包含已选择的图片。")
        tap("取消")
        tap("不保存")
    }

    @MainActor
    @objc func testReportEditingAndSubmissionKeepTheirSheet() {
        openDetail("poster")
        func openReport() {
            let comment = textElement("自动化测试评论")
            reveal(comment, description: "举报目标评论")
            comment.press(forDuration: 1)
            tap("举报评论")
        }
        openReport()
        replaceText("保留举报说明", in: app.textFields["gallery.report.reason"])
        dismissKeyboard()
        swipeSheetHeader(app.navigationBars["举报评论"])
        assertUI(app.textFields["gallery.report.reason"].value as? String == "保留举报说明", "下滑应保留当前举报说明。")
        tap("取消")
        tap("继续编辑")
        assertUI(app.textFields["gallery.report.reason"].value as? String == "保留举报说明", "继续编辑应保留举报载荷。")
        tap("取消")
        tap("放弃输入")
        openReport()
        replaceText("等待举报回执", in: app.textFields["gallery.report.reason"])
        dismissKeyboard()
        assertUI(UITestControlClient.request(["command": "hold-request", "key": "manage/reports"]) == "queued", "举报提交应进入受控等待。")
        defer { _ = UITestControlClient.request(["command": "release-request", "key": "manage/reports"]) }
        tap("提交举报")
        waitForRequest("manage/reports")
        swipeSheetHeader(app.navigationBars["举报评论"])
        assertUI(app.textFields["gallery.report.reason"].exists, "提交期间应保持举报编辑页。")
        assertUI(!app.textFields["gallery.report.reason"].isEnabled, "提交期间应保护已捕获的举报载荷。")
        releaseRequest("manage/reports")
        assertUI(app.alerts["举报已提交"].appears(timeout: 5), "回执应在原编辑页中完成确认。")
        tap("知道了")
    }

    @MainActor
    @objc func testContentControlsRemainAvailableAtAccessibilityTextSizes() {
        for style in ["Light", "Dark"] {
            app = configureApp(resetStorage: true, accessibilityTextSize: true, userInterfaceStyle: style,
                content: true, media: true, longTags: true, initialTab: "home")
            tapHeader(app.segmentedControls.buttons["课程"])
            let course = textElement("自动化测试课程")
            assertUI(course.appears(timeout: 5) && course.isHittable, "大字号课程列表应提供可读、可触达的课程卡片。")
            tap("自动化测试课程")
            let like = app.buttons.matching(identifier: "ui.app-comment-action-bar.like").firstMatch
            reveal(like, description: "大字号评论操作")
            assertUI(like.isHittable && like.frame.width.rounded() >= 44 && like.frame.height.rounded() >= 44,
                "大字号评论操作应保持完整触控区域：\(like.frame)。")
            let author = app.buttons.matching(NSPredicate(format: "label == %@", "自动化测试用户")).firstMatch
            reveal(author, description: "大字号评论作者")
            assertUI(author.frame.height.rounded() >= 44 && author.isHittable, "评论昵称应保持原生触控尺寸：\(author.frame)。")
            author.tapBriefly()
            assertUI(app.buttons["关注"].appears(timeout: 5), "昵称操作应进入含头像与统计的作者主页。")
            back()
            back()
            app.mainTab("我的").tapBriefly()
            let followers = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@",
                "ui.mine-stat-button.destination", "粉丝")).firstMatch
            reveal(followers, description: "大字号主页统计")
            assertUI(followers.isHittable && followers.frame.height.rounded() >= 44,
                "头像统计区域应提供可触达的粉丝入口：\(followers.frame)。")
            followers.tapBriefly()
            assertUI(app.navigationBars["我的粉丝"].appears(timeout: 5), "大字号统计入口应打开对应列表。")
            back()
            app.mainTab("话廊").tapBriefly()
            tapHeader(app.segmentedControls.buttons["最新"])
            let tags = app.scrollViews.matching(identifier: "interaction.CommunityPosterCard.scroll").firstMatch
            reveal(tags, description: "大字号长标签")
            tags.native.swipeLeft(velocity: .slow)
            assertUI(app.segmentedControls.buttons["最新"].isSelected && app.segmentedControls.buttons["话题"].isSelected,
                "横向标签滚动应保持当前信息流分区。")
            let posterBody = app.descendants(matching: .any).matching(identifier: "community.poster.1").firstMatch
            reveal(posterBody, description: "话题正文横滑区域")
            posterBody.swipeLeft()
            assertUI(!app.segmentedControls.buttons["最新"].isSelected, "标签区域外应继续支持分区切换。")
        }
    }

    @MainActor
    private func openDetail(_ kind: String, mediaLinks: Bool = false) {
        app = configureApp(resetStorage: true, content: true, animations: true, media: mediaLinks,
            commentMediaLinks: mediaLinks, initialTab: kind == "course" ? "home" : "gallery")
        if kind == "course" { tapHeader(app.segmentedControls.buttons["课程"]) }
        if kind == "paper" { tapHeader(app.segmentedControls.buttons["文章"]) }
        tap(kind == "poster" ? "自动化测试话题" : kind == "course" ? "自动化测试课程" : "自动化测试文章")
    }

    @MainActor
    private func waitForRequest(_ key: String) {
        assertUI(waitUntil(NSPredicate { _, _ in
            UITestControlClient.request(["command": "request-state", "key": key]) == "pending"
        }, on: app), "请求应进入受控等待状态。")
    }

    @MainActor
    private func releaseRequest(_ key: String) {
        assertUI(UITestControlClient.request(["command": "release-request", "key": key]) == "released", "场景应释放原请求。")
    }

    @MainActor
    private func selectFirstPhoto() {
        let platform = UIElement(app.native)
        let photos = platform.buttons.matching(NSPredicate(format: "label IN %@", ["照片", "Photos"])).firstMatch
        assertUI(photos.appears(timeout: 30), "图片入口应呈现系统照片选择器。")
        let first = UIElement(app.native.images.matching(identifier: "PXGGridLayout-Info").firstMatch)
        assertUI(first.appears(timeout: 5), "照片选择器应展示固定测试图片。")
        first.tapBriefly()
        let add = platform.buttons.matching(identifier: "Add").firstMatch
        assertUI(add.appears(timeout: 5), "选择图片后应提供添加操作。")
        add.tapBriefly()
        assertUI(photos.disappears(timeout: 5), "确认选择应返回编辑器。")
    }
}
