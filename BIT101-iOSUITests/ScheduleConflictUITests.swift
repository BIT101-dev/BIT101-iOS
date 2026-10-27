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
    private var sidebarWidth: CGFloat?
    private var navigationBackground: [Int]?
    @MainActor
    @objc func testClassroomSMSUsesTheCurrentNativeDestination() {
        app = configureApp(resetStorage: true, animations: true, school: true, classroomSMS: true)
        tapHeader(app.sectionTab("空教室"))
        assertUI(app.navigationBars["短信验证"].appears(timeout: 5), "空教室认证应由当前可见页面呈现。")
        assertUI(app.buttons["验证并继续"].exists, "短信验证应继续所属学校请求。")
        fillVerificationCode("123456", in: app.textFields["verification.code"])
        assertUI(app.navigationBars["短信验证"].disappears(timeout: 10), "验证完成应关闭短信面板。")
        assertUI(textElement("已验证A101").appears(timeout: 10), "验证完成应重新查询空教室。")
        assertUI(app.sectionTab("空教室").native.isSelected, "空教室查询应保留当前分区。")
    }
    @MainActor
    @objc func testCurrentWindowUsesAdaptivePanesAndReadableCards() {
        app = configureApp(resetStorage: true, ddlFixture: "sources", content: true, school: true, pagination: true, initialTab: "mine")
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
        func showPortrait() {
            XCUIDevice.shared.orientation = .portrait
            assertUI(waitUntil(NSPredicate { _, _ in
                let window = self.app.native.windows.firstMatch.frame
                return window.height > window.width
            }, on: app, timeout: 10), "首次旋转检查应从实际竖屏窗口开始。")
        }
        if traits["idiom"] != UIUserInterfaceIdiom.phone.rawValue {
            showPortrait()
            app.mainTab("话廊").tapBriefly()
            func checkFirstRotation(firstID: String, title: String) {
                let first = app.descendants(matching: .any)[firstID]
                assertUI(first.appears(timeout: 5), "竖屏应显示浏览列表。")
                XCUIDevice.shared.orientation = .landscapeLeft
                let sort = app.native.segmentedControls.containing(.button, identifier: "最新").firstMatch
                assertUI(waitUntil(NSPredicate { _, _ in
                    let window = self.app.native.windows.firstMatch.frame
                    return window.width > window.height && sort.exists && first.exists && first.frame.width < window.width / 2
                        && first.frame.minY >= sort.frame.maxY - 1
                        && first.frame.minY - sort.frame.maxY <= sort.frame.height
                }, on: app, timeout: 10), "首次旋转应让列表贴近顶部排序栏。")
                capture(title)
            }
            checkFirstRotation(firstID: "community.poster.card.1", title: "首次旋转话题")
            showPortrait()
            tapHeader(app.sectionTab("文章"))
            checkFirstRotation(firstID: "paper.summary.1", title: "首次旋转文章")
        }
        app.mainTab("我的").tapBriefly()
        assertUI(waitUntil(NSPredicate { _, _ in
            let window = self.app.native.windows.firstMatch.frame
            return window.width > window.height
        }, on: app, timeout: 10), "横屏专项应在实际横屏窗口运行；Duo 姿态由 Device Hub 设置。")
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
        checkAcademicBrowsers()
        app.mainTab("日程").tapBriefly()
        let calendarWeek = app.buttons["第1周"]
        assertUI(calendarWeek.appears(timeout: 5) && calendarWeek.isHittable, "横屏应完整展示课表周次。")
        assertUI(app.buttons["添加待办"].isHittable, "课表与单列 DDL 应同时提供入口。")
        let surface = app.descendants(matching: .any)["schedule.section-surface"]
        let window = app.windows.firstMatch
        if let safeArea = window.scrollGestureFrame(in: window.frame) {
            assertUI(waitUntil(NSPredicate { _, _ in surface.frame.maxY >= safeArea.maxY - 1 }, on: app, timeout: 5),
                "日程应填满窗口安全区：内容 \(surface.frame)，安全区 \(safeArea)，键盘 \(UITestControlClient.request(["command": "keyboard-state"]) ?? "未知")。")
        }
        let grid = app.descendants(matching: .any)["schedule.calendar"]
        assertUI(waitUntil(NSPredicate { _, _ in grid.exists && grid.frame.maxY >= surface.frame.maxY - 17 }, on: app),
            "课表网格应延伸至模块底部的标准间距：网格 \(grid.frame)，模块 \(surface.frame)。")
        capture("课表与DDL")
        tapHeader(app.sectionTab("空教室"))
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
        app.mainTab("话廊").tapBriefly()
        assertUI(first.appears(timeout: 5), "详情验收应在话题列表中选择内容。")
        first.tapBriefly()
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5) && first.exists, "话题详情应在右侧打开并保留左侧列表。")
        assertDetailWidth()
        capture("话题详情")
        XCUIDevice.shared.orientation = .portrait
        assertUI(app.navigationBars["帖子详情"].appears(timeout: 5), "竖屏应保留当前帖子详情。")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertUI(first.appears(timeout: 5) && app.navigationBars["帖子详情"].exists, "返回横屏应保留阅读位置与详情。")
        tapHeader(app.sectionTab("文章"))
        let paper = textElement("分页文章 1"), nextPaper = textElement("分页文章 2")
        assertUI(waitUntil(NSPredicate { _, _ in
            paper.exists && nextPaper.exists && paper.frame.maxY <= nextPaper.frame.minY
        }, on: app), "横屏文章应沿左侧单列排列。")
        capture("文章列表")
        paper.tapBriefly()
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5) && paper.exists, "文章详情应在右侧打开并保留左侧列表。")
        assertDetailWidth()
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
    @MainActor
    @objc func testAcademicBrowsersKeepTheSharedChrome() {
        app = configureApp(resetStorage: true, content: true, animations: true, school: true, initialTab: "home")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        assertUI(waitUntil(NSPredicate { _, _ in
            let window = self.app.windows.firstMatch.frame
            return window.width > window.height
        }, on: app, timeout: 10), "分栏验收使用实际横屏窗口。")
        checkAcademicBrowsers()
        for (tab, title) in [("日程", "课表与DDL"), ("话廊", "话题列表"), ("文章", "文章列表")] {
            app.mainTab(tab).tapBriefly()
            capture(title)
        }
    }
    @MainActor private func checkAcademicBrowsers() {
        app.mainTab("成绩").tapBriefly()
        assertPanes("browser.master", "browser.detail")
        assertUI(app.native.buttons["score.query"].exists, "成绩浏览器应保留系统可访问的逐行操作。")
        app.buttons["score.query"].tapBriefly()
        let code = app.textFields["verification.code"]
        assertUI(code.appears(timeout: 5), "成绩查询应打开所属验证流程。")
        fillVerificationCode("123456", in: code)
        assertUI(textElement("加权平均分、92.00").appears(timeout: 5), "横屏成绩应展示已加载记录的统计。")
        assertUI(app.navigationBars["短信验证"].disappears(timeout: 5), "成绩截图应在验证面板完全收起后采样。")
        assertUI(waitUntil(NSPredicate { _, _ in
            UITestControlClient.request(["command": "keyboard-state"]) == "hidden"
        }, on: app, timeout: 5), "短信验证结束后应释放键盘焦点。")
        capture("成绩")
        let score = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ui.score-list-page.score.")).firstMatch
        reveal(score, description: "成绩记录")
        score.tapBriefly()
        assertUI(app.navigationBars["成绩详情"].appears(timeout: 5), "成绩详情应在右侧打开。")
        assertDetailWidth()
        capture("成绩详情")
        app.mainTab("课程").tapBriefly()
        assertPanes("browser.master", "browser.detail")
        let course = app.buttons["ui.course-page-content.course"]
        assertUI(course.appears(timeout: 5), "课程列表应加载可选记录。")
        course.tapBriefly()
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "课程详情应在右侧打开。")
        assertDetailWidth()
        capture("课程详情")
        app.mainTab("成绩").tapBriefly()
        assertUI(app.navigationBars["成绩详情"].appears(timeout: 5), "切换主入口应保留成绩详情。")
    }
    @MainActor private func assertPanes(_ sidebarID: String, _ contentID: String) {
        let sidebar = app.descendants(matching: .any)[sidebarID]
        let content = app.descendants(matching: .any)[contentID]
        let placeholder = app.staticTexts["从左侧列表选择内容"]
        assertUI(waitUntil(NSPredicate { _, _ in
            guard sidebar.exists && content.exists else { return false }
            let contentX = contentID == "browser.detail" ? placeholder.frame.minX : content.frame.minX
            return sidebar.frame.maxX <= contentX + 1
        }, on: app), "横屏应并排呈现侧栏和主体：\(sidebarID)。")
    }
    @MainActor private func assertDetailWidth() {
        let pane = app.native.descendants(matching: .any)["browser.detail"]
        let sidebar = app.descendants(matching: .any)["browser.master"]
        let window = app.windows.firstMatch.frame
        let detailFrame = CGRect(x: sidebar.frame.maxX, y: window.minY,
            width: window.maxX - sidebar.frame.maxX, height: window.height)
        assertUI(waitUntil(NSPredicate { _, _ in
            let scroll = pane.scrollViews.firstMatch
            let list = pane.collectionViews.firstMatch
            let viewport = [.scrollView, .collectionView].contains(pane.elementType) ? pane : (scroll.exists ? scroll : list)
            return viewport.exists && viewport.frame.intersection(detailFrame).width >= detailFrame.width * 0.9
        }, on: app),
            "右侧详情应使用所属分栏的主要宽度。")
        let list = pane.elementType == .collectionView ? pane : pane.collectionViews.firstMatch
        if list.exists {
            let cell = list.cells.firstMatch
            assertUI(waitUntil(NSPredicate { _, _ in
                cell.exists && cell.frame.minX >= sidebar.frame.maxX && cell.frame.maxX <= window.maxX
            }, on: app), "详情分组应完整位于所属分栏内，保留两侧圆角。")
        }
    }
    @MainActor private func capture(_ title: String) {
        assertUI(app.native.descendants(matching: .any)["app.navigation.adaptive"].exists, "主导航应由系统 TabView 承载。")
        let navigation = ["日程", "空教室", "地图", "话廊", "文章", "成绩", "课程", "我的"].map { app.mainTab($0) }
        assertUI(navigation.allSatisfy { $0.exists }, "原生主导航应呈现八个入口。")
        if navigation.allSatisfy({ $0.exists }) {
            let frame = navigation.reduce(CGRect.null) { $0.union($1.frame) }
            assertUI(app.native.windows.firstMatch.frame.contains(frame), "原生导航应位于窗口内。")
            if frame.width > frame.height {
                assertUI(abs(frame.midX - app.native.windows.firstMatch.frame.midX) <= 1, "横向主导航应位于窗口中央。")
                if title != "地图" { assertNavigationBackground(frame) }
            }
            if let navigationWidth { assertUI(abs(frame.width - navigationWidth) <= 1, "页面切换应保持主导航宽度。") }
            else { navigationWidth = frame.width }
            for status in app.native.staticTexts.matching(identifier: "app.refresh-status.timestamp").allElementsBoundByIndex {
                if app.native.windows.firstMatch.frame.intersects(status.frame) {
                    assertUI(!frame.intersects(status.frame), "刷新信息应位于主导航之外：\(status.frame)。")
                }
            }
            let refresh = NSPredicate(format: "identifier IN %@", ["app.refresh-status.action", "score.query"])
            for cell in app.native.cells.containing(refresh).allElementsBoundByIndex {
                assertUI(abs(cell.frame.height - 52) <= 1, "模块刷新行应沿公共行高布局：\(cell.frame)。")
            }
        }
        for identifier in ["mine.sidebar", "classroom.sidebar", "browser.master"] {
            let sidebar = app.native.descendants(matching: .any)[identifier]
            if sidebar.exists && sidebar.frame.width > 0 {
                if let sidebarWidth { assertUI(abs(sidebar.frame.width - sidebarWidth) <= 1,
                    "同一窗口各页面应共享侧栏宽度：\(sidebar.frame.width)，参考 \(sidebarWidth)。") }
                else { sidebarWidth = sidebar.frame.width }
            }
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "界面截图·\(title)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func assertNavigationBackground(_ navigation: CGRect) {
        let window = app.windows.firstMatch.frame
        let screenshot = app.screenshot().image
        let rendered = UIGraphicsImageRenderer(size: window.size).image { _ in
            screenshot.draw(in: CGRect(origin: .zero, size: window.size))
        }
        guard let image = rendered.cgImage else { XCTFail("导航背景验收需要实际截图。"); return }
        let scale = CGFloat(image.width) / window.width
        let region = CGRect(x: 12 * scale, y: (navigation.midY - window.minY) * scale,
                            width: 4 * scale, height: 4 * scale).integral
        guard let sample = image.cropping(to: region) else { XCTFail("导航背景采样点应位于窗口内。"); return }
        var pixels = [UInt8](repeating: 0, count: sample.width * sample.height * 4)
        let color = pixels.withUnsafeMutableBytes { bytes -> [Int] in
            guard let context = CGContext(data: bytes.baseAddress, width: sample.width, height: sample.height,
                bitsPerComponent: 8, bytesPerRow: sample.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                XCTFail("导航背景验收应创建像素绘制上下文。"); return []
            }
            context.draw(sample, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
            return (0..<3).map { channel in
                stride(from: channel, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) } / (sample.width * sample.height)
            }
        }
        if let navigationBackground { assertUI(zip(color, navigationBackground).allSatisfy { abs($0 - $1) <= 2 },
            "页面切换应保持主导航周围的公共背景：\(color)，参考 \(navigationBackground)。") }
        else { navigationBackground = color }
    }

}
