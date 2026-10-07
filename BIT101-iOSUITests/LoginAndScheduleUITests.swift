import XCTest
import CoreGraphics
import Network
import os

nonisolated final class LoginAndScheduleUITests: UIAutomationTestCase {
    @MainActor
    func testAccessibilityQueryParityAndNativeButtonContract() throws {
        app = configureApp(resetStorage: true, account: nil)
        XCTAssertEqual(app.frame, app.native.frame)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "ui-test.scene").firstMatch.value as? String,
                       app.native.descendants(matching: .any).matching(identifier: "ui-test.scene").firstMatch.value as? String)
        func compareWithNative(_ element: UIElement) throws {
            let actual = try XCTUnwrap(element.attributes(), "渲染查询应提供当前控件状态。")
            let expected = try element.native.snapshot()
            XCTAssertEqual(actual["identifier"] as? String, expected.identifier)
            XCTAssertEqual(actual["label"] as? String, expected.label)
            XCTAssertEqual(actual["elementType"] as? Int, Int(expected.elementType.rawValue))
            XCTAssertEqual(actual["enabled"] as? Bool, expected.isEnabled)
            XCTAssertEqual(actual["hittable"] as? Bool, element.native.isHittable)
            let frame = try XCTUnwrap(actual["frame"] as? [Double])
            for (value, reference) in zip(frame, [expected.frame.minX, expected.frame.minY, expected.frame.width, expected.frame.height]) {
                XCTAssertEqual(value, Double(reference), accuracy: 0.5)
            }
        }
        for element in [app.textFields["login.student-id"], app.secureTextFields["login.password"], app.buttons["login.submit"]] {
            try compareWithNative(element)
        }
        let missing = app.buttons["ui-test.missing-control"]
        XCTAssertFalse(missing.exists)
        XCTAssertFalse(missing.native.exists)
        XCTAssertFalse(missing.isHittable)
        for element in [app.staticTexts.firstMatch, app.descendants(matching: .any).matching(identifier: "login.student-id").firstMatch] {
            let actual = try XCTUnwrap(element.attributes())
            let expected = try element.native.snapshot()
            XCTAssertEqual(actual["identifier"] as? String, expected.identifier)
            XCTAssertEqual(actual["label"] as? String, expected.label)
            XCTAssertEqual(actual["elementType"] as? Int, Int(expected.elementType.rawValue))
        }
        app = configureApp(resetStorage: true)
        app.buttons["下一周"].native.press(forDuration: 0.01)
        UITestSnapshotReader.invalidate()
        assertSelectedWeek(2)
        XCTAssertTrue(app.buttons["第2周"].native.isSelected)
        app.buttons["上一周"].tapBriefly()
        assertSelectedWeek(1)
        XCTAssertTrue(app.buttons["第1周"].native.isSelected)
        app.buttons["schedule.add-content"].native.press(forDuration: 0.01)
        UITestSnapshotReader.invalidate()
        app.native.buttons["添加日程"].firstMatch.press(forDuration: 0.01)
        UITestSnapshotReader.invalidate()
        let title = app.textFields["schedule.custom.title"]
        title.native.tap()
        UITestSnapshotReader.invalidate()
        replaceText("渲染查询输入", in: title)
        XCTAssertEqual(title.native.value as? String, "渲染查询输入")
        XCTAssertTrue(app.keyboards.firstMatch.native.exists)
        dismissKeyboard()
        XCTAssertTrue(app.keyboards.firstMatch.native.disappears(timeout: 5))
        replaceText("字段绑定输入", in: title)
        XCTAssertEqual(title.native.value as? String, "字段绑定输入")
        XCTAssertTrue(app.keyboards.firstMatch.native.disappears(timeout: 5))
        app.buttons["取消"].native.press(forDuration: 0.01)
        UITestSnapshotReader.invalidate()
        XCTAssertTrue(app.buttons["schedule.add-content"].native.exists)
        app = configureApp(resetStorage: true, initialSettings: "gallery")
        let row = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "隐藏匿名内容")).firstMatch
        let control = row.native.switches.firstMatch
        let initial = control.value as? String
        control.tap()
        UITestSnapshotReader.invalidate()
        XCTAssertNotEqual(control.value as? String, initial)
        _ = toggle("隐藏匿名内容")
        XCTAssertEqual(control.value as? String, initial)
        app = configureApp(resetStorage: false, initialSettings: "gallery")
        XCTAssertEqual(app.switches.matching(NSPredicate(format: "label CONTAINS %@", "隐藏匿名内容")).firstMatch.native.switches.firstMatch.value as? String, initial)
        app.navigationBars["话廊设置"].buttons.firstMatch.native.press(forDuration: 0.01)
        UITestSnapshotReader.invalidate()
        XCTAssertTrue(app.buttons["settings.route.gallery"].appears(timeout: 5))
        openSettings("gallery")
        back()
        XCTAssertTrue(app.buttons["settings.route.gallery"].appears(timeout: 5))
        app = configureApp(resetStorage: true, initialTab: "gallery")
        let alert = app.alerts["加载话廊失败"]
        XCTAssertTrue(alert.appears(timeout: 5))
        try compareWithNative(alert.buttons["知道了"])
        alert.buttons["知道了"].native.press(forDuration: 0.01)
        UITestSnapshotReader.invalidate()
        XCTAssertTrue(alert.disappears(timeout: 5))
        XCTAssertFalse(alert.native.exists)
    }

    @MainActor
    func testScheduleWeekButtonsAndSectionSwipes() {
        app = configureApp(resetStorage: true, school: true)
        tap("下一周")
        assertSelectedWeek(2)
        tap("上一周")
        assertSelectedWeek(1)
        tap("第3周")
        assertSelectedWeek(3)
        let area = app.descendants(matching: .any).matching(identifier: "schedule.blank-context-menu").firstMatch
        area.swipeLeft()
        assertUI(app.segmentedControls.buttons["DDL"].isSelected, "横滑应切换到 DDL。")
        app.swipeLeft()
        assertUI(app.segmentedControls.buttons["空教室"].isSelected, "横滑应切换到空教室。")
        closeAlertIfPresent()
        app.swipeRight()
        assertUI(app.segmentedControls.buttons["DDL"].isSelected, "反向横滑应恢复 DDL。")
        tapHeader(app.segmentedControls.buttons.element(boundBy: 0))
        assertUI(app.buttons["schedule.add-content"].exists, "分栏切换应恢复课表交互。")
    }

    @MainActor
    func testScheduleDayHolidayAndTransferConfirmationCancellation() {
        app = configureApp(resetStorage: true)
        tap("第1周")
        let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第1周，周一，")).firstMatch
        assertUI(day.appears(timeout: 5), "每日表头应提供调整入口。")
        day.tapBriefly()
        assertUI(app.navigationBars["调休 / 放假"].appears(timeout: 5), "每日表头应打开日期调整。")
        tapHeader(app.segmentedControls.buttons["放假"])
        tap("确定")
        assertUI(app.alerts["确认放假"].appears(timeout: 5), "放假应展示确认。")
        app.alerts.buttons["取消"].tapBriefly()
        tapHeader(app.segmentedControls.buttons["调至某天"])
        assertUI(app.datePickers.firstMatch.exists, "调休应提供目标日期选择。")
        tap("确定")
        assertUI(app.alerts["确认调课"].appears(timeout: 5), "调休应展示确认。")
        app.alerts.buttons["取消"].tapBriefly()
        tap("取消")
        assertUI(app.buttons["schedule.add-content"].exists, "取消日期调整应恢复课表。")
    }

    @MainActor
    func testLinearScheduleTimelineScrollAndPinch() {
        app = configureApp(resetStorage: true)
        openSettings("calendar")
        assertInteractiveLabelIsColored("时间轴")
        choose("时间轴", option: "线性")
        back()
        app.tabBars.buttons["日程"].tapBriefly()
        let timeline = app.scrollViews["schedule.linear.timeline"]
        assertUI(timeline.appears(timeout: 5), "线性模式应提供可缩放的时间轴。")
        let canvas = app.buttons["schedule.blank-context-menu"]
        XCTAssertEqual(canvas.native.frame.minX, timeline.native.frame.minX, accuracy: 0.5, "初始时间轴应与视口左边界对齐。")
        let initial = timeline.value as? String
        timeline.pinch(withScale: 1.5, velocity: 1)
        assertUI(waitUntil(NSPredicate(format: "value != %@", initial ?? ""), on: timeline, timeout: 5), "双指展开应放大时间轴，当前值：\(String(describing: timeline.value))，\(timeline.label)。")
        let enlarged = timeline.value as? String
        XCTAssertEqual(canvas.native.frame.minX, timeline.native.frame.minX, accuracy: 0.5, "放大后的日期列应与视口左边界对齐。")
        timeline.swipeUp()
        timeline.swipeDown()
        timeline.pinch(withScale: 0.8, velocity: -1)
        assertUI(timeline.value as? String != enlarged, "双指收拢应缩小时间轴。")
        XCTAssertEqual(canvas.native.frame.minX, timeline.native.frame.minX, accuracy: 0.5, "缩小后的日期列应与视口左边界对齐。")
        assertUI(timeline.isHittable, "缩放和滚动后时间轴应可交互。")
    }

    @MainActor
    func testMapCampusLayerPanAndZoomPersist() {
        app = configureApp(resetStorage: true, initialTab: "map")
        let layer = app.buttons["切换地图图层"]
        assertUI(layer.appears(timeout: 5), "地图应提供图层入口。")
        let original = layer.value as? String
        layer.tapBriefly()
        assertUI(layer.value as? String != original, "切换图层应改变地图模式。")
        for campus in ["良乡校区", "中关村校区", "珠海校区"] {
            let button = app.buttons["切换到\(campus)"]
            button.tapBriefly()
            assertUI(button.isSelected, "校区切换应更新选中状态：\(campus)")
        }
        let map = app.maps.firstMatch
        assertUI(map.exists, "地图应暴露可交互的地图区域。")
        map.swipeLeft()
        map.pinch(withScale: 1.5, velocity: 1)
        assertUI(layer.isHittable, "平移和缩放后地图操作仍可触达。")
        app = configureApp(resetStorage: false, initialTab: "map")
        assertUI(app.buttons["切换地图图层"].value as? String != original, "重新装载应保留图层设置。")
        assertUI(app.buttons["切换到珠海校区"].isSelected, "重新装载应保留校区。")
    }

    @MainActor
    func testCalendarSettingsPickersTogglesAndRenamePersist() {
        app = configureApp(resetStorage: true, initialSettings: "calendar")
        tap("时间表")
        let editor = app.textViews.firstMatch
        replaceTextWithKeyboard("invalid", in: editor)
        dismissKeyboard()
        tap("确定")
        assertUI(app.alerts["设置失败"].appears(timeout: 5), "错误时间表应展示校验结果。")
        closeAlertIfPresent()
        replaceText("08:00,08:45\n09:00,09:45", in: editor)
        dismissKeyboard()
        tap("确定")
        tap("时间表")
        assertUI((editor.value as? String ?? "").contains("08:00"), "保存应恢复新时间表。")
        replaceText("10:00,10:45", in: editor)
        dismissKeyboard()
        tap("取消")
        tap("时间表")
        assertUI((editor.value as? String ?? "").contains("08:00"), "取消应保留已保存时间表。")
        tap("取消")
        let cancelName = app.buttons["schedule.settings.primary-name"]
        reveal(cancelName)
        cancelName.tapBriefly()
        replaceText("取消的名称", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("取消")
        assertUI(!cancelName.label.contains("取消的名称"), "取消改名应保留课表名称。")
        choose("时间轴", option: "线性")
        choose("时间轴", option: "节次")
        choose("课程显示方式", option: "全学期叠加")
        choose("课程显示方式", option: "按周显示")
        for option in ["名称", "地点", "名称和地点"] {
            choose("显示内容", option: option)
        }
        let savedSwitches = Dictionary(uniqueKeysWithValues: ["显示周六", "显示周日", "显示考试安排"].map { ($0, toggle($0)) })
        let nameRow = app.buttons["schedule.settings.primary-name"]
        reveal(nameRow, description: "课表名称")
        nameRow.tapBriefly()
        let name = app.textFields["schedule.rename.name"]
        assertUI(name.appears(timeout: 5), "重命名应展示输入框。")
        replaceText("测试课表名称", in: name)
        tap("确定")
        assertUI(textElement("测试课表名称").appears(timeout: 5), "重命名应更新设置行。")
        app = configureApp(resetStorage: false)
        assertUI(app.segmentedControls.buttons["测试课表名称"].exists, "重新装载应保留课表名称。")
        openSettings("calendar")
        for title in ["显示周六", "显示周日", "显示考试安排"] {
            let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            reveal(control, description: title)
            assertUI(control.value as? String == savedSwitches[title], "重新装载应保留开关：\(title)")
        }
    }

    @MainActor
    func testCalendarOfflineTermFailureAndCancellation() {
        app = configureApp(resetStorage: true, initialSettings: "calendar")
        tap("当前学期")
        assertUI(app.navigationBars["切换学期"].appears(timeout: 5), "当前学期应打开选择页。")
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "学校离线应展示学期加载失败。")
        closeAlertIfPresent()
        back()
        assertUI(app.buttons["schedule.settings.primary-name"].exists, "关闭失败提示并返回应恢复日程设置。")
    }


    @MainActor
    func testSharedScheduleCopyImportRenameCycleAndSwipeDelete() {
        app = configureApp(resetStorage: true, initialSettings: "calendar")
        tap("分享课表")
        assertUI(app.alerts["当前课表为空"].appears(timeout: 5), "空课表分享应先提示确认。")
        app.alerts["当前课表为空"].buttons["确定"].tapBriefly()
        tap("复制到剪贴板")
        assertUI(app.alerts["已复制"].appears(timeout: 5), "复制编码应展示成功提示。")
        app.alerts["已复制"].buttons["知道了"].tapBriefly()
        tap("取消")
        tap("导入课表")
        assertUI(app.alerts["导入分享课表提示"].appears(timeout: 5), "首次导入应展示说明。")
        app.alerts["导入分享课表提示"].buttons["知道了"].tapBriefly()
        tap("粘贴剪贴板")
        let code = app.textViews["schedule.import.code"]
        assertUI(!(code.value as? String ?? "").isEmpty, "粘贴应恢复刚导出的编码。")
        tap("导入")
        assertUI(app.alerts["导入成功"].appears(timeout: 5), "导入分享课表应展示成功结果。")
        closeAlertIfPresent()
        let shared = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "schedule.settings.shared.")).firstMatch
        reveal(shared, description: "分享课表名称")
        shared.tapBriefly()
        replaceText("测试分享课表", in: app.textFields["schedule.rename.name"])
        dismissKeyboard()
        tap("确定")
        assertUI(waitUntil(NSPredicate(format: "label CONTAINS %@", "测试分享课表"), on: shared, timeout: 5), "保存应更新分享课表名称。")
        back()
        app.tabBars.buttons["日程"].tapBriefly()
        let sharedSegment = app.segmentedControls.buttons["测试分享课表"]
        assertUI(sharedSegment.appears(timeout: 5), "导入和改名应增加课表分栏。")
        let area = app.descendants(matching: .any).matching(identifier: "schedule.blank-context-menu").firstMatch
        area.swipeUp()
        assertUI(app.segmentedControls.buttons.element(boundBy: 0).label == "课表", "向上滑动应从分享课表循环到主课表。")
        area.swipeDown()
        assertUI(app.segmentedControls.buttons.element(boundBy: 0).label == "测试分享课表", "向下滑动应恢复分享课表。")
        openSettings("calendar")
        reveal(shared, description: "分享课表名称")
        shared.swipeLeft()
        tap("删除")
        assertUI(!shared.exists, "左滑删除应移除分享课表。")
    }


    @MainActor
    func testDDLSettingsWheelSaveCancelAndPersistence() {
        app = configureApp(resetStorage: true)
        openSettings("ddl")
        tap("变色天数")
        let wheel = app.pickerWheels.firstMatch
        assertUI(wheel.appears(timeout: 5), "变色天数应使用滚轮选择。")
        wheel.adjust(toPickerWheelValue: "7 天")
        tap("完成")
        assertUI(wheel.disappears(timeout: 5), "保存变色天数应收起滚轮。")
        tap("滞留天数")
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "10 天")
        tap("取消")
        assertUI(wheel.disappears(timeout: 5), "取消滞留天数应收起滚轮。")
        tap("滞留天数")
        assertUI(app.pickerWheels.firstMatch.value as? String != "10 天", "取消应保留原值。")
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "5 天")
        tap("完成")
        assertUI(wheel.disappears(timeout: 5), "保存滞留天数应收起滚轮。")
        app = configureApp(resetStorage: false, initialSettings: "ddl")
        tap("变色天数")
        assertUI(app.pickerWheels.firstMatch.value as? String == "7 天", "重新装载应保留变色天数。")
        tap("取消")
        assertUI(wheel.disappears(timeout: 5), "取消变色天数应收起滚轮。")
        tap("滞留天数")
        assertUI(app.pickerWheels.firstMatch.value as? String == "5 天", "重新装载应保留滞留天数。")
        tap("取消")
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
        app = configureApp(resetStorage: false, initialSettings: "gallery")
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
        assertUI(app.tabBars.buttons["我的"].exists, "取消重置应保留当前会话。")
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
    }


    @MainActor
    func testPaperPublishEditCommentAndDelete() {
        app = configureApp(resetStorage: true, content: true, animations: true, initialTab: "gallery")
        tapHeader(app.segmentedControls.buttons["文章"])
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
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: editor, timeout: 5), "保存文章应返回详情。")
        assertUI(textElement("测试修改文章").appears(timeout: 5), "保存应更新文章详情。")
        assertUI(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "文章发布测试正文")).firstMatch.native.exists,
                 "修改标题应保留完整正文。")
        tap("更多操作")
        app.buttons["paper.detail.edit"].tapBriefly()
        assertUI(editor.appears(timeout: 5), "已保存文章应支持再次编辑。")
        replaceText("取消的文章修改", in: app.textFields["标题"])
        dismissKeyboard()
        tap("取消")
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
        assertUI(!app.buttons["提交"].isEnabled, "空建议应禁用提交。")
        replaceText("自动化测试建议", in: text)
        dismissKeyboard()
        let contact = app.textFields["联系方式"]
        replaceText("测试联系信息", in: contact)
        dismissKeyboard()
        tap("取消")
        tap("保存草稿")
        openSettings("suggestion")
        tap("加载草稿")
        assertUI(app.textFields["建议内容"].value as? String == "自动化测试建议", "建议草稿应恢复正文。")
        assertUI(app.textFields["联系方式"].value as? String == "测试联系信息", "建议草稿应恢复联系信息。")
        tap("取消")
        tap("不保存")
    }

    @MainActor
    func testCourseEditorFieldsPickersSaveDetailAndDelete() {
        app = configureApp(resetStorage: true)
        app.buttons["schedule.add-content"].tapBriefly()
        tap("添加课程")
        for (title, value) in [("课程名称", "测试补录课程"), ("教师", "测试教师"), ("教室", "文萃A101"), ("周次（如 1-16,18）", "1-3")] {
            let field = app.textFields[title]
            assertUI(field.exists, "课程编辑应支持字段：\(title)")
            replaceText(value, in: field)
        }
        dismissKeyboard()
        choose("星期", option: "周2")
        tap("开始节次")
        tap("第1节")
        tap("结束节次")
        tap("第2节")
        tap("确定")
        let course = textElement("测试补录课程")
        assertUI(course.appears(timeout: 5), "补录课程应显示在课表。")
        course.tapBriefly()
        tap("调这门课")
        assertUI(app.navigationBars["调这门课"].appears(timeout: 5), "调课应打开安排编辑器。")
        assertUI(app.textFields["房间号"].exists, "调课应支持地点编辑。")
        tap("取消")
        assertUI(app.navigationBars["调这门课"].disappears(timeout: 5), "取消应关闭调课编辑器。")
        app.buttons["删除这门课"].press(forDuration: 0.01)
        app.alerts.buttons["取消"].tapBriefly()
        assertUI(app.buttons["删除这门课"].exists, "取消删除应保留课程详情。")
        app.buttons["删除这门课"].press(forDuration: 0.01)
        app.alerts.buttons["删除"].tapBriefly()
        assertUI(course.disappears(timeout: 5), "确认删除应移除课程。")
        app.buttons["schedule.add-content"].tapBriefly()
        tap("添加课程")
        tap("取消")
        assertUI(app.buttons["schedule.add-content"].exists, "取消课程编辑应返回课表。")
    }

    @MainActor
    func testImportInvalidCodeReportsErrorAndKeepsEditor() {
        app = configureApp(resetStorage: true)
        let area = app.descendants(matching: .any).matching(identifier: "schedule.blank-context-menu").firstMatch
        area.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        tap("导入课表")
        let code = app.textViews["schedule.import.code"]
        assertUI(code.appears(timeout: 5), "导入应打开编码编辑器。")
        code.tapBriefly()
        code.typeText("invalid-code")
        dismissKeyboard()
        tap("导入")
        assertUI(app.alerts.firstMatch.appears(timeout: 5), "无效编码应给出校验结果。")
        closeAlertIfPresent()
        assertUI(code.value as? String == "invalid-code", "校验失败应保留输入以供修改。")
        tap("取消")
    }

    @MainActor
    func testSchoolDDLSourcesAndCompletionPersistAcrossSceneReload() throws {
        app = configureApp(resetStorage: true, ddlFixture: "sources")
        let ddl = app.segmentedControls.buttons["DDL"]
        assertUI(ddl.appears(timeout: 10), "日程页应展示 DDL 分页。")
        ddl.tapBriefly()
        let eclass = app.staticTexts["课程中心测试作业"]
        assertUI(eclass.appears(timeout: 5), "DDL 页应展示课程中心作业。")
        assertUI(app.staticTexts["乐学测试日程"].exists, "DDL 页应展示乐学日程。")
        let completion = app.buttons["ddl.done.eclass:ui"]
        assertUI(completion.exists, "课程中心作业应提供完成状态操作。")
        completion.tapBriefly()
        assertUI(completion.value as? String == "已完成", "点击后应保存完成状态。")
        eclass.tapBriefly()
        assertUI(app.navigationBars["DDL 详情"].appears(timeout: 5), "课程中心作业应打开详情。")
        assertUI(app.staticTexts["课程中心"].exists, "详情应显示中文来源。")
        assertUI(!app.buttons["编辑"].exists && !app.buttons["删除"].exists, "学校作业应按同步来源展示。")
        tapHeader(app.buttons["取消"])
        app = configureApp(resetStorage: false)
        tapHeader(app.segmentedControls.buttons["DDL"])
        let restored = app.buttons["ddl.done.eclass:ui"]
        assertUI(restored.appears(timeout: 5), "重新启动后应恢复课程中心作业。")
        assertUI(restored.value as? String == "已完成", "重新启动后应恢复完成状态。")
    }

    @MainActor
    func testDDLEmptyStateExplainsTheRetentionWindow() throws {
        app = configureApp(resetStorage: true, ddlFixture: "overdue")
        tapHeader(app.segmentedControls.buttons["DDL"])
        let explanation = app.staticTexts["1 条日程已超出显示范围。当前滞留天数为 0 天，可在 DDL 设置调整。"]
        assertUI(explanation.appears(timeout: 5), "过期日程的空列表应说明当前显示范围。")
    }

    @MainActor
    func testLongPressOpensScheduleContextMenuAndImportSheet() throws {
        app = configureApp(resetStorage: true)

        let contextArea = app.descendants(matching: .any)
            .matching(identifier: "schedule.blank-context-menu")
            .firstMatch
        assertUI(contextArea.appears(timeout: 10), "日程页面应展示可操作的空白课表区域。")
        contextArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)

        let shareAction = app.buttons["分享课表"]
        let importAction = app.buttons["导入课表"]
        assertUI(
            shareAction.appears(timeout: 5),
            "长按课表区域后应展示分享操作。\(focusedAccessibilitySnapshot(app, matching: ["分享", "导入", "课表", "menu"]))"
        )
        assertUI(importAction.exists, "长按课表区域后应展示导入操作。")

        importAction.tapBriefly()
        assertUI(app.navigationBars["导入课表"].appears(timeout: 5), "点按导入后应打开导入课表面板。")
        assertUI(app.textViews["schedule.import.code"].exists, "导入面板应展示课表编码编辑区。")
    }


    @MainActor
    func testCustomSchedulesAreIsolatedBetweenAccounts() throws {
        app = configureApp(resetStorage: true, account: "ui-test-account-a", content: true)
        addCustomSchedule("A 账户专属日程", in: app)

        app.tabBars.buttons["我的"].tapBriefly()
        let accountRoute = app.buttons["settings.route.account"]
        assertUI(accountRoute.appears(timeout: 10), "我的页面应展示账号设置入口。")
        accountRoute.tapBriefly()

        let logout = app.buttons["settings.account.logout"]
        assertUI(logout.appears(timeout: 5), "账号设置应展示退出操作。")
        logout.tapBriefly()

        let studentID = app.textFields["login.student-id"]
        assertUI(studentID.appears(timeout: 10), "退出后应返回登录表单。")
        assertUI(studentID.value as? String == "ui-test-account-a", "退出后表单应保留账号 A。")
        signIn(app, studentID: "ui-test-account-b")
        let accountASchedule = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "自定义日程，A 账户专属日程"))
            .firstMatch
        assertUI(!accountASchedule.exists, "账号 B 的课表应隔离账号 A 的日程。")
    }


    @MainActor
    func testMainTabsRemainAccessibleAtAccessibilityDynamicType() throws {
        for style in ["Light", "Dark"] {
            app = configureApp(
                resetStorage: true,
                accessibilityTextSize: true,
                userInterfaceStyle: style
            )
            assertMainTabsRemainAccessible(style: style)
        }
    }



}

@MainActor
extension XCUIElement {

    func appears(timeout: TimeInterval) -> Bool {
        waitForPresence(true, timeout: timeout)
    }

    func disappears(timeout: TimeInterval) -> Bool {
        waitForPresence(false, timeout: timeout)
    }

    @MainActor
    private func waitForPresence(_ presence: Bool, timeout: TimeInterval) -> Bool {
        if exists == presence { return true }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if exists == presence { return true }
        } while Date() < deadline
        return false
    }
}
