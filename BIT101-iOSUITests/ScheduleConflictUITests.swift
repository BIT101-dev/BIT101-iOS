import XCTest

final class ScheduleConflictUITests: UIAutomationTestCase {
    @MainActor
    func testDamagedRootRebuildRequiresConfirmation() {
        app = configureApp(
            resetStorage: true, scheduleRootDamage: true, initialSettings: "calendar")
        let nameRow = app.buttons["schedule.settings.primary-name"]
        let rebuild = app.buttons["schedule.recovery.rebuild"]
        assertUI(rebuild.appears(timeout: 5) && !nameRow.isEnabled, "损坏的根文件应提供所属日程域的确认重建入口。")
        let cloudSync = app.switches["iCloud 多端同步"]
        reveal(cloudSync)
        cloudSync.assertDisabled("日程恢复确认期间，同步开关应沿共享写入资格置灰。")
        let preferenceSync = app.switches["同步设置与使用偏好（实验性）"]
        reveal(preferenceSync)
        assertUI(preferenceSync.isEnabled, "独立偏好同步应保留操作能力。")
        reveal(rebuild)
        rebuild.tapBriefly()
        tap("schedule.recovery.rebuild.cancel")
        assertUI(rebuild.exists && !nameRow.isEnabled, "取消确认后应保留原文件与读取状态。")
        rebuild.tapBriefly()
        tap("schedule.recovery.rebuild.confirm")
        assertUI(rebuild.disappears(timeout: 5) && nameRow.isEnabled, "确认重建后应恢复日程编辑。")
        reveal(cloudSync)
        assertUI(cloudSync.isEnabled, "重建完成后同步开关应恢复操作。")
        reveal(nameRow)
        nameRow.tapBriefly()
        replaceText("重建课表", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("确定")
        app = configureApp(resetStorage: false, restartProcess: true, initialSettings: "calendar")
        let saved = app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "schedule.settings.primary-name", "重建课表")
        ).firstMatch
        assertUI(saved.appears(timeout: 5), "冷启动应恢复重建后的编辑。")
    }

    @MainActor
    func testDdlSettingsResume() {
        app = configureApp(resetStorage: true, scheduleRecovery: true, initialSettings: "ddl")
        let before = app.buttons["ui.ddl-settings-page.before-day"]
        let after = app.buttons["ui.ddl-settings-page.after-day"]
        let confirm = app.buttons["schedule.recovery.confirm"]
        assertUI(
            confirm.appears(timeout: 5) && !before.isEnabled && !after.isEnabled,
            "DDL 显示设置应等待日程恢复确认。")
        app.buttons["ddl.refresh"].assertDisabled("恢复确认前应保留学校日程。")
        tap("schedule.recovery.retry")
        assertUI(confirm.appears(timeout: 5) && !before.isEnabled, "读取重试应沿用恢复状态。")
        confirm.tapBriefly()
        assertUI(
            confirm.disappears(timeout: 5) && before.isEnabled && after.isEnabled, "确认后应恢复 DDL 设置。")
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
    func testRecoveredScheduleRequiresConfirmation() {
        app = configureApp(resetStorage: true, scheduleRecovery: true, initialSettings: "calendar")
        let nameRow = app.buttons["schedule.settings.primary-name"]
        let retry = app.buttons["schedule.recovery.retry"]
        let confirm = app.buttons["schedule.recovery.confirm"]
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
        let saved = app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "schedule.settings.primary-name", "确认课表")
        ).firstMatch
        assertUI(saved.appears(timeout: 5), "冷启动应恢复确认后的编辑。")
        assertUI(!app.buttons["schedule.recovery.confirm"].exists, "已保存的日程应直接进入常规编辑状态。")
    }

    @MainActor
    func resolveConflict(keepingLocal: Bool) {
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
        let selectedName = app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "schedule.settings.primary-name", title)
        ).firstMatch
        assertUI(selectedName.appears(timeout: 5), "课表名称应采用所选冲突版本。")
        app = configureApp(resetStorage: false, restartProcess: true, initialSettings: "calendar")
        assertUI(selectedName.appears(timeout: 5), "冷启动应恢复已保存版本。")
    }
}

