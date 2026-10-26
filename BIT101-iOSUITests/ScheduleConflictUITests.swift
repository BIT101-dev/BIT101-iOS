import XCTest

final class ScheduleConflictUITests: UIAutomationTestCase {
    @MainActor
    func testDamagedRootRebuildRequiresConfirmationAndRestoresEditing() {
        app = configureApp(resetStorage: true, scheduleRootDamage: true, initialSettings: "calendar")
        let nameRow = app.buttons["schedule.settings.primary-name"]
        let rebuild = app.buttons["schedule.recovery.rebuild"]
        assertUI(rebuild.appears(timeout: 5) && !nameRow.isEnabled, "损坏的根文件应提供所属日程域的确认重建入口。")
        rebuild.tapBriefly()
        tap("schedule.recovery.rebuild.cancel")
        assertUI(rebuild.exists && !nameRow.isEnabled, "取消确认后应保留原文件与读取状态。")
        rebuild.tapBriefly()
        tap("schedule.recovery.rebuild.confirm")
        assertUI(rebuild.disappears(timeout: 5) && nameRow.isEnabled, "确认重建后应恢复日程编辑。")
        reveal(nameRow)
        nameRow.tapBriefly()
        replaceText("重建课表", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("确定")
        app = configureApp(resetStorage: false, restartProcess: true, initialSettings: "calendar")
        let saved = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
            "schedule.settings.primary-name", "重建课表")).firstMatch
        assertUI(saved.appears(timeout: 5), "冷启动应恢复重建后的编辑。")
    }

    @MainActor
    func testDDLSettingsResumeAfterCacheRecoveryConfirmation() {
        app = configureApp(resetStorage: true, scheduleRecovery: true, initialSettings: "ddl")
        let before = app.buttons["ui.ddl-settings-page.before-day"]
        let after = app.buttons["ui.ddl-settings-page.after-day"]
        let confirm = app.buttons["schedule.recovery.confirm"]
        assertUI(confirm.appears(timeout: 5) && !before.isEnabled && !after.isEnabled,
                 "DDL 显示设置应等待日程恢复确认。")
        app.buttons["ddl.refresh"].assertDisabled("恢复确认前应保留学校日程。")
        tap("schedule.recovery.retry")
        assertUI(confirm.appears(timeout: 5) && !before.isEnabled, "读取重试应沿用恢复状态。")
        confirm.tapBriefly()
        assertUI(confirm.disappears(timeout: 5) && before.isEnabled && after.isEnabled, "确认后应恢复 DDL 设置。")
        before.tapBriefly()
        let wheel = app.pickerWheels.firstMatch
        assertUI(wheel.appears(timeout: 5), "恢复后的天数设置应继续使用系统滚轮。")
        wheel.adjust(toPickerWheelValue: "7 天")
        tap("完成")
        assertUI(wheel.disappears(timeout: 5), "保存后应关闭滚轮。")
        app = configureApp(resetStorage: false, restartProcess: true, initialSettings: "ddl")
        tap("变色天数")
        assertUI(app.pickerWheels.firstMatch.value as? String == "7 天", "冷启动应恢复已确认的 DDL 设置。")
        tap("取消")
    }

    @MainActor
    func testKeepLocalConflictContentPersists() { resolveConflict(keepingLocal: true) }

    @MainActor
    func testUseSyncedConflictContentPersists() { resolveConflict(keepingLocal: false) }

    @MainActor
    func testRecoveredScheduleRequiresConfirmationAndPersistsSubsequentEdits() {
        app = configureApp(resetStorage: true, scheduleRecovery: true, initialSettings: "calendar")
        let nameRow = app.buttons["schedule.settings.primary-name"]
        let retry = app.buttons["schedule.recovery.retry"], confirm = app.buttons["schedule.recovery.confirm"]
        assertUI(confirm.appears(timeout: 5) && retry.exists, "恢复结果应提供核对、重试和确认入口。")
        assertUI(!nameRow.isEnabled, "确认恢复结果后继续编辑日程。")
        retry.tapBriefly()
        assertUI(confirm.appears(timeout: 5) && !nameRow.isEnabled, "重试读取应保留待确认的恢复结果。")
        confirm.tapBriefly()
        assertUI(confirm.disappears(timeout: 5) && nameRow.isEnabled, "确认成功后应恢复编辑。")
        reveal(nameRow)
        nameRow.tapBriefly()
        replaceText("确认课表", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("确定")
        app = configureApp(resetStorage: false, restartProcess: true, initialSettings: "calendar")
        let saved = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
            "schedule.settings.primary-name", "确认课表")).firstMatch
        assertUI(saved.appears(timeout: 5), "冷启动应恢复确认后的编辑。")
        assertUI(!app.buttons["schedule.recovery.confirm"].exists, "已保存的日程应直接进入常规编辑状态。")
    }

    @MainActor
    private func resolveConflict(keepingLocal: Bool) {
        app = configureApp(resetStorage: true, scheduleConflict: true, initialSettings: "calendar")
        let nameRow = app.buttons["schedule.settings.primary-name"]
        reveal(nameRow)
        nameRow.tapBriefly()
        replaceText("本机标题", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("确定")
        let local = app.buttons["schedule.conflict.keep-local"]
        let synced = app.buttons["schedule.conflict.use-cloud"]
        assertUI(local.appears(timeout: 5) && synced.exists, "版本分歧应展示两种明确选择。")
        assertUI(!nameRow.isEnabled, "版本冲突期间课表编辑应等待版本选择。")
        back()
        openSettings("ddl")
        let before = app.buttons["ui.ddl-settings-page.before-day"]
        assertUI(local.appears(timeout: 5) && !before.isEnabled, "DDL 设置应共享日程版本选择。")
        app.buttons["ui.ddl-settings-page.after-day"].assertDisabled("版本选择完成后可调整滞留天数。")
        let choice = keepingLocal ? local : synced
        reveal(choice)
        choice.tapBriefly()
        assertUI(local.disappears(timeout: 5), "版本选择应完成保存并关闭提示。")
        assertUI(before.isEnabled, "版本选择应恢复 DDL 显示设置。")
        back()
        openSettings("calendar")
        assertUI(nameRow.isEnabled, "版本选择保存后应恢复编辑。")
        let title = keepingLocal ? "本机标题" : "同步标题"
        let selectedName = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
            "schedule.settings.primary-name", title)).firstMatch
        assertUI(selectedName.appears(timeout: 5), "课表名称应采用所选冲突版本。")
        app = configureApp(resetStorage: false, restartProcess: true, initialSettings: "calendar")
        assertUI(selectedName.appears(timeout: 5), "冷启动应恢复已保存版本。")
    }
}

