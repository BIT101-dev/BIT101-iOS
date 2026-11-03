import XCTest

extension LandscapeLayoutUITests {
    @MainActor @objc func testLandscapeEdgesAndColumnBoundaries() throws {
        let rotates = UIDevice.current.userInterfaceIdiom != .phone
        if rotates { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { if rotates { XCUIDevice.shared.orientation = .portrait } }
        for style in ["Light", "Dark"] {
            app = configureApp(
                resetStorage: true, userInterfaceStyle: style, ddlFixture: "sources", content: true,
                animations: true, school: true)
            try requireLandscapeSupport()
            let isPhone = windowTraits()["idiom"] == UIUserInterfaceIdiom.phone.rawValue
            for orientation: UIDeviceOrientation in rotates
                ? [.landscapeLeft, .landscapeRight] : [.unknown]
            {
                if rotates { XCUIDevice.shared.orientation = orientation }
                assertUI(
                    waitUntil(
                        NSPredicate { _, _ in
                            let frame = self.app.windows.firstMatch.frame
                            return frame.width > frame.height
                        }, on: app, timeout: 10), "边界验收应处于横屏窗口。")
                navigationWidth = nil
                sidebarWidth = nil
                navigationBackground = nil
                let window = app.windows.firstMatch
                guard let safeArea = window.scrollGestureFrame(in: window.frame) else { return }
                let expectedDivider =
                    isPhone ? window.frame.midX : safeArea.minX + safeArea.height * 9 / 16
                func assertDivider(_ identifier: String, trailingInset: CGFloat = 0) {
                    let pane = self.app.descendants(matching: .any)[identifier]
                    assertUI(
                        waitUntil(
                            NSPredicate { _, _ in
                                pane.exists
                                    && abs(pane.frame.maxX + trailingInset - expectedDivider) <= 1
                            }, on: app, timeout: 5),
                        """
                        分栏应沿当前设备的统一边界排列：\(identifier)，实际 \(pane.frame)，目标 \(expectedDivider)，内缩\
                         \(trailingInset)。
                        """
                    )
                }
                func assertBottom(_ button: UIElement) {
                    assertUI(
                        waitUntil(
                            NSPredicate { _, _ in
                                button.exists && abs(safeArea.maxY - button.frame.maxY) <= 8
                            }, on: app, timeout: 5),
                        """
                        横屏悬浮按钮应贴近底部安全区：\(button.frame)，安全区 \(safeArea)，键盘 \
                        \(controlDiagnostic("keyboard-state", fallback: "未知"))。
                        """
                    )
                }
                app.mainTab("日程").tapBriefly()
                let grid = app.descendants(matching: .any)["schedule.calendar"]
                assertUI(grid.exists, "横屏应展示学校课表网格。")
                let addFrame = app.buttons["schedule.add-content"].frame
                print(
                    """
                    Landscape geometry: traits=\(windowTraits()), window=\(window.frame), \
                    safe=\(safeArea), grid=\(grid.frame), button=\(addFrame)
                    """
                )
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                let background = UIColor.systemBackground.resolvedColor(
                    with: UITraitCollection(userInterfaceStyle: style == "Dark" ? .dark : .light))
                assertUI(
                    background.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
                    "网格底色应采用标准色空间。")
                let fill = [red, green, blue].map { Int(($0 * 255).rounded()) }
                let calendarWidth = isPhone ? window.frame.width / 2 : safeArea.width / 2
                let edge = backgroundColor(
                    at: CGPoint(
                        x: safeArea.minX + calendarWidth * 0.75,
                        y: window.frame.maxY - 2))
                assertUI(
                    zip(fill, edge).allSatisfy { abs($0 - $1) <= 2 },
                    "课表网格应铺满模块底部安全区：底边 \(edge)，网格底色 \(fill)，安全区 \(safeArea)。")
                let courseBackground = backgroundColor(
                    at: CGPoint(x: safeArea.minX + 2, y: safeArea.maxY - 2))
                let ddlBackground = backgroundColor(
                    at: CGPoint(x: safeArea.maxX - 2, y: safeArea.maxY - 2))
                assertUI(
                    zip(courseBackground, ddlBackground).allSatisfy { abs($0 - $1) <= 2 },
                    "课表与 DDL 模块周围应沿同一页面底色呈现：\(courseBackground)，\(ddlBackground)。")
                func assertTopBackground() {
                    let top = backgroundColor(
                        at: CGPoint(x: safeArea.minX + safeArea.width / 4, y: safeArea.minY + 2))
                    assertUI(
                        zip(top, courseBackground).allSatisfy { abs($0 - $1) <= 2 },
                        "顶部安全间距应沿用页面分组底色：\(top)，页面 \(courseBackground)。")
                }
                assertTopBackground()
                recordLayoutScreenshot("课表与DDL")
                if isPhone {
                    assertDivider("interaction.CourseScheduleTabView.refresh")
                    let refreshList = app.descendants(matching: .any)[
                        "interaction.CourseScheduleTabView.refresh"]
                    assertUI(
                        refreshList.frame.minY >= safeArea.minY + 16 - 0.5,
                        "Duo 课表顶部应保留标准安全间距：\(refreshList.frame)，安全区 \(safeArea)。")
                    let ddl = app.native.descendants(matching: .any)[
                        "interaction.DDLScheduleTabView.list"]
                    let row = ddl.cells.firstMatch
                    assertUI(
                        row.exists && abs(row.frame.maxX - (safeArea.maxX - 8)) <= 1,
                        "DDL 分组行应完整位于所属分栏：\(row.frame)，安全区 \(safeArea)。")
                    let corner = backgroundColor(
                        at: CGPoint(x: row.frame.minX + 1, y: row.frame.minY + 1))
                    let surrounding = backgroundColor(
                        at: CGPoint(x: safeArea.maxX - 2, y: row.frame.minY + 1))
                    assertUI(
                        zip(corner, surrounding).allSatisfy { abs($0 - $1) <= 2 },
                        "DDL 刷新分组应保留系统圆角：边角 \(corner)，周围底色 \(surrounding)。")
                    assertUI(
                        abs(app.buttons["添加待办"].frame.maxX - (safeArea.maxX - 8)) <= 1,
                        "DDL 悬浮操作应沿右栏的标准水平间距排列。")
                }
                assertBottom(app.buttons["schedule.add-content"])
                assertBottom(app.buttons["添加待办"])
                for (tab, identifier) in [
                    ("空教室", "browser.master"), ("话廊", "browser.master"),
                    ("文章", "browser.master"), ("成绩", "browser.master"), ("课程", "browser.master"),
                    ("我的", "browser.master"),
                ] {
                    app.mainTab(tab).tapBriefly()
                    assertDivider(identifier)
                    assertTopBackground()
                    assertPaneContentWidth(
                        "browser.master", left: safeArea.minX, right: expectedDivider)
                    if tab == "空教室" && isPhone {
                        let row = app.native.descendants(matching: .any)[identifier].cells
                            .firstMatch
                        assertUI(
                            row.exists && abs(row.frame.minX - (safeArea.minX + 8)) <= 1
                                && abs(row.frame.maxX - (expectedDivider - 8)) <= 1,
                            "空教室筛选分组行应完整位于左栏：\(row.frame)，中线 \(expectedDivider)。")
                        let results = app.native.descendants(matching: .any)[
                            "interaction.FreeClassroomTabView.list"
                        ].cells.firstMatch
                        assertUI(
                            results.exists && abs(results.frame.maxX - (safeArea.maxX - 8)) <= 1,
                            "空教室结果行应利用右栏可用宽度：\(results.frame)，安全区 \(safeArea)。")
                        recordLayoutScreenshot("空教室")
                    }
                    if tab == "话廊" || tab == "文章" {
                        assertCommunityTab(
                            tab,
                            isPhone: isPhone,
                            safeArea: safeArea,
                            assertBottom: assertBottom,
                            recordScreenshot: recordLayoutScreenshot)
                    }
                }
            }
        }
    }

    @MainActor
    @objc func testSchoolCaptchaCanBeCancelled() {
        app = configureApp(resetStorage: true, animations: true, school: true, schoolCaptcha: true)
        let refresh = app.descendants(matching: .any)["schedule.refresh-status"].buttons[
            "app.refresh-status.action"]
        refresh.tapBriefly()
        assertUI(
            app.navigationBars["图形验证"].appears(timeout: 5)
                && app.descendants(matching: .any)["verification.captcha"].exists,
            "图形验证码挑战应展示学校返回的图片。")
        tap("取消")
        assertUI(app.navigationBars["图形验证"].disappears(timeout: 5), "取消应恢复原查询页面。")
        refresh.tapBriefly()
        let code = app.textFields["verification.code"]
        code.typeText("aB12")
        assertUI(
            app.navigationBars["图形验证"].exists && code.value as? String == "aB12",
            "图形验证码应保留大小写，并由用户确认提交。")
        tap("验证并继续")
        assertUI(app.navigationBars["短信验证"].appears(timeout: 5), "图形验证通过后应继续所需的短信验证。")
        let value = code.value as? String
        assertUI(value == nil || value == "" || value == "短信验证码", "进入短信阶段应清空图形验证码。")
        fillVerificationCode("123456", in: code)
        assertUI(app.alerts["课表已是最新"].appears(timeout: 5), "验证完成应继续同一次课表同步。")
        closeAlertIfPresent()
    }

    @MainActor
    @objc func testRejectedSchoolCaptchaRequiresChallenge() {
        app = configureApp(resetStorage: true, animations: true, school: true, schoolCaptcha: true)
        let refresh = app.descendants(matching: .any)["schedule.refresh-status"].buttons[
            "app.refresh-status.action"]
        refresh.tapBriefly()
        app.textFields["verification.code"].typeText("wrong")
        tap("验证并继续")
        assertUI(
            app.alerts["验证已失效"].appears(timeout: 5)
                && !app.descendants(matching: .any)["verification.captcha"].exists,
            "图形验证失败应结束当前挑战，并提示重新发起。")
        closeAlertIfPresent()
        refresh.tapBriefly()
        assertUI(
            app.navigationBars["图形验证"].appears(timeout: 5)
                && app.descendants(matching: .any)["verification.captcha"].exists,
            "重新同步应建立新的图形验证码挑战。")
        tap("取消")
    }

    @MainActor
    @objc func testClassroomSmsUsesNativeDestination() {
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
    @objc func testClassroomLoadingKeepsThePageBackground() {
        let rotates = UIDevice.current.userInterfaceIdiom != .phone
        if rotates { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { if rotates { XCUIDevice.shared.orientation = .portrait } }
        app = configureApp(
            resetStorage: true, animations: true, school: true, classroomLoading: true)
        if app.native.windows.firstMatch.frame.height > app.native.windows.firstMatch.frame.width {
            return
        }
        app.mainTab("空教室").tapBriefly()
        let sidebar = app.descendants(matching: .any)["browser.master"]
        let results = app.descendants(matching: .any)["interaction.FreeClassroomTabView.list"]
        assertUI(app.staticTexts["正在加载空教室信息"].appears(timeout: 5), "空教室应处于首次查询的加载状态。")
        assertPanes("browser.master", "interaction.FreeClassroomTabView.list")
        let left = backgroundColor(at: CGPoint(x: sidebar.frame.midX, y: sidebar.frame.maxY - 24))
        let right = backgroundColor(at: CGPoint(x: results.frame.midX, y: results.frame.maxY - 24))
        assertUI(zip(left, right).allSatisfy { abs($0 - $1) <= 2 }, "空教室查询中的左右区域应沿页面分组底色呈现。")
        capture("空教室加载")
    }

    @MainActor
    @objc func testMineSettingsFillAvailableDetailWidth() {
        let rotates = UIDevice.current.userInterfaceIdiom != .phone
        if rotates { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { if rotates { XCUIDevice.shared.orientation = .portrait } }
        app = configureApp(
            resetStorage: true, content: true, animations: true, school: true,
            initialTab: "mine", initialSettings: "account")
        if app.native.windows.firstMatch.frame.height > app.native.windows.firstMatch.frame.width {
            assertPortraitDetailWidth()
            return
        }
        for route in ["account", "calendar", "ddl", "gallery", "about"] {
            let entry = app.buttons["settings.route.\(route)"]
            entry.tapBriefly()
            let detail = app.native.descendants(matching: .any)["browser.detail"]
            let master = app.native.descendants(matching: .any)["browser.master"]
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in
                        let window = self.app.windows.firstMatch.frame
                        let available =
                            self.app.windows.firstMatch.scrollGestureFrame(in: window) ?? window
                        let viewport =
                            detail.collectionViews.firstMatch.exists
                            ? detail.collectionViews.firstMatch : detail.scrollViews.firstMatch
                        return entry.native.isSelected && viewport.exists
                            && viewport.frame.width >= (available.maxX - master.frame.maxX) * 0.95
                    }, on: app, timeout: 5), "设置二级页面应填满右侧可用宽度：\(route)，详情 \(detail.frame)。")
        }
    }

    @MainActor
    @objc func testScheduleChromeSurvivesRotations() {
        guard UIDevice.current.userInterfaceIdiom != .phone else { return }
        defer { XCUIDevice.shared.orientation = .portrait }
        app = configureApp(
            resetStorage: true, ddlFixture: "sources", content: true, school: true,
            initialTab: "mine", initialSettings: "account")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.mainTab("日程").tapBriefly()
        for orientation: UIDeviceOrientation in [
            .portrait, .landscapeRight, .portraitUpsideDown,
            .landscapeLeft, .portrait, .landscapeRight,
        ] {
            XCUIDevice.shared.orientation = orientation
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in
                        let window = self.app.native.windows.firstMatch.frame
                        return (window.width > window.height) == orientation.isLandscape
                    }, on: app, timeout: 5), "日程应完成当前方向的窗口布局。")
            let tabs =
                orientation.isLandscape
                ? ["日程", "空教室", "地图", "话廊", "文章", "成绩", "课程", "我的"]
                : ["日程", "地图", "话廊", "成绩", "我的"]
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in
                        let navigation = tabs.map { self.app.mainTab($0).native.frame }.reduce(
                            CGRect.null
                        ) { $0.union($1) }
                        let window = self.app.native.windows.firstMatch.frame
                        let stamps = self.app.native.staticTexts.matching(
                            identifier: "app.refresh-status.timestamp"
                        )
                        .allElementsBoundByIndex.filter { window.intersects($0.frame) }
                        return !stamps.isEmpty
                            && stamps.allSatisfy { $0.frame.minY >= navigation.maxY - 0.5 }
                    }, on: app, timeout: 5), "日程保持选中并旋转后，刷新行应位于系统主导航下方：\(orientation.rawValue)。")
            assertSelectedWeek(1)
            if !orientation.isLandscape { assertCompactNavigation(requiresSections: true) }
        }
    }

    @MainActor
    @objc func testWindowUsesAdaptivePanes() {
        app = configureApp(
            resetStorage: true, ddlFixture: "sources", content: true, animations: true,
            school: true, pagination: true, initialTab: "mine")
        let traits = windowTraits()
        let isCompactPhone =
            traits["idiom"] == UIUserInterfaceIdiom.phone.rawValue
            && traits["horizontal"] == UIUserInterfaceSizeClass.compact.rawValue
        if isCompactPhone {
            assertUI(
                app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width,
                "紧凑手机采用竖屏布局。")
            assertUI(
                app.descendants(matching: .any)["browser.master"].frame.width >= app.windows
                    .firstMatch.frame.width * 0.95,
                "竖向窗口应以完整宽度展示资料与设置入口。")
            assertUI(app.mainTab("我的").isHittable, "竖向窗口保留主导航。")
            return
        }
        defer { XCUIDevice.shared.orientation = .portrait }
        func showPortrait() {
            XCUIDevice.shared.orientation = .portrait
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in
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
                let sort = app.native.segmentedControls.containing(.button, identifier: "最新")
                    .firstMatch
                assertUI(
                    waitUntil(
                        NSPredicate { _, _ in
                            let window = self.app.native.windows.firstMatch.frame
                            return window.width > window.height && sort.exists && first.exists
                                && first.frame.width < window.width / 2
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
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    let window = self.app.native.windows.firstMatch.frame
                    return window.width > window.height
                }, on: app, timeout: 10), "横屏专项应在实际横屏窗口运行；Duo 姿态由 Device Hub 设置。")
        assertPanes("browser.master", "browser.detail")
        capture("个人页")
        openSettings("account")
        tap("昵称")
        let input = app.textFields.firstMatch
        replaceText("横屏编辑草稿", in: input)
        dismissKeyboard()
        assertUI(input.value as? String == "横屏编辑草稿", "横屏编辑与键盘收起保留完整草稿。")
        tap("取消")
        capture("个人页")
        checkAcademicBrowsers()
        app.mainTab("日程").tapBriefly()
        let calendarWeek = app.buttons["第1周"]
        assertUI(calendarWeek.appears(timeout: 5) && calendarWeek.isHittable, "横屏应完整展示课表周次。")
        assertUI(app.buttons["添加待办"].isHittable, "课表与单列 DDL 应同时提供入口。")
        let surface = app.descendants(matching: .any)["schedule.section-surface"]
        let window = app.windows.firstMatch
        if let safeArea = window.scrollGestureFrame(in: window.frame) {
            assertUI(
                waitUntil(
                    NSPredicate { _, _ in surface.frame.maxY >= safeArea.maxY - 1 }, on: app,
                    timeout: 5),
                """
                日程应填满窗口安全区：内容 \(surface.frame)，安全区 \(safeArea)，键盘 \
                \(controlDiagnostic("keyboard-state", fallback: "未知"))。
                """
            )
        }
        let grid = app.descendants(matching: .any)["schedule.calendar"]
        assertUI(
            waitUntil(
                NSPredicate { _, _ in grid.exists && grid.frame.maxY >= surface.frame.maxY - 17 },
                on: app),
            "课表网格应延伸至模块底部的标准间距：网格 \(grid.frame)，模块 \(surface.frame)。")
        capture("课表与DDL")
        tapHeader(app.sectionTab("空教室"))
        assertPanes("browser.master", "interaction.FreeClassroomTabView.list")
        capture("空教室")
        app.mainTab("话廊").tapBriefly()
        tapHeader(app.segmentedControls.buttons["最新"])
        let first = app.descendants(matching: .any)["community.poster.card.1"]
        let second = app.descendants(matching: .any)["community.poster.card.2"]
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    first.exists && second.exists && first.frame.maxY <= second.frame.minY
                }, on: app), "横屏话题应沿左侧单列排列。")
        capture("话题列表")
        let more = app.descendants(matching: .any)["ui.community-poster-action-menu.menu"]
        assertUI(
            more.frame.width >= 44 - 0.5 && more.frame.height >= 44 - 0.5,
            "帖子菜单应提供完整点击区域：\(more.frame)。")
        more.tapBriefly()
        assertUI(app.buttons["举报帖子"].appears(timeout: 5), "帖子菜单应响应原生触摸。")
        app.mainTab("话廊").tapBriefly()
        assertUI(app.buttons["举报帖子"].disappears(timeout: 5), "点按导航应关闭帖子菜单。")
        app.mainTab("话廊").tapBriefly()
        assertUI(first.appears(timeout: 5), "详情验收应在话题列表中选择内容。")
        first.tapBriefly()
        assertUI(
            app.navigationBars["帖子详情"].appears(timeout: 5) && first.exists, "话题详情应在右侧打开并保留左侧列表。")
        assertDetailWidth()
        capture("话题详情")
        checkPortraitRoundTrip(detailTitle: "帖子详情") { first.tapBriefly() }
        assertUI(first.appears(timeout: 5) && app.navigationBars["帖子详情"].exists, "返回横屏应保留阅读位置与详情。")
        tapHeader(app.sectionTab("文章"))
        let paper = textElement("分页文章 1")
        let nextPaper = textElement("分页文章 2")
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    paper.exists && nextPaper.exists && paper.frame.maxY <= nextPaper.frame.minY
                }, on: app), "横屏文章应沿左侧单列排列。")
        capture("文章列表")
        paper.tapBriefly()
        assertUI(
            app.navigationBars["文章详情"].appears(timeout: 5) && paper.exists, "文章详情应在右侧打开并保留左侧列表。")
        assertDetailWidth()
        capture("文章详情")
        checkPortraitRoundTrip(detailTitle: "文章详情") { paper.tapBriefly() }
        app.mainTab("地图").tapBriefly()
        let layer = app.buttons["切换地图图层"]
        assertUI(
            layer.appears(timeout: 5) && app.windows.firstMatch.frame.contains(layer.frame),
            "横屏地图应完整显示图层工具。")
        layer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapBriefly()
        waitForValue("卫星图", of: layer)
        capture("地图")
        app = configureApp(
            resetStorage: true, accessibilityTextSize: true, content: true, animations: true,
            school: true, initialTab: "mine")
        assertUI(textElement("自动化测试用户").appears(timeout: 5), "大字号窗口保留资料内容。")
        assertUI(!app.collectionViews["mine.sidebar"].exists, "辅助功能字号采用完整宽度的单列内容。")
        app.mainTab("日程").tapBriefly()
        let week = app.buttons["第1周"]
        assertUI(
            week.appears(timeout: 5) && week.frame.width >= 44 && week.frame.height >= 44,
            "大字号周次刻度保留完整点击区域。")
        let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1周，周一，"))
            .firstMatch
        assertUI(day.appears(timeout: 5) && day.frame.height >= 44, "大字号日期入口保留完整点击高度。")
    }

    @MainActor @objc func testAcademicBrowsersKeepTheSharedChrome() throws {
        let usesDeviceRotation = UIDevice.current.userInterfaceIdiom != .phone
        if usesDeviceRotation { XCUIDevice.shared.orientation = .portrait }
        app = configureApp(resetStorage: true, content: true, animations: true, school: true)
        try requireLandscapeSupport()
        if usesDeviceRotation {
            for tab in ["成绩", "话廊", "日程", "成绩", "话廊", "日程"] {
                app.mainTab(tab).native.press(forDuration: 0.01)
                assertCompactNavigation(requiresSections: true)
            }
            app.mainTab("我的").native.press(forDuration: 0.01)
            assertCompactNavigation()
            app.mainTab("成绩").native.press(forDuration: 0.01)
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        defer { if usesDeviceRotation { XCUIDevice.shared.orientation = .portrait } }
        assertUI(
            waitUntil(
                NSPredicate { _, _ in
                    let window = self.app.windows.firstMatch.frame
                    return window.width > window.height
                }, on: app, timeout: 10), "分栏验收使用实际横屏窗口。")
        checkAcademicBrowsers()
        checkPortraitRoundTrip(detailTitle: "成绩详情") {
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "ui.score-list-page.score.")
            ).firstMatch.tapBriefly()
        }
        app.mainTab("课程").tapBriefly()
        checkPortraitRoundTrip(detailTitle: "课程详情") {
            app.buttons["ui.course-page-content.course"].tapBriefly()
        }
        for (tab, title) in [("日程", "课表与DDL"), ("话廊", "话题列表"), ("文章", "文章列表")] {
            app.mainTab(tab).tapBriefly()
            capture(title)
        }
    }
}
