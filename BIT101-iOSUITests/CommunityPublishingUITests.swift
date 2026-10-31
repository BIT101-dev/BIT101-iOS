import XCTest

nonisolated final class CommunityPublishingUITests: UIAutomationTestCase {
    @MainActor
    func testGalleryPublicationReviewSurvivesRestartAndDraftRestore() {
        publicationReviewSurvivesRestart(paper: false)
    }

    @MainActor
    func testPaperPublicationReviewSurvivesRestartAndDraftRestore() {
        publicationReviewSurvivesRestart(paper: true)
    }

    @MainActor
    private func publicationReviewSurvivesRestart(paper: Bool) {
        app = configureApp(resetStorage: true, content: true, publicationOutcomeUnknownOnce: true, initialTab: "gallery")
        if paper { tapHeader(app.sectionTab("文章")) }
        tap(paper ? "发布文章" : "发布话题")
        let title = paper ? "核对后的文章" : "核对后的话题"
        replaceText(title, in: app.textFields["标题"])
        if paper { replaceText("保留简介", in: app.textFields["简介"]) }
        replaceText("保留发布内容", in: app.textFields["正文"])
        dismissKeyboard()
        if !paper { tap("活动"); tap("聊天") }
        tap("发布")
        assertUI(app.alerts["发布结果待确认"].appears(timeout: 5), "回执丢失应要求核对发布结果。")
        closeAlertIfPresent()
        tap("取消")
        tap(paper ? "暂存并离开" : "保存草稿")
        app = configureApp(resetStorage: false, restartProcess: true, content: true, initialTab: "gallery")
        if paper { tapHeader(app.sectionTab("文章")) }
        tap(paper ? "发布文章" : "发布话题")
        tap(paper ? "恢复草稿" : "加载草稿")
        assertUI(app.textFields["标题"].value as? String == title, "重新启动应保留原有草稿。")
        let submit = app.buttons[paper ? "ui.paper-composer-view.submit" : "ui.gallery-composer-scene.submit"]
        submit.assertDisabled("待确认的发布应等待用户核对。")
        tap("community.publication.review-content")
        assertUI(app.navigationBars["搜索"].appears(timeout: 5), "核对入口应直接打开原生搜索。")
        assertUI(app.textFields.firstMatch.value as? String == title, "核对应带入待确认发布的标题。")
        tap(paper ? "ui.paper-search-scene.cancel" : "ui.gallery-search-view.cancel")
        reveal(app.textFields["标题"], description: "返回核对后的标题", searchFromTop: true)
        assertUI(app.textFields["标题"].value as? String == title, "返回核对后应保留当前编辑内容。")
        let review = app.buttons["community.publication.review"]
        reveal(review, description: "核对发布结果")
        review.tapBriefly()
        assertUI(review.disappears(timeout: 5), "确认后应结束待核对状态。")
        reveal(submit, description: "核对后的发布入口", searchFromTop: true)
        assertUI(waitUntil(NSPredicate(format: "enabled == true"), on: submit, timeout: 5), "用户确认后应允许再次发布。")
        submit.tapBriefly()
        assertUI(textElement(title).appears(timeout: 5), "确认后的发布应更新列表。")
    }

    @MainActor
    func testDamagedPaperDraftStorageRecoversAndKeepsCurrentInput() {
        app = configureApp(resetStorage: true, content: true, paperDraftRecovery: true, initialTab: "gallery")
        tapHeader(app.sectionTab("文章"))
        tap("发布文章")
        assertUI(app.alerts["恢复文章草稿存储？"].appears(timeout: 5), "损坏的文章草稿应提供确认恢复入口。")
        tap("paper.draft.recovery.cancel")
        for (title, text) in [("标题", "恢复中的文章"), ("简介", "保留简介"), ("正文", "保留当前正文")] {
            replaceText(text, in: app.textFields[title])
        }
        dismissKeyboard()
        tap("paper.draft.recovery")
        tap("paper.draft.recovery.confirm")
        assertUI(app.buttons["ui.paper-composer-view.save-draft"].appears(timeout: 5), "恢复后应继续提供暂存。")
        assertUI(app.textFields["标题"].value as? String == "恢复中的文章", "恢复存储应保留当前输入。")
        tap("暂存")
        tap("发布文章")
        assertUI(app.alerts["恢复文章草稿？"].appears(timeout: 5), "重建后的文章存储应支持再次恢复。")
        tap("恢复草稿")
        assertUI(app.textFields["正文"].value as? String == "保留当前正文", "重新进入后应恢复暂存正文。")
        tap("取消")
        tap("放弃修改")
    }

    @MainActor
    func testGallerySettingsValidationTogglesAndPersistence() {
        app = configureApp(resetStorage: true)
        openSettings("gallery")
        let values = ["隐藏机器人帖子", "隐藏匿名内容", "使用网页话廊"].map { ($0, toggle($0)) }
        let ids = app.textFields["屏蔽用户 UID（逗号分隔）"]
        ids.tapBriefly()
        ids.typeText("abc\n")
        assertUI(app.alerts["UID 格式错误"].appears(timeout: 5), "无效 UID 应给出校验提示。")
        closeAlertIfPresent()
        replaceTextWithKeyboard("12,34\n", in: ids)
        dismissKeyboard()
        app = configureApp(resetStorage: false, restartProcess: true, initialSettings: "gallery")
        assertUI(app.textFields["屏蔽用户 UID（逗号分隔）"].value as? String == "12,34", "重新装载应保留屏蔽 UID。")
        for (title, value) in values {
            assertUI(app.switches.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.value as? String == value,
                     "重新装载应保留开关状态：\(title)。")
        }
    }

    @MainActor
    func testAboutLicenseUpdateAndResetConfirmation() {
        app = configureApp(resetStorage: true)
        openSettings("about")
        tap("开源声明")
        assertUI(app.navigationBars["开源声明"].appears(timeout: 5), "开源声明应打开正文。")
        app.swipeUp()
        back()
        assertUI(app.navigationBars["关于"].appears(timeout: 5), "开源声明返回后应恢复关于页。")
        toggle("自动检查更新")
        tap("检查更新")
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "离线更新检查应给出结果提示。")
        closeAlertIfPresent()
        tap("删除所有文稿与数据")
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "重置应要求确认。")
        app.alerts.buttons["取消"].tapBriefly()
        assertUI(app.mainTab("我的").exists, "取消重置应保留当前会话。")
    }




    @MainActor
    func testGalleryComposerTagsSettingsPublishAndDelete() {
        app = configureApp(resetStorage: true, content: true, animations: true, initialTab: "gallery")
        tap("发布话题")
        tap("发布")
        assertUI(app.alerts["发布失败"].appears(timeout: 5), "空话题应展示必填验证。")
        closeAlertIfPresent()
        replaceText("测试草稿", in: app.textFields["标题"])
        dismissKeyboard()
        swipeSheetHeader(app.navigationBars["发布帖子"])
        assertUI(app.textFields["标题"].value as? String == "测试草稿", "下拉关闭应保留草稿输入并等待明确关闭操作。")
        XCUIDevice.shared.press(.home)
        app.activate()
        assertUI(app.textFields["标题"].value as? String == "测试草稿", "返回前台应保留编辑中的草稿。")
        tap("取消")
        tap("保存草稿")
        tap("发布话题")
        tap("加载草稿")
        assertUI(app.textFields["标题"].value as? String == "测试草稿", "重新打开应恢复保存的草稿。")
        tap("活动")
        tap("聊天")
        tap("自定义")
        replaceText("临时标签", in: app.textFields["自定义标签"])
        dismissKeyboard()
        tap("删除标签")
        assertUI(!app.textFields["自定义标签"].exists, "删除应移除自定义标签输入行。")
        toggle("匿名发布")
        toggle("公开显示")
        toggle("公开显示")
        replaceText("测试发布的话题", in: app.textFields["标题"])
        replaceText("测试发布正文", in: app.textFields["正文"])
        dismissKeyboard()
        tap("发布")
        let poster = textElement("测试发布的话题")
        assertUI(poster.appears(timeout: 5), "发布应更新话廊列表。")
        poster.tapBriefly()
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "刚发布的话题应打开详情。")
        tap("更多操作")
        tap("删除帖子")
        app.alerts.buttons["取消"].tapBriefly()
        assertUI(app.navigationBars["帖子详情"].exists, "取消删除应保留详情。")
        tap("更多操作")
        tap("删除帖子")
        app.alerts.buttons["删除"].tapBriefly()
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: poster, timeout: 5), "删除应移除刚发布的话题。")
        tap("发布话题")
        replaceText("待丢弃草稿", in: app.textFields["标题"])
        dismissKeyboard()
        tap("取消")
        tap("保存草稿")
        tap("发布话题")
        tap("不加载")
        assertUI(app.textFields["标题"].value as? String != "待丢弃草稿", "放弃恢复应保留空编辑器。")
        tap("取消")
        app = configureApp(resetStorage: true, content: true, animations: true, claimsFailureOnce: true, initialTab: "gallery")
        tap("发布话题")
        let retry = app.buttons["gallery.editor.retry-claims"]
        assertUI(retry.appears(timeout: 5), "声明加载失败应在编辑页提供重试。")
        tap("重新加载声明")
        assertUI(retry.disappears(timeout: 5), "重试成功应收起声明错误状态。")
        assertUI(textElement("日常").appears(timeout: 5), "重试应载入服务端声明选项。")
        tap("取消")
        tap("不保存")
    }


    @MainActor
    func testPaperPublishEditCommentAndDelete() {
        app = configureApp(resetStorage: true, content: true, animations: true, paperEditConflictOnce: true, initialTab: "gallery")
        tapHeader(app.sectionTab("文章"))
        tap("发布文章")
        let paperComposer = app.navigationBars["发布文章"]
        tap("发布")
        assertUI(app.alerts["发布失败"].appears(timeout: 5), "空文章应提示必填字段。")
        closeAlertIfPresent()
        toggle("匿名发布")
        for (title, text) in [("标题", "测试发布文章"), ("简介", "文章发布测试简介"), ("正文", "文章发布测试正文")] {
            replaceText(text, in: app.textFields[title])
        }
        dismissKeyboard()
        swipeSheetHeader(paperComposer)
        assertUI(paperComposer.exists, "下滑关闭应保留文章编辑内容。")
        assertUI(app.textFields["正文"].value as? String == "文章发布测试正文", "文章正文应继续保留。")
        tap("取消")
        tap("暂存并离开")
        assertUI(paperComposer.disappears(timeout: 5), "暂存完成后应返回文章列表。")
        tap("发布文章")
        assertUI(app.alerts["恢复文章草稿？"].appears(timeout: 5), "重新进入应提供所属账号的文章草稿。")
        tap("继续当前编辑")
        assertUI(app.textFields["标题"].value as? String != "测试发布文章", "当前编辑应保留新建文章状态。")
        tap("取消")
        tap("发布文章")
        assertUI(app.alerts["恢复文章草稿？"].appears(timeout: 5), "继续当前编辑后，暂存草稿应保持可恢复。")
        tap("恢复草稿")
        tap("暂存")
        assertUI(paperComposer.disappears(timeout: 5), "工具栏暂存应保存恢复后的文章。")
        tap("发布文章")
        assertUI(app.alerts["恢复文章草稿？"].appears(timeout: 5), "工具栏保存的草稿应支持恢复。")
        tap("恢复草稿")
        assertUI(app.textFields["标题"].value as? String == "测试发布文章", "恢复后应保留文章标题。")
        assertUI(app.textFields["正文"].value as? String == "文章发布测试正文", "恢复后应保留文章正文。")
        tap("paper.drafts.manage")
        assertUI(app.navigationBars["文章草稿"].appears(timeout: 5), "草稿管理应展示当前账号的文章草稿。")
        checkScrollContainers()
        tap("删除草稿")
        dismissSystemPopover(UIElement(app.native.sheets.firstMatch))
        assertUI(app.buttons["paper.drafts.delete"].exists, "取消删除应保留文章草稿。")
        tap("paper.drafts.delete")
        UIElement(app.native.sheets.buttons["删除草稿"]).tapBriefly()
        assertUI(textElement("暂无文章草稿").appears(timeout: 5), "确认删除后应更新草稿列表。")
        tap("完成")
        reveal(app.textFields["标题"], description: "草稿管理后的标题", searchFromTop: true)
        assertUI(app.textFields["标题"].value as? String == "测试发布文章", "草稿管理应保留当前编辑输入。")
        tap("发布")
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: paperComposer, timeout: 5), "文章发布后应关闭编辑窗口。")
        let paper = textElement("测试发布文章")
        assertUI(paper.appears(timeout: 5), "发布应更新文章列表。")
        paper.tapBriefly()
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5), "刚发布的文章应打开详情。")
        tap("评论文章")
        let commentComposer = app.navigationBars["发表评论"]
        assertUI(commentComposer.appears(timeout: 5), "评论入口应打开输入窗口。")
        replaceText("测试文章评论", in: app.textFields.firstMatch)
        dismissKeyboard()
        tap("发布")
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: commentComposer, timeout: 5), "评论提交后应关闭输入窗口。")
        reveal(textElement("测试文章评论"), description: "测试文章评论")
        assertUI(textElement("测试文章评论").exists, "提交应更新文章评论。")
        tap("更多操作")
        app.buttons["paper.detail.edit"].tapBriefly()
        let editor = app.navigationBars["编辑文章"]
        assertUI(editor.appears(timeout: 5), "文章菜单应打开编辑器。")
        assertUI(app.textFields["标题"].value as? String == "测试发布文章", "编辑应恢复文章标题。")
        assertUI(app.textFields["简介"].value as? String == "文章发布测试简介", "编辑应恢复文章简介。")
        assertUI(app.textFields["正文"].value as? String == "文章发布测试正文", "编辑应恢复详情页已解析的正文。")
        replaceText("测试修改文章", in: app.textFields["标题"])
        dismissKeyboard()
        tap("保存")
        assertUI(app.alerts["文章已有更新"].appears(timeout: 5), "版本冲突应保留编辑内容并提示核对。")
        closeAlertIfPresent()
        tap("paper.edit.review-latest")
        assertUI(textElement("远端更新的文章").appears(timeout: 5), "核对入口应展示最新文章。")
        back()
        reveal(app.textFields["标题"], description: "核对更新后的标题", searchFromTop: true)
        assertUI(app.textFields["标题"].value as? String == "测试修改文章", "查看最新文章后应保留本地标题。")
        tap("paper.edit.confirm-version")
        let save = app.buttons["ui.paper-composer-view.submit"]
        reveal(save, description: "确认版本后的保存入口", searchFromTop: true)
        save.tapBriefly()
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: editor, timeout: 5), "保存文章应返回详情。")
        assertUI(textElement("测试修改文章").appears(timeout: 5), "保存应更新文章详情。")
        assertUI(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "文章发布测试正文")).firstMatch.native.exists,
                 "修改标题应保留完整正文。")
        tap("更多操作")
        app.buttons["paper.detail.edit"].tapBriefly()
        assertUI(editor.appears(timeout: 5), "已保存文章应支持再次编辑。")
        replaceText("取消的文章修改", in: app.textFields["标题"])
        dismissKeyboard()
        let edge = app.native.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.01, thenDragTo: app.native.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        assertUI(editor.exists && app.textFields["标题"].value as? String == "取消的文章修改", "边缘返回应保留待确认的文章修改。")
        tap("取消")
        dismissSystemPopover(UIElement(app.native.sheets.firstMatch))
        assertUI(app.textFields["标题"].value as? String == "取消的文章修改", "继续编辑应保留当前输入。")
        tap("取消")
        tap("放弃修改")
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: editor, timeout: 5), "取消编辑应返回文章详情。")
        assertUI(textElement("测试修改文章").exists, "取消应保留已保存的文章标题。")
        tap("更多操作")
        tap("删除文章")
        app.alerts.buttons["取消"].tapBriefly()
        tap("更多操作")
        tap("删除文章")
        app.alerts.buttons["删除"].tapBriefly()
        assertUI(app.buttons["发布文章"].appears(timeout: 5), "删除应返回文章列表。")
        let article = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@", "测试修改文章", "测试发布文章"
        )).firstMatch
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: article, timeout: 5), "文章列表应移除删除的文章。")
    }

    @MainActor
    func testSuggestionDraftRestoreAndDiscard() {
        app = configureApp(resetStorage: true, animations: true, nativeInteraction: true)
        openSettings("suggestion")
        let text = app.textFields["建议内容"]
        assertUI(text.appears(timeout: 5), "建议页应展示内容字段。")
        app.buttons["提交"].assertDisabled("空建议应禁用提交。")
        replaceText("自动化测试建议", in: text)
        dismissKeyboard()
        let contact = app.textFields["联系方式"]
        replaceText("测试联系信息", in: contact)
        dismissKeyboard()
        swipeSheetHeader(app.navigationBars["向开发者提建议"])
        assertUI(text.value as? String == "自动化测试建议", "下滑关闭应保留建议内容并等待保存选择。")
        tap("取消")
        tap("保存草稿")
        openSettings("suggestion")
        tap("加载草稿")
        assertUI(app.textFields["建议内容"].value as? String == "自动化测试建议", "建议草稿应恢复正文。")
        assertUI(app.textFields["联系方式"].value as? String == "测试联系信息", "建议草稿应恢复联系信息。")
        tap("取消")
        tap("不保存")
    }

}