nonisolated final class LandscapeLayoutUITests: UIAutomationTestCase {
    private var navigationWidth: CGFloat?
    @MainActor
    @objc func testCurrentWindowUsesAdaptivePanesAndReadableCards() {
        app = configureApp(resetStorage: true, content: true, school: true, pagination: true, initialTab: "mine")
        let traits = windowTraits()
        let isCompactPhone = traits["idiom"] == UIUserInterfaceIdiom.phone.rawValue
            && traits["horizontal"] == UIUserInterfaceSizeClass.compact.rawValue
        if isCompactPhone {
            assertUI(app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width, "紧凑手机采用竖屏布局。")
            assertUI(!app.collectionViews["mine.sidebar"].exists, "竖向窗口应合并资料与设置入口。")
            assertUI(app.mainTab("我的").isHittable, "竖向窗口保留主导航。")
            return
        }
        defer { XCUIDevice.shared.orientation = .portrait }
        app.mainTab("话廊").tapBriefly()
        func checkFirstRotation(firstID: String, title: String) {
            let first = app.descendants(matching: .any)[firstID]
            assertUI(first.appears(timeout: 5), "竖屏应显示浏览列表。")
            XCUIDevice.shared.orientation = .landscapeLeft
            let sort = app.native.segmentedControls.containing(.button, identifier: "最新").firstMatch
            assertUI(waitUntil(NSPredicate { _, _ in
                let window = self.app.native.windows.firstMatch.frame
                return window.width > window.height && sort.exists && first.exists
                    && first.frame.minY >= sort.frame.maxY - 1
                    && first.frame.minY - sort.frame.maxY <= sort.frame.height
            }, on: app, timeout: 10), "首次旋转应让列表贴近顶部排序栏。")
            capture(title)
        }
        checkFirstRotation(firstID: "community.poster.card.1", title: "首次旋转话题")
        XCUIDevice.shared.orientation = .portrait
        tapHeader(app.segmentedControls.buttons["文章"])
        checkFirstRotation(firstID: "paper.summary.1", title: "首次旋转文章")
        app.mainTab("我的").tapBriefly()
        assertUI(waitUntil(NSPredicate { _, _ in
            let window = self.app.native.windows.firstMatch.frame
            return window.width > window.height
        }, on: app, timeout: 10), "横屏专项应在实际横屏窗口运行；Duo 姿态由 Device Hub 设置。")
        func assertPanes(_ sidebarID: String, _ contentID: String) {
            let sidebar = app.descendants(matching: .any)[sidebarID]
            let content = app.descendants(matching: .any)[contentID]
            assertUI(waitUntil(NSPredicate { _, _ in
                sidebar.exists && content.exists && sidebar.frame.maxX <= content.frame.minX + 1
            }, on: app), "横屏应并排呈现侧栏和主体：\(sidebarID)。")
        }
        assertPanes("mine.sidebar", "interaction.MineRootViewScene.list")
        capture("个人页")
        openSettings("account")
        tap("昵称")
        let input = app.textFields.firstMatch
        replaceText("横屏编辑草稿", in: input)
        dismissKeyboard()
        assertUI(input.value as? String == "横屏编辑草稿", "横屏编辑与键盘收起保留完整草稿。")
        tap("取消")
        back()
        app.mainTab("成绩").tapBriefly()
        assertPanes("home.score-surface", "home.course-surface")
        capture("成绩")
        app.mainTab("日程").tapBriefly()
        let calendarWeek = app.buttons["第1周"]
        assertUI(calendarWeek.appears(timeout: 5) && calendarWeek.isHittable, "横屏应完整展示课表周次。")
        assertUI(app.buttons["添加待办"].isHittable, "课表与单列 DDL 应同时提供入口。")
        capture("课表与DDL")
        tapHeader(app.segmentedControls.buttons["空教室"])
        assertPanes("classroom.sidebar", "interaction.FreeClassroomTabView.list")
        capture("空教室")
        app.mainTab("话廊").tapBriefly()
        tapHeader(app.segmentedControls.buttons["最新"])
        let first = app.descendants(matching: .any)["community.poster.card.1"]
        let second = app.descendants(matching: .any)["community.poster.card.2"]
        assertUI(waitUntil(NSPredicate { _, _ in
            first.exists && second.exists && first.frame.maxY <= second.frame.minY
        }, on: app), "横屏话题应沿左侧单列排列。")
        capture("话题列表")
        let more = app.descendants(matching: .any)["ui.community-poster-action-menu.menu"]
        assertUI(more.frame.width >= 44 - 0.5 && more.frame.height >= 44 - 0.5, "帖子菜单应提供完整点击区域：\(more.frame)。")
        more.tapBriefly()
        assertUI(app.buttons["举报帖子"].appears(timeout: 5), "帖子菜单应响应原生触摸。")
        app.mainTab("话廊").tapBriefly()
        assertUI(app.buttons["举报帖子"].disappears(timeout: 5), "点按导航应关闭帖子菜单。")
        first.tapBriefly()
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5) && first.exists, "话题详情应在右侧打开并保留左侧列表。")
        capture("话题详情")
        XCUIDevice.shared.orientation = .portrait
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "竖屏应保留当前帖子详情。")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertUI(first.appears(timeout: 5) && app.navigationBars["帖子详情"].exists, "返回横屏应保留阅读位置与详情。")
        tapHeader(app.segmentedControls.buttons["文章"])
        let paper = textElement("分页文章 1"), nextPaper = textElement("分页文章 2")
        assertUI(waitUntil(NSPredicate { _, _ in
            paper.exists && nextPaper.exists && paper.frame.maxY <= nextPaper.frame.minY
        }, on: app), "横屏文章应沿左侧单列排列。")
        capture("文章列表")
        paper.tapBriefly()
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5) && paper.exists, "文章详情应在右侧打开并保留左侧列表。")
        capture("文章详情")
        app.mainTab("地图").tapBriefly()
        let layer = app.buttons["切换地图图层"]
        assertUI(layer.appears(timeout: 5) && app.windows.firstMatch.frame.contains(layer.frame), "横屏地图应完整显示图层工具。")
        layer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapBriefly()
        waitForValue("卫星图", of: layer)
        capture("地图")
        app = configureApp(resetStorage: true, accessibilityTextSize: true, content: true, school: true, initialTab: "mine")
        assertUI(textElement("自动化测试用户").appears(timeout: 5), "大字号窗口保留资料内容。")
        assertUI(!app.collectionViews["mine.sidebar"].exists, "辅助功能字号采用完整宽度的单列内容。")
        app.mainTab("日程").tapBriefly()
        let week = app.buttons["第1周"]
        assertUI(week.appears(timeout: 5) && week.frame.width >= 44 && week.frame.height >= 44, "大字号周次刻度保留完整点击区域。")
        let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1周，周一，")).firstMatch
        assertUI(day.appears(timeout: 5) && day.frame.height >= 44, "大字号日期入口保留完整点击高度。")
    }
    @MainActor private func capture(_ title: String) {
        let navigation = app.native.segmentedControls.containing(.button, identifier: "地图").firstMatch
        if navigation.exists {
            let frame = navigation.frame
            assertUI(abs(frame.midX - app.native.windows.firstMatch.frame.midX) <= 1, "主导航应始终位于窗口中央。")
            if let navigationWidth { assertUI(abs(frame.width - navigationWidth) <= 1, "页面切换应保持主导航宽度。") }
            else { navigationWidth = frame.width }
            for cell in app.native.cells.containing(.button, identifier: "app.refresh-status.action").allElementsBoundByIndex {
                assertUI(abs(cell.frame.height - 52) <= 1, "模块刷新行应沿公共行高布局：\(cell.frame)。")
            }
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "界面截图·\(title)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