nonisolated final class LandscapeLayoutUITests: UIAutomationTestCase {
    var navigationWidth: CGFloat?
    var sidebarWidth: CGFloat?
    var navigationBackground: [Int]?
    @MainActor
    @objc func testGallerySurfaceChangesNavigation() {
        if UIDevice.current.userInterfaceIdiom != .phone {
            XCUIDevice.shared.orient(to: .portrait)
        }
        app = configureApp(resetStorage: true, content: true, initialTab: "gallery")
        for surface in ["话题", "文章", "话题", "文章"] {
            app.native.segmentedControls.buttons[surface].press(forDuration: 0.01)
            assertCompactNavigation(requiresSections: true)
            let search = surface == "话题" ? "搜索话廊" : "搜索文章"
            assertUI(app.native.buttons[search].isHittable, "切换内容应保留当前页面的操作入口。")
        }
        captureBrowserScreenshot("话廊顶部间距")
    }
    @MainActor
    @objc func testCompactWindowKeepsSystemBars() {
        if UIDevice.current.userInterfaceIdiom != .phone {
            XCUIDevice.shared.orient(to: .portrait)
        }
        app = configureApp(
            resetStorage: true, content: true, animations: true, school: true, initialTab: "home")
        checkCompactWindowBounds()
        app.mainTab("日程").tapBriefly()
        let headerFrame = app.native.segmentedControls.firstMatch.frame
        for section in ["课表", "DDL", "空教室"] {
            tapHeader(app.sectionTab(section))
            assertRefreshBelowSectionTabs(referenceHeader: headerFrame)
        }
        app.buttons["classroom.section-filter"].tapBriefly()
        let navigation = app.navigationBars["节次筛选"]
        assertUI(navigation.appears(timeout: 5), "竖屏节次筛选应沿整页导航打开。")
        let section = app.buttons["ui.app-multi-selection-list.item.1"]
        section.tapBriefly()
        back()
        assertUI(
            navigation.disappears(timeout: 5) && app.buttons["classroom.section-filter"].exists,
            "竖屏筛选返回应恢复空教室查询页。")
        assertRefreshBelowSectionTabs()
    }
    @MainActor
    @objc func testWindowChangesKeepInsets() throws {
        XCUIDevice.shared.orient(to: .landscapeLeft)
        defer { XCUIDevice.shared.orient(to: .portrait) }
        app = configureApp(
            resetStorage: true, content: true, animations: true, school: true, initialTab: "home")
        try XCTSkipIf((windowTraits()["divisionX"] ?? -1) < 0, "连续切换验收使用系统提供分隔区域的窗口。")
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    let frame = self.app.windows.firstMatch.frame
                    return frame.width > frame.height
                }, on: app, timeout: 10), "连续切换验收从宽幅窗口开始。")
        print("Layout phase: close")
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    let frame = self.app.windows.firstMatch.frame
                    return frame.height > frame.width
                }, on: app, timeout: 60), "连续切换验收应进入紧凑窗口。")
        checkCompactWindowBounds()
        app.mainTab("成绩").tapBriefly()
        print("Layout phase: open")
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    let frame = self.app.windows.firstMatch.frame
                    return frame.width > frame.height
                }, on: app, timeout: 60), "连续切换验收应恢复宽幅窗口。")
        let master = app.descendants(matching: .any)["browser.master"]
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    let divider = self.windowTraits()["divisionX"] ?? -1
                    return divider > 0 && master.exists
                        && abs(master.frame.maxX - CGFloat(divider)) <= 1
                }, on: app, timeout: 5), "恢复宽幅窗口后，浏览列表应沿系统分隔区域排列：\(master.frame)。")
        recordLayoutScreenshot("展开恢复")
    }
    @MainActor func checkCompactWindowBounds() {
        let traits = windowTraits()
        let window = app.windows.firstMatch.frame
        let available = app.windows.firstMatch.scrollGestureFrame(in: window) ?? window
        let master = app.native.descendants(matching: .any)["browser.master"]
        print("Window geometry: \(traits), available=\(available), master=\(master.frame)")
        recordLayoutScreenshot("紧凑窗口边界")
        guard traits["idiom"] == UIUserInterfaceIdiom.phone.rawValue,
            min(window.width, window.height) < 640
        else { return }
        assertUI(
            traits["orientation"] == UIInterfaceOrientation.portrait.rawValue,
            "紧凑手机窗口应采用竖屏方向：\(traits)。")
        let tabs = ["日程", "地图", "话廊", "成绩", "我的"].map { app.mainTab($0).native.frame }
        let bar = tabs.reduce(CGRect.null) { $0.union($1) }
        assertUI(window.contains(bar), "系统主导航应位于当前窗口内：\(bar)，窗口 \(window)。")
        if available.maxX < window.maxX {
            assertUI(bar.minX >= available.maxX, "系统侧栏应位于正文可用区域之外：\(bar)，正文 \(available)。")
        }
        for row in master.cells.allElementsBoundByIndex where available.intersects(row.frame) {
            assertUI(
                row.frame.minX >= available.minX && row.frame.maxX <= available.maxX,
                "紧凑窗口的分组行应完整位于可用区域：\(row.frame)，可用区域 \(available)。")
        }
        if traits["safeTop"] == 0 && available.width < window.width {
            let header = app.native.segmentedControls.firstMatch
            assertUI(header.exists && header.frame.minY >= 16, "顶部自定义分区栏应保留标准间距：\(header.frame)。")
        }
        app.mainTab("日程").tapBriefly()
        let add = app.buttons["schedule.add-content"]
        assertUI(add.appears(timeout: 5), "紧凑窗口应展示课表操作。")
        print("Schedule geometry: button=\(add.frame), available=\(available)")
        let hasBottomBar = bar.width > bar.height && bar.minY > window.midY
        let contentBottom = hasBottomBar ? bar.minY : window.maxY
        let grid = app.descendants(matching: .any)["schedule.calendar"]
        print("Portrait spacing: grid=\(grid.frame), contentBottom=\(contentBottom)")
        let gap = contentBottom - grid.frame.maxY
        assertUI(
            (hasBottomBar ? gap >= 8 : abs(gap) <= 1) && add.frame.maxY <= grid.frame.maxY - 19,
            "竖屏课表与悬浮操作应保留底部间距：课表 \(grid.frame)，按钮 \(add.frame)，正文底部 \(contentBottom)。")
        recordLayoutScreenshot("紧凑课表底部")
    }

    @MainActor @objc func testLandscapeDetailBackUseRightPanePane() throws {
        let rotates = UIDevice.current.userInterfaceIdiom != .phone
        if rotates { XCUIDevice.shared.orient(to: .landscapeLeft) }
        defer { if rotates { XCUIDevice.shared.orient(to: .portrait) } }
        app = configureApp(
            resetStorage: true, content: true, animations: true, school: true, initialTab: "home")
        try requireLandscapeSupport()
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    let window = self.app.windows.firstMatch.frame
                    return window.width > window.height
                }, on: app, timeout: 10), "右侧导航验收使用横屏窗口。")
        let window = app.windows.firstMatch.frame
        let available = app.windows.firstMatch.scrollGestureFrame(in: window) ?? window
        app.buttons["ui.score-list-page.排序"].tapBriefly()
        let scoreNavigation = app.native.navigationBars["成绩排序"]
        let backButton = app.buttons["app.pane.back"]
        let scoreMaster = app.descendants(matching: .any)["browser.master"]
        assertUI(
            scoreNavigation.waitForExistence(timeout: 5) && backButton.exists
                && backButton.frame.minX >= scoreMaster.frame.maxX
                && scoreNavigation.frame.contains(backButton.frame)
                && backButton.frame.maxX <= scoreNavigation.frame.minX + 88,
            "横屏详情返回键应位于右栏左上侧：\(backButton.frame)，左栏 \(scoreMaster.frame)。")
        assertPaneContentWidth(
            "browser.detail", left: scoreMaster.frame.maxX, right: available.maxX)
        backButton.tapBriefly()
        assertUI(
            scoreNavigation.disappears(timeout: 5) && textElement("选择一项成绩").exists,
            "右栏返回应恢复详情占位并保留左侧列表。")
        app.mainTab("空教室").tapBriefly()
        let sidebar = app.descendants(matching: .any)["browser.master"]
        let campus = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "校区"))
            .firstMatch
        let tabs = ["日程", "空教室", "地图", "话廊", "文章", "成绩", "课程", "我的"]
            .map { app.mainTab($0).native.frame }.reduce(CGRect.null) { $0.union($1) }
        if tabs.width > tabs.height {
            let stamp = app.native.staticTexts["app.refresh-status.timestamp"]
            assertUI(
                stamp.exists && stamp.frame.minY >= tabs.maxY,
                "空教室刷新行应位于系统主导航下方：\(stamp.frame)，主导航 \(tabs)。")
        }
        app.buttons["classroom.section-filter"].tapBriefly()
        let filterNavigation = app.native.navigationBars["节次筛选"]
        let firstSection = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1节"))
            .firstMatch
        assertUI(
            filterNavigation.waitForExistence(timeout: 5) && firstSection.appears(timeout: 5)
                && sidebar.exists && campus.exists && firstSection.frame.minX >= sidebar.frame.maxX,
            "节次筛选应在右栏打开，并保留左侧查询条件。")
        let row = app.native.cells.containing(.button, identifier: firstSection.identifier)
            .firstMatch
        assertUI(
            row.exists && abs(row.frame.maxX - (available.maxX - 8)) <= 1,
            "右栏节次分组应完整位于系统侧栏左侧：\(row.frame)，正文 \(available)。")
        assertPaneContentWidth("browser.detail", left: sidebar.frame.maxX, right: available.maxX)
        if available.maxX < window.maxX {
            let sidebarBackground = backgroundColor(
                at: CGPoint(x: sidebar.frame.minX + 2, y: available.maxY - 2))
            let railBackground = backgroundColor(at: CGPoint(x: window.maxX - 2, y: available.midY))
            assertUI(
                zip(sidebarBackground, railBackground).allSatisfy { abs($0 - $1) <= 2 },
                "右栏导航周围应沿页面分组底色呈现：\(railBackground)，页面 \(sidebarBackground)。")
        }
        assertUI(
            backButton.frame.minX >= sidebar.frame.maxX
                && filterNavigation.frame.contains(backButton.frame)
                && backButton.frame.maxX <= filterNavigation.frame.minX + 88,
            "节次筛选返回键应位于右栏左上侧：\(backButton.frame)。")
        let previous = firstSection.value as? String
        firstSection.tapBriefly()
        let changed = NSPredicate { _, _ in firstSection.value as? String != previous }
        assertUI(
            waitUntil(changed, on: firstSection),
            "右栏节次选择应更新筛选状态。")
        recordLayoutScreenshot("右栏节次筛选")
        backButton.tapBriefly()
        assertUI(
            filterNavigation.disappears(timeout: 5)
                && app.descendants(matching: .any)["interaction.FreeClassroomTabView.list"].exists,
            "返回后应展示同一查询的空教室结果。")
        if UIDevice.current.userInterfaceIdiom != .phone {
            app.buttons["classroom.section-filter"].tapBriefly()
            XCUIDevice.shared.orient(to: .portrait)
            assertUI(
                filterNavigation.disappears(timeout: 5)
                    && app.buttons["classroom.section-filter"].exists,
                "横屏筛选转入竖屏应恢复空教室查询页。")
            app.buttons["classroom.section-filter"].tapBriefly()
            assertUI(filterNavigation.waitForExistence(timeout: 5), "竖屏应打开同一节次筛选。")
            XCUIDevice.shared.orient(to: .landscapeLeft)
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in
                        sidebar.exists && filterNavigation.exists
                            && filterNavigation.frame.minX >= sidebar.frame.maxX
                    }, on: app, timeout: 5), "竖屏筛选转入横屏应沿公共导航移至右栏。")
            assertPaneContentWidth(
                "browser.detail", left: sidebar.frame.maxX, right: available.maxX)
            backButton.tapBriefly()
        }
    }

    @MainActor
    func assertCommunityTab(
        _ tab: String,
        isPhone: Bool,
        safeArea: CGRect,
        assertBottom: (UIElement) -> Void,
        recordScreenshot: (String) -> Void
    ) {
        let buttonTitle = tab == "话廊" ? "搜索话廊" : "搜索文章"
        assertBottom(app.buttons[buttonTitle])
        if isPhone {
            let header = app.native.segmentedControls.firstMatch
            assertUI(
                header.exists && header.frame.minY >= safeArea.minY + 16 - 0.5,
                "Duo 顶部控件应保留标准安全间距：\(header.frame)，安全区 \(safeArea)。")
        }
        let screenshotTitle = tab == "话廊" ? "话题列表" : "文章列表"
        recordScreenshot(screenshotTitle)
    }
    @MainActor func assertPaneContentWidth(
        _ identifier: String, left: CGFloat, right: CGFloat
    ) {
        let pane = app.native.descendants(matching: .any)[identifier]
        let viewport = scrollingContent(in: pane)
        assertUI(viewport.exists, "分栏应提供实际列表或滚动区域：\(identifier)。")
        if viewport.elementType == .collectionView {
            let row = viewport.cells.firstMatch
            assertUI(row.exists, "分组列表宽度验收需要实际显示的行。")
            let frame = row.frame
            assertUI(
                abs(frame.minX - (left + 8)) <= 1 && abs(frame.maxX - (right - 8)) <= 1,
                "分组行应填满所属栏标准边距内的宽度：\(identifier)，\(frame)，分栏 \(left)...\(right)。")
        } else {
            let column = CGRect(
                x: left, y: pane.frame.minY, width: right - left, height: pane.frame.height)
            let visible = viewport.frame.intersection(column)
            assertUI(
                abs(visible.minX - left) <= 1 && abs(visible.maxX - right) <= 1,
                "滚动区应铺满所属栏：\(identifier)，\(visible)，分栏 \(left)...\(right)。")
        }
    }
    @MainActor func scrollingContent(in pane: XCUIElement) -> XCUIElement {
        if [.scrollView, .collectionView].contains(pane.elementType) { return pane }
        let list = pane.collectionViews.firstMatch
        return list.exists ? list : pane.scrollViews.firstMatch
    }

    @MainActor func checkPortraitRoundTrip(detailTitle: String, reopen: () -> Void) {
        guard windowTraits()["idiom"] != UIUserInterfaceIdiom.phone.rawValue else { return }
        XCUIDevice.shared.orient(to: .portrait)
        assertPortraitBrowser(detailTitle: detailTitle)
        reopen()
        assertUI(app.navigationBars[detailTitle].appears(timeout: 5), "竖屏浏览列表应继续打开所属详情。")
        assertPortraitDetailWidth()
        XCUIDevice.shared.orient(to: .landscapeLeft)
    }
    @MainActor func assertPortraitBrowser(detailTitle: String) {
        let master = app.native.descendants(matching: .any)["browser.master"]
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    let window = self.app.native.windows.firstMatch.frame
                    return window.height > window.width && master.exists
                        && master.frame.width >= window.width * 0.95
                        && !self.app.native.navigationBars[detailTitle].exists
                }, on: app, timeout: 10), "竖屏应回到全宽浏览列表。")
        assertCompactNavigation(requiresSections: true)
    }
    @MainActor func assertPortraitDetailWidth() {
        let pane = app.native.descendants(matching: .any)["browser.detail"]
        let window = app.native.windows.firstMatch.frame
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    let content =
                        [.collectionView, .scrollView].contains(pane.elementType)
                        ? pane
                        : (pane.scrollViews.firstMatch.exists
                            ? pane.scrollViews.firstMatch : pane.collectionViews.firstMatch)
                    return content.exists && content.frame.width >= window.width * 0.95
                }, on: app),
            "竖屏详情应使用完整可用宽度。")
        assertCompactNavigation()
    }
    @MainActor func assertCompactNavigation(requiresSections: Bool = false) {
        let tabs = ["日程", "地图", "话廊", "成绩", "我的"].map { app.mainTab($0).native.frame }
        let frame = tabs.reduce(CGRect.null) { $0.union($1) }
        let controls = app.native.segmentedControls.allElementsBoundByIndex.filter(\.isHittable)
        if requiresSections { assertUI(!controls.isEmpty, "浏览列表应展示可操作的分区栏。") }
        for control in controls {
            assertUI(!control.frame.intersects(frame), "页面分区栏应与系统主导航分别布局。")
        }
        if frame.midY < app.native.windows.firstMatch.frame.midY,
            let first = controls.min(by: { $0.frame.minY < $1.frame.minY })
        {
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in
                        let navigation = ["日程", "地图", "话廊", "成绩", "我的"].map {
                            self.app.mainTab($0).native.frame
                        }
                        .reduce(CGRect.null) { $0.union($1) }
                        let gap = first.frame.minY - navigation.maxY
                        return gap >= 0 && gap <= first.frame.height
                    }, on: app), "顶部导航与分区栏应沿内容间距排列：分区栏 \(first.frame)，主导航 \(frame)。")
        }
    }
    @MainActor func checkAcademicBrowsers() {
        app.mainTab("成绩").native.press(forDuration: 0.01)
        assertUI(
            app.native.buttons["score.query"].waitForExistence(timeout: 5)
                && app.native.buttons["score.query"].isHittable, "成绩入口应呈现可操作的成绩页面。")
        assertPanes("browser.master", "browser.detail")
        assertUI(app.native.buttons["score.query"].exists, "成绩浏览器应保留系统可访问的逐行操作。")
        let empty = UIElement(
            app.native.cells.containing(.staticText, identifier: "暂无成绩").firstMatch)
        assertUI(empty.exists, "首次成绩查询前应展示公共空态行，供背景验收。")
        let initialRefresh = UIElement(
            app.native.cells.containing(.button, identifier: "score.query").firstMatch)
        let initialBackground = backgroundColor(
            at: CGPoint(x: initialRefresh.frame.minX + 4, y: initialRefresh.frame.midY))
        reveal(empty, description: "成绩空态")
        assertPlainRow(empty.native, matches: initialBackground)
        reveal(initialRefresh, description: "成绩刷新")
        app.buttons["score.query"].tapBriefly()
        let code = app.textFields["verification.code"]
        assertUI(code.appears(timeout: 5), "成绩查询应打开所属验证流程。")
        fillVerificationCode("123456", in: code)
        assertUI(textElement("加权平均分、92.00").appears(timeout: 5), "横屏成绩应展示已加载记录的统计。")
        assertUI(app.navigationBars["短信验证"].disappears(timeout: 5), "成绩截图应在验证面板完全收起后采样。")
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    UITestControlClient.request(["command": "keyboard-state"]) == "hidden"
                }, on: app, timeout: 5), "短信验证结束后应释放键盘焦点。")
        capture("成绩")
        let refresh = app.native.cells.containing(.button, identifier: "score.query").firstMatch
        let groupedBackground = backgroundColor(
            at: CGPoint(x: refresh.frame.minX + 4, y: refresh.frame.midY))
        let statistics = app.native.cells.containing(
            NSPredicate(format: "label BEGINSWITH %@", "参与加权")
        ).firstMatch
        assertPlainRow(statistics, matches: groupedBackground)
        let score = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "ui.score-list-page.score.")
        ).firstMatch
        reveal(score, description: "成绩记录")
        score.tapBriefly()
        assertUI(app.navigationBars["成绩详情"].appears(timeout: 5), "成绩详情应在右侧打开。")
        assertDetailWidth()
        let selected = app.native.cells.containing(.button, identifier: score.native.identifier)
            .firstMatch
        let edge = backgroundColor(at: CGPoint(x: selected.frame.minX + 1, y: selected.frame.midY))
        let fill = backgroundColor(at: CGPoint(x: selected.frame.minX + 6, y: selected.frame.midY))
        assertUI(zip(edge, fill).allSatisfy { abs($0 - $1) <= 20 }, "成绩选中态应使用浅色背景。")
        capture("成绩详情")
        app.mainTab("课程").tapBriefly()
        assertPanes("browser.master", "browser.detail")
        let search = app.native.cells.containing(.textField, identifier: "在这里搜索课程哦").firstMatch
        assertPlainRow(search, matches: groupedBackground)
        let course = app.buttons["ui.course-page-content.course"]
        assertUI(course.appears(timeout: 5), "课程列表应加载可选记录。")
        course.tapBriefly()
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "课程详情应在右侧打开。")
        assertDetailWidth()
        capture("课程详情")
        app.mainTab("成绩").tapBriefly()
        assertUI(app.navigationBars["成绩详情"].appears(timeout: 5), "切换主入口应保留成绩详情。")
    }
    @MainActor func assertPanes(_ sidebarID: String, _ contentID: String) {
        let sidebar = app.descendants(matching: .any)[sidebarID]
        let content = app.descendants(matching: .any)[contentID]
        let placeholder = app.staticTexts["从左侧列表选择内容"]
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    guard sidebar.exists && content.exists else { return false }
                    let contentX =
                        contentID == "browser.detail" ? placeholder.frame.minX : content.frame.minX
                    return sidebar.frame.maxX <= contentX + 1
                }, on: app), "横屏应并排呈现侧栏和主体：\(sidebarID)。")
    }
    @MainActor func assertDetailWidth() {
        let pane = app.native.descendants(matching: .any)["browser.detail"]
        let sidebar = app.descendants(matching: .any)["browser.master"]
        let window = app.windows.firstMatch.frame
        let available = app.windows.firstMatch.scrollGestureFrame(in: window) ?? window
        let detailFrame = CGRect(
            x: sidebar.frame.maxX, y: window.minY,
            width: available.maxX - sidebar.frame.maxX, height: window.height)
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    let viewport = self.scrollingContent(in: pane)
                    return viewport.exists
                        && viewport.frame.intersection(detailFrame).width >= detailFrame.width - 9
                }, on: app),
            "右侧详情应使用所属分栏的主要宽度。")
        assertPaneContentWidth("browser.detail", left: detailFrame.minX, right: detailFrame.maxX)
        let list = pane.elementType == .collectionView ? pane : pane.collectionViews.firstMatch
        if list.exists {
            let cell = list.cells.firstMatch
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in
                        cell.exists && cell.frame.minX >= sidebar.frame.maxX
                            && cell.frame.maxX <= window.maxX
                    }, on: app), "详情分组应完整位于所属分栏内，保留两侧圆角。")
        }
        if list.exists { list.swipeUp() } else { pane.scrollViews.firstMatch.swipeUp() }
        guard windowTraits()["idiom"] != UIUserInterfaceIdiom.phone.rawValue else { return }
        let bar = app.native.navigationBars.firstMatch
        assertUI(bar.exists, "宽屏详情应保留原生标题栏。")
        let occupied =
            (bar.buttons.allElementsBoundByIndex + bar.staticTexts.allElementsBoundByIndex)
            .map(\.frame).filter { $0.intersects(bar.frame) }.sorted { $0.minX < $1.minX }
        var gaps: [CGRect] = []
        var cursor = bar.frame.minX
        for frame in occupied {
            if frame.minX > cursor {
                gaps.append(
                    CGRect(
                        x: cursor, y: bar.frame.minY, width: frame.minX - cursor,
                        height: bar.frame.height))
            }
            cursor = max(cursor, frame.maxX)
        }
        if cursor < bar.frame.maxX {
            gaps.append(
                CGRect(
                    x: cursor, y: bar.frame.minY, width: bar.frame.maxX - cursor,
                    height: bar.frame.height))
        }
        guard let gap = gaps.max(by: { $0.width < $1.width }) else {
            XCTFail("导航背景取样需要按钮和标题之外的可见区域。")
            return
        }
        let backdrop = backgroundColor(at: CGPoint(x: gap.midX, y: gap.midY))
        guard let grouped = navigationBackground else {
            XCTFail("标题栏验收需要先采样公共主导航背景。")
            return
        }
        let usesGroupedBackground = zip(backdrop, grouped).allSatisfy { abs($0 - $1) <= 2 }
        if !usesGroupedBackground {
            let attachment = XCTAttachment(screenshot: layoutScreenshot())
            attachment.name = "界面截图·详情导航背景"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        assertUI(
            usesGroupedBackground,
            "宽屏标题栏应以公共背景遮蔽滚动内容：\(backdrop)，参考 \(grouped)。")
    }
    @MainActor func capture(_ title: String) {
        if title == "话题列表" || title == "文章列表" {
            let labels = title == "话题列表" ? ["我的收藏", "消息", "发布话题", "搜索话廊"] : ["发布文章", "搜索文章"]
            let buttons = labels.map { app.native.buttons[$0].frame }
            assertUI(
                zip(buttons, buttons.dropFirst()).allSatisfy {
                    abs($0.minX - $1.minX) <= 1 && $0.maxY <= $1.minY
                },
                "浏览操作应竖向悬浮排列。")
            let master = app.native.descendants(matching: .any)["browser.master"]
            let scroll = master.elementType == .scrollView ? master : master.scrollViews.firstMatch
            assertUI(
                scroll.exists && scroll.frame.maxY >= buttons[labels.count - 1].maxY,
                "浏览列表应延伸至悬浮按钮后方。")
        }
        assertUI(
            app.native.descendants(matching: .any)["app.navigation.adaptive"].exists,
            "主导航应由系统 TabView 承载。")
        let navigation = ["日程", "空教室", "地图", "话廊", "文章", "成绩", "课程", "我的"].map { app.mainTab($0) }
        assertUI(navigation.allSatisfy { $0.exists }, "原生主导航应呈现八个入口。")
        if navigation.allSatisfy({ $0.exists }) {
            let frame = navigation.reduce(CGRect.null) { $0.union($1.frame) }
            assertUI(app.native.windows.firstMatch.frame.contains(frame), "原生导航应位于窗口内。")
            if frame.width > frame.height {
                assertUI(
                    abs(frame.midX - app.native.windows.firstMatch.frame.midX) <= 1, "横向主导航应位于窗口中央。"
                )
                if title != "地图" { assertNavigationBackground(frame) }
            } else if navigationBackground == nil {
                let detail = app.native.descendants(matching: .any)["browser.detail"]
                navigationBackground = backgroundColor(
                    at: CGPoint(x: detail.frame.midX, y: frame.minY / 2))
            }
            if let navigationWidth {
                assertUI(abs(frame.width - navigationWidth) <= 1, "页面切换应保持主导航宽度。")
            } else {
                navigationWidth = frame.width
            }
            for status in app.native.staticTexts.matching(
                identifier: "app.refresh-status.timestamp"
            ).allElementsBoundByIndex {
                if app.native.windows.firstMatch.frame.intersects(status.frame) {
                    assertUI(!frame.intersects(status.frame), "刷新信息应位于主导航之外：\(status.frame)。")
                }
            }
            let refresh = NSPredicate(
                format: "identifier IN %@", ["app.refresh-status.action", "score.query"])
            for cell in app.native.cells.containing(refresh).allElementsBoundByIndex {
                assertUI(abs(cell.frame.height - 52) <= 1, "模块刷新行应沿公共行高布局：\(cell.frame)。")
            }
        }
        if title == "个人页" {
            let master = app.native.descendants(matching: .any)["browser.master"]
            let list =
                master.elementType == .collectionView ? master : master.collectionViews.firstMatch
            let tabs = navigation.reduce(CGRect.null) { $0.union($1.frame) }
            let first = list.cells.firstMatch.frame
            assertUI(
                tabs.width > tabs.height ? first.minY >= tabs.maxY : first.maxX <= tabs.minX,
                "个人页一级列表应沿原生导航的可用区域布局，保留顶部内容。")
            for identifier in ["account", "calendar", "ddl", "gallery", "suggestion", "about"] {
                let entry = app.buttons["settings.route.\(identifier)"]
                assertUI(
                    entry.exists && entry.frame.maxX <= master.frame.maxX,
                    "个人页一级入口应统一位于左侧列表：\(identifier)。")
            }
        }
        for identifier in ["browser.master"] {
            let sidebar = app.native.descendants(matching: .any)[identifier]
            if sidebar.exists && sidebar.frame.width > 0 {
                if let sidebarWidth {
                    assertUI(
                        abs(sidebar.frame.width - sidebarWidth) <= 1,
                        "同一窗口各页面应共享侧栏宽度：\(sidebar.frame.width)，参考 \(sidebarWidth)。")
                } else {
                    sidebarWidth = sidebar.frame.width
                }
            }
        }
        recordLayoutScreenshot(title)
    }

    @MainActor func recordLayoutScreenshot(_ title: String) {
        let attachment = XCTAttachment(screenshot: layoutScreenshot())
        attachment.name = "界面截图·\(title)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func assertPlainRow(_ row: XCUIElement, matches expected: [Int]) {
        assertUI(row.exists, "分组背景验收需要实际列表行。")
        guard row.exists else { return }
        for x in [row.frame.minX + 4, row.frame.maxX - 4] {
            let color = backgroundColor(at: CGPoint(x: x, y: row.frame.midY))
            assertUI(
                zip(color, expected).allSatisfy { abs($0 - $1) <= 2 },
                "公共列表行应沿完整行宽呈现分组背景：\(color)，参考 \(expected)，行 \(row.frame)。")
        }
    }
    @MainActor func assertNavigationBackground(_ navigation: CGRect) {
        let color = backgroundColor(at: CGPoint(x: 12, y: navigation.midY))
        if let navigationBackground {
            assertUI(
                zip(color, navigationBackground).allSatisfy { abs($0 - $1) <= 2 },
                "页面切换应保持主导航周围的公共背景：\(color)，参考 \(navigationBackground)。")
        } else {
            navigationBackground = color
        }
    }
    @MainActor func backgroundColor(at point: CGPoint) -> [Int] {
        let window = app.windows.firstMatch.frame
        let screenshot = layoutScreenshot().image
        let rendered = UIGraphicsImageRenderer(size: window.size).image { _ in
            screenshot.draw(in: CGRect(origin: .zero, size: window.size))
        }
        guard let image = rendered.cgImage else {
            XCTFail("背景验收需要实际截图。")
            return []
        }
        let scale = CGFloat(image.width) / window.width
        let region = CGRect(
            x: (point.x - window.minX) * scale, y: (point.y - window.minY) * scale,
            width: 2 * scale, height: 2 * scale
        ).integral
        guard let sample = image.cropping(to: region) else {
            XCTFail("背景采样点应位于窗口内。")
            return []
        }
        var pixels = [UInt8](repeating: 0, count: sample.width * sample.height * 4)
        let color = pixels.withUnsafeMutableBytes { bytes -> [Int] in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: sample.width, height: sample.height,
                    bitsPerComponent: 8, bytesPerRow: sample.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                XCTFail("导航背景验收应创建像素绘制上下文。")
                return []
            }
            context.draw(sample, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
            return (0..<3).map { channel in
                stride(from: channel, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }
                    / (sample.width * sample.height)
            }
        }
        return color
    }

    @MainActor func layoutScreenshot() -> XCUIScreenshot {
        let screenshots = XCUIScreen.screens.map { $0.screenshot() }
        var selected = screenshots[0]
        var hasContent = false
        for screenshot in screenshots {
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            pixels.withUnsafeMutableBytes { bytes in
                if let context = CGContext(
                    data: bytes.baseAddress, width: 32, height: 32,
                    bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                    let image = screenshot.image.cgImage
                {
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
                }
            }
            hasContent = stride(from: 0, to: pixels.count, by: 4).contains {
                pixels[$0] > 0 || pixels[$0 + 1] > 0 || pixels[$0 + 2] > 0
            }
            if hasContent {
                selected = screenshot
                break
            }
        }
        assertUI(hasContent, "布局截图应包含活跃屏幕的可见内容，活跃屏幕数 \(screenshots.count)。")
        return selected
    }

}
