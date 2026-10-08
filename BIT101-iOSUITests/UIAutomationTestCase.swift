import XCTest
import CoreGraphics
import Network
import os

nonisolated class UIAutomationTestCase: XCTestCase {
    @MainActor var app = UIElement(XCUIApplication(), path: [])
    @MainActor private static var sessionApplication: XCUIApplication?
    @MainActor private static var sessionProcess: String?
    @MainActor private static var sessionScene: String?
    @MainActor private static let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let runIdentifier = "ui"

    override func tearDown() async throws {
        await MainActor.run {
            if Self.sessionApplication?.state == .runningForeground,
               let coverage = UITestControlClient.request(["command": "coverage"]) {
                print("UI control inventory: \(coverage)")
            }
        }
        try await super.tearDown()
    }

    @MainActor
    func assertSelectedWeek(_ week: Int) {
        let button = app.buttons["第\(week)周"]
        if button.isSelected { return }
        assertUI(waitUntil(NSPredicate(format: "selected == true"), on: button, timeout: 5), "周次选择应更新为第 \(week) 周。")
    }

    @MainActor
    func tap(_ title: String) {
        let response = title == "取消" ? nil
            : UITestControlClient.request(["command": "resolve", "label": title], timeout: 5)
        if let response, let target = try? JSONDecoder().decode([String: String].self, from: Data(response.utf8)) {
            let identifier = target["identifier"] ?? ""
            let label = target["label"] ?? ""
            let predicate = identifier.isEmpty
                ? (label == title ? NSPredicate(format: "label == %@", title) : NSPredicate(format: "label CONTAINS %@", title))
                : NSPredicate(format: "identifier == %@ AND label CONTAINS %@", identifier, title)
            let button = app.buttons.matching(predicate).firstMatch
            if !button.isHittable { reveal(button, description: title) }
            button.tapBriefly()
            return
        }
        let exact = app.buttons.matching(NSPredicate(format: "label == %@", title))
        let exactExists = exact.firstMatch.exists
        let matches = exactExists ? exact : app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title))
        let button = matches.firstMatch
        if exactExists || button.exists {
            if button.isHittable {
                button.tapBriefly()
                return
            }
            if let visible = matches.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                visible.press(forDuration: 0.01)
                return
            }
        }
        reveal(button, description: title)
        button.press(forDuration: 0.01)
    }

    @MainActor
    func dismissNotificationBanner() {
        if app.state != .runningForeground { app.activate() }
        let banner = Self.springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        if banner.exists && banner.isHittable {
            let frame = banner.frame
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY))
                .press(forDuration: 0.01, thenDragTo: origin.withOffset(CGVector(dx: frame.midX, dy: 0)),
                       withVelocity: .fast, thenHoldForDuration: 0.01)
            assertUI(banner.disappears(timeout: 2), "系统通知横幅应收起并恢复顶栏交互。")
            print("UI notification banner dismissed")
            if app.state != .runningForeground { app.activate() }
        }
    }

    @MainActor
    func tapHeader(_ element: UIElement) {
        element.tapBriefly()
    }

    @MainActor
    func reveal(_ element: UIElement, description: String = "交互控件") {
        if element.exists && element.isHittable { return }
        if !UIElement.usesNativeInteraction, element.revealInScrollView() == "revealed", element.exists && element.isHittable {
            print("UI scroll reveal")
            return
        }
        let window = app.windows.firstMatch.frame
        let frame = interactionScrollFrame() ?? app.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<8 {
            let target = element.exists ? element.frame : CGRect.null
            let horizontal = !target.isNull && (target.maxX <= window.minX || target.minX >= window.maxX)
            let upward = target.isNull || target.minY >= window.midY
            let start = origin.withOffset(CGVector(dx: horizontal ? frame.midX : frame.minX + frame.width * 0.03, dy: frame.midY))
            let end = origin.withOffset(CGVector(dx: horizontal ? frame.minX + frame.width * (target.minX >= window.maxX ? 0.1 : 0.9) : frame.minX + frame.width * 0.03,
                                                dy: horizontal ? frame.midY : frame.minY + frame.height * (upward ? 0.1 : 0.9)))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
            if element.exists && element.isHittable { return }
        }
        assertUI(false, "滚动后目标应可触达：\(description)。存在：\(element.exists)，窗口：\(app.windows.firstMatch.frame)。\(focusedAccessibilitySnapshot(app, matching: [description, "Button", "Alert"]))")
    }

    @MainActor
    func interactionScrollFrame() -> CGRect? {
        guard let snapshot = try? app.snapshot() else { return nil }
        return (snapshot.snapshots(matching: .collectionView) + snapshot.snapshots(matching: .scrollView))
            .last(where: { $0.frame.height >= snapshot.frame.height / 2
                && snapshot.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })?.frame
    }

    @MainActor
    func waitUntil(_ predicate: NSPredicate, on element: UIElement, timeout: TimeInterval = 5) -> Bool {
        if predicate.evaluate(with: element) { return true }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            UITestSnapshotReader.invalidate()
            if predicate.evaluate(with: element) { return true }
        } while Date() < deadline
        return false
    }

    @MainActor
    func openSettings(_ route: String) {
        let mine = app.tabBars.buttons["我的"]
        if !mine.isSelected {
            mine.tapBriefly()
            assertUI(waitUntil(NSPredicate(format: "selected == true"), on: mine), "设置入口应先切换到个人页。")
        }
        let entry = app.buttons["settings.route.\(route)"]
        reveal(entry)
        entry.tapBriefly()
    }

    @MainActor
    func back() {
        guard let state = try? app.snapshot(),
              let bar = state.snapshots(matching: .navigationBar).last(where: { !$0.frame.isEmpty && state.frame.intersects($0.frame) }) else {
            assertUI(false, "返回操作应使用当前可见的导航栏。")
            return
        }
        let button = app.navigationBars[bar.identifier].buttons.firstMatch
        assertUI(button.isHittable, "当前导航栏的返回按钮应可交互。")
        button.tapBriefly()
    }

    @MainActor
    func textElement(_ text: String) -> UIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    func waitForValue(_ value: String, of element: UIElement) {
        if element.value as? String == value { return }
        assertUI(waitUntil(NSPredicate(format: "value == %@", value), on: element, timeout: 5), "交互应更新为\(value)，实际值：\(String(describing: element.value))。")
    }

    @MainActor @discardableResult
    func toggle(_ title: String) -> String {
        let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        reveal(control, description: title)
        let initial = control.value as? String
        control.tap()
        guard let value = control.value as? String else {
            assertUI(false, "开关操作后应保留当前设置页和可读数值：\(title)。")
            return ""
        }
        var updated = value
        if updated == initial {
            assertUI(waitUntil(NSPredicate(format: "value != %@", initial ?? ""), on: control, timeout: 5), "开关应改变状态：\(title)")
            updated = control.value as? String ?? ""
        }
        return updated
    }

    @MainActor
    func choose(_ title: String, option: String) {
        tap(title)
        tap(option)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        if row.label.hasSuffix(option) || row.value as? String == option { return }
        assertUI(waitUntil(NSPredicate(format: "label ENDSWITH %@ OR value == %@", option, option), on: row, timeout: 5), "选择应更新\(title)为\(option)。")
    }

    @MainActor
    func replaceText(_ text: String, in field: UIElement) {
        if UIElement.usesNativeInteraction || text.hasSuffix("\n") {
            replaceTextWithKeyboard(text, in: field)
            return
        }
        enterText(text, in: field)
        let secure = field.elementType == .secureTextField
        waitForValue(secure ? String(repeating: "•", count: text.count) : text, of: field)
    }

    @MainActor
    private func enterText(_ text: String, in field: UIElement) {
        assertUI(field.appears(timeout: 5), "输入操作应等待字段出现。")
        let started = ProcessInfo.processInfo.systemUptime
        let response = field.insertText(text)
        if response == "native" {
            field.press(forDuration: 0.01)
            assertUI(app.keyboards.firstMatch.appears(timeout: 5), "输入控件应完成系统键盘焦点切换。")
            guard let current = try? field.snapshot() else {
                assertUI(false, "输入字段应提供当前布局。")
                return
            }
            let result = UITestControlClient.request([
                "command": "input", "text": text,
                "x": String(Double(current.frame.midX)), "y": String(Double(current.frame.midY)),
            ], timeout: 5)
            assertUI(result == "entered", "文本应通过实际输入控件更新：\(result ?? "empty")。")
        } else {
            assertUI(response == "entered", "文本应通过实际输入控件更新：\(response ?? "empty")。")
        }
        print(String(format: "UI input replace: %.3f", ProcessInfo.processInfo.systemUptime - started))
    }

    @MainActor
    func fillVerificationCode(_ text: String, in field: UIElement) {
        if UIElement.usesNativeInteraction {
            guard let state = prepareInput(field) else { return }
            enterWithKeyboard(text, in: field, state: state)
        } else { enterText(text, in: field) }
    }

    @MainActor
    func replaceTextWithKeyboard(_ text: String, in field: UIElement) {
        guard let state = prepareInput(field) else { return }
        enterWithKeyboard(text, in: field, state: state)
        assertEnteredText(text, in: field, state: state)
    }

    @MainActor
    private func prepareInput(_ field: UIElement) -> (any XCUIElementSnapshot)? {
        assertUI(field.appears(timeout: 5), "输入操作应等待字段出现。")
        guard let state = try? field.snapshot() else {
            assertUI(false, "输入字段应提供可读的界面状态。")
            return nil
        }
        return state
    }

    @MainActor
    private func enterWithKeyboard(_ text: String, in field: UIElement, state: any XCUIElementSnapshot) {
        let value = state.value as? String ?? ""
        let empty = value.isEmpty || value == state.placeholderValue
        UIElement.beforeNativeTap?()
        field.native.tap()
        UITestSnapshotReader.invalidate()
        let keyboard = app.keyboards.firstMatch
        if !keyboard.exists {
            let nextKeyboard = UIElement(app.native.buttons["下一个键盘"])
            if nextKeyboard.exists { nextKeyboard.tapBriefly() }
            assertUI(keyboard.appears(timeout: 5), "文本输入应使用系统键盘。")
        }
        assertUI(app.buttons["keyboard.dismiss"].appears(timeout: 5), "系统输入应等待键盘附件完成安装。")
        if !empty {
            let selected = UITestControlClient.request(["command": "select-input"])
            assertUI(selected == "selected", "系统键盘替换应先选中输入框的完整文本。")
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            waitForValue("", of: field)
        }
        field.typeText(text)
    }

    @MainActor
    private func assertEnteredText(_ text: String, in field: UIElement, state: any XCUIElementSnapshot) {
        let expected = state.elementType == .secureTextField
            ? String(repeating: "•", count: text.count)
            : text.trimmingCharacters(in: .newlines)
        if field.value as? String == expected { return }
        assertUI(waitUntil(NSPredicate(format: "value == %@", expected), on: field, timeout: 5), "输入应完整替换文本，当前值：\(String(describing: field.value))。")
    }

    @MainActor
    func dismissKeyboard() {
        guard UITestControlClient.request(["command": "keyboard-state"]) != "hidden" else { return }
        if UIElement.usesNativeInteraction {
            let done = app.buttons["keyboard.dismiss"]
            assertUI(done.appears(timeout: 5), "系统键盘应呈现完成按钮。")
            done.press(forDuration: 0.01)
            assertUI(app.keyboards.firstMatch.disappears(timeout: 5), "原生完成按钮应关闭系统键盘。")
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = Date().addingTimeInterval(2)
        var result = UITestControlClient.request(["command": "finish-input"], timeout: 5)
        while result == "input toolbar missing" && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            result = UITestControlClient.request(["command": "finish-input"], timeout: 5)
        }
        assertUI(result == "finished", "键盘完成按钮应执行实际目标动作：\(result ?? "empty")。")
        assertUI(waitUntil(NSPredicate { _, _ in UITestControlClient.request(["command": "keyboard-state"]) == "hidden" }, on: app),
                 "完成输入后键盘应收起。")
        print(String(format: "UI keyboard finish: %.3f", ProcessInfo.processInfo.systemUptime - started))
    }

    @MainActor
    func closeAlertIfPresent() {
        guard app.alerts.firstMatch.exists else { return }
        let alert = app.alerts.firstMatch
        let close = alert.buttons["知道了"]
        assertUI(close.appears(timeout: 5), "提示应展示明确的“知道了”关闭动作。")
        close.tapBriefly()
        assertUI(alert.disappears(timeout: 5), "关闭提示应恢复页面交互。")
    }

    @MainActor
    func addCustomSchedule(_ titleText: String, in application: UIElement) {
        let addContent = application.buttons["schedule.add-content"]
        assertUI(addContent.appears(timeout: 10), "课表页应展示添加内容入口。")
        assertUI(
            addContent.isHittable,
            "添加入口应处于可点击位置。frame=\(addContent.frame); \(focusedAccessibilitySnapshot(application, matching: ["Window", "Alert", "Sheet", "Menu", "添加", "课表", "保存", "密码", "之后", "稍后", "现在"]))"
        )
        addContent.tapBriefly()

        let addSchedule = application.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "添加日程"))
            .firstMatch
        assertUI(
            addSchedule.appears(timeout: 5),
            "添加菜单应展示自定义日程操作。\(focusedAccessibilitySnapshot(application, matching: ["添加", "日程"]))"
        )
        addSchedule.tapBriefly()

        let title = application.textFields["schedule.custom.title"]
        assertUI(title.appears(timeout: 5), "自定义日程面板应展示标题输入框。")
        replaceText(titleText, in: title)
        dismissKeyboard()

        let save = application.buttons["schedule.custom.save"]
        assertUI(save.appears(timeout: 5), "自定义日程面板应展示保存操作。")
        tapHeader(save)
        let savedSchedule = application.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", titleText))
            .firstMatch
        assertUI(
            savedSchedule.appears(timeout: 10),
            "保存后课表应展示新建的自定义日程。\(focusedAccessibilitySnapshot(application, matching: [titleText, "保存", "确定", "日程", "课表"]))"
        )
    }

    @MainActor
    func assertMainTabsRemainAccessible(style: String) {
        let window = app.windows.firstMatch
        assertUI(window.exists, "辅助功能大字号应展示主窗口。")
        let windowFrame = window.frame
        for identifier in ["日程", "地图", "成绩", "话廊", "我的"] {
            let tab = app.tabBars.buttons[identifier]
            assertUI(tab.appears(timeout: 10), "辅助功能大字号下主 Tab 应可见：\(identifier)")
            tab.tapBriefly()
            guard let state = try? tab.snapshot() else {
                assertUI(false, "辅助功能大字号下 Tab 应提供可读的界面状态：\(identifier)。")
                return
            }
            assertUI(state.isSelected, "辅助功能大字号下点按后应选中对应 Tab：\(identifier)")
            if identifier == "话廊" {
                let offlineAlert = app.alerts["加载话廊失败"]
                assertUI(offlineAlert.appears(timeout: 10), "离线话廊请求应展示失败提示。")
                offlineAlert.buttons["知道了"].tapBriefly()
            }
            let tabFrame = state.frame
            let tabIsHittable = tab.native.isHittable
            let tabLabel = state.label
            assertUI(
                tabIsHittable && windowFrame.contains(tabFrame) && tabLabel.count > 0,
                "辅助功能大字号下 Tab 应保持可见、可触达并具有名称：\(identifier)；window=\(windowFrame)，tab=\(tabFrame)，hittable=\(tabIsHittable)，label=\(tabLabel)"
            )
            let contentTarget: UIElement?
            let contentDescription: String
            switch identifier {
            case "日程":
                contentTarget = app.descendants(matching: .any)
                    .matching(identifier: "schedule.blank-context-menu")
                    .firstMatch
                contentDescription = "课表空白操作区"
            case "成绩":
                contentTarget = app.buttons["score.query"]
                contentDescription = "成绩查询操作"
            case "我的":
                contentTarget = app.buttons["settings.route.account"]
                contentDescription = "账号设置入口"
            default:
                contentTarget = nil
                contentDescription = ""
            }
            if let contentTarget {
                assertUI(
                    contentTarget.appears(timeout: 10),
                    "辅助功能大字号与\(style)外观下应展示\(contentDescription)"
                )
                let contentFrame = contentTarget.frame
                assertUI(
                    contentTarget.native.isHittable && windowFrame.contains(contentFrame),
                    "\(contentDescription)应位于可见窗口且保持可触达：\(contentFrame)"
                )
            }
        }
    }

    @MainActor
    func signIn(_ application: UIElement, studentID inputStudentID: String = "ui-test-student") {
        let studentID = application.textFields["login.student-id"]
        let password = application.secureTextFields["login.password"]
        let submit = application.buttons["login.submit"]
        assertUI(studentID.appears(timeout: 10), "测试启动后应展示登录页。")

        replaceText(inputStudentID, in: studentID)
        replaceText("ui-test-password", in: password)
        assertUI(submit.isEnabled, "完整填写账号信息后，登录按钮应启用。")
        dismissKeyboard()
        submit.tapBriefly()
        dismissCredentialSavePrompt(in: application)
        assertUI(
            application.tabBars.buttons["日程"].appears(timeout: 10),
            "登录后应进入日程页。"
        )
        let scheduleTab = application.tabBars.buttons["日程"]
        if !scheduleTab.isSelected { scheduleTab.tapBriefly() }
        let scheduleReady = application.descendants(matching: .any)
            .matching(identifier: "schedule.blank-context-menu")
            .firstMatch
        assertUI(scheduleReady.appears(timeout: 10), "日程缓存与课表网格应完成首屏加载。")
    }

    @MainActor
    func dismissCredentialSavePrompt(in application: UIElement) {
        let prompt = application.sheets["保存密码？"]
        guard prompt.exists else { return }
        let nonSavingActions = ["取消", "不保存", "稍后", "暂不", "以后", "以后再说", "稍后再说", "关闭"]
        let buttons = prompt.buttons.allElementsBoundByIndex
        guard let dismissAction = buttons.first(where: { nonSavingActions.contains($0.label) }) else {
            let labels = buttons.map(\.label).joined(separator: "、")
            assertUI(false, "系统密码提示应提供安全关闭操作。按钮：\(labels)")
            return
        }
        dismissAction.tapBriefly()
        assertUI(!prompt.exists, "合成测试凭据的系统保存提示应自动收起。")
    }

    @MainActor
    func assertUI(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !condition() else { return }
        var diagnostics = ""
        let application = app
        let state = application.state
        diagnostics = "App 运行状态：\(state.rawValue)。"
        if state == .runningForeground {
            let description = application.native.debugDescription
            let hierarchy = XCTAttachment(string: description)
            hierarchy.name = "失败时的界面元素树"
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: application.screenshot())
            screenshot.name = "失败时的界面截图"
            add(screenshot)
            diagnostics += focusedAccessibilitySnapshot(description, matching: ["Alert", "NavigationBar", "TextField"])
        }
        XCTFail("\(message()) \(diagnostics)", file: file, line: line)
    }

    @MainActor
    func assertInteractiveLabelIsColored(_ title: String) {
        let label = app.staticTexts[title]
        assertUI(label.appears(timeout: 5), "交互行应展示左侧标题：\(title)")
        guard let screenshot = app.screenshot().image.cgImage else {
            assertUI(false, "标题颜色验收应获取截图像素。")
            return
        }
        let window = app.windows.firstMatch.frame
        let scale = CGFloat(screenshot.width) / window.width
        let bounds = label.frame
        let rectangle = CGRect(x: (bounds.minX - window.minX) * scale, y: (bounds.minY - window.minY) * scale,
                               width: bounds.width * scale, height: bounds.height * scale).integral
        guard let glyphs = screenshot.cropping(to: rectangle) else {
            assertUI(false, "左侧标题应位于可见截图中：\(title)")
            return
        }
        let width = glyphs.width
        let height = glyphs.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colored = pixels.withUnsafeMutableBytes { bytes -> Int in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                assertUI(false, "标题颜色验收应创建像素绘制上下文。")
                return 0
            }
            context.draw(glyphs, in: CGRect(x: 0, y: 0, width: width, height: height))
            return stride(from: 0, to: bytes.count, by: 4).filter { offset in
                let channels = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
                return max(channels[0], max(channels[1], channels[2])) - min(channels[0], min(channels[1], channels[2])) > 50
            }.count
        }
        assertUI(colored >= 10, "\(title)的左侧字形应包含页面主题色或警示色，当前彩色像素：\(colored)。")
    }

    @MainActor
    @nonobjc func focusedAccessibilitySnapshot(
        _ application: UIElement,
        matching terms: [String]
    ) -> String {
        focusedAccessibilitySnapshot(application.native.debugDescription, matching: terms)
    }

    @nonobjc func focusedAccessibilitySnapshot(_ description: String, matching terms: [String]) -> String {
        let lines = description.split(separator: "\n")
        var seen = Set<Substring>()
        let matches = terms.flatMap { term in
            lines.filter { $0.contains(term) && seen.insert($0).inserted }
        }.prefix(24)
        return matches.isEmpty ? "界面元素树中未检索到目标文案。" : matches.joined(separator: " | ")
    }

    @MainActor
    func configureApp(
        resetStorage: Bool,
        account: String? = "ui-test-student",
        accessibilityTextSize: Bool = false,
        userInterfaceStyle: String? = nil,
        ddlFixture: String? = nil,
        content: Bool = false,
        animations: Bool = false,
        nativeInteraction: Bool = true,
        school: Bool = false,
        media: Bool = false,
        failureOnce: Bool = false,
        update: String? = nil,
        schoolSMS: Bool = false,
        initialTab: String = "schedule",
        initialSettings: String? = nil
    ) -> UIElement {
        let started = ProcessInfo.processInfo.systemUptime
        defer { print(String(format: "UI scene preparation: %.3f", ProcessInfo.processInfo.systemUptime - started)) }
        continueAfterFailure = false
        UIElement.usesNativeInteraction = nativeInteraction
        let application = Self.sessionApplication ?? XCUIApplication()
        application.launchEnvironment = [:]
        application.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if accessibilityTextSize {
            application.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityL",
            ]
        }
        if let userInterfaceStyle {
            application.launchArguments += ["-UIUserInterfaceStyle", userInterfaceStyle]
        }
        application.launchEnvironment["BIT101_UI_TEST_LARGE_TEXT"] = accessibilityTextSize ? "1" : "0"
        application.launchEnvironment["BIT101_UI_TEST_STYLE"] = userInterfaceStyle
        application.launchEnvironment["BIT101_UI_TESTING"] = "1"
        application.launchEnvironment["BIT101_UI_TEST_CASE"] = name
        application.launchEnvironment["BIT101_UI_TEST_TAB"] = initialTab
        application.launchEnvironment["BIT101_UI_TEST_SETTINGS"] = initialSettings
        application.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        application.launchEnvironment["BIT101_UI_TEST_CONTENT"] = content ? "1" : "0"
        application.launchEnvironment["BIT101_UI_TEST_ANIMATIONS"] = animations ? "1" : "0"
        application.launchEnvironment["BIT101_UI_TEST_SCHOOL"] = school ? "1" : "0"
        application.launchEnvironment["BIT101_UI_TEST_MEDIA"] = media ? "1" : "0"
        application.launchEnvironment["BIT101_UI_TEST_FAILURE_ONCE"] = failureOnce ? "1" : "0"
        if let update { application.launchEnvironment["BIT101_UI_TEST_UPDATE"] = update }
        application.launchEnvironment["BIT101_UI_TEST_SCHOOL_SMS"] = schoolSMS ? "1" : "0"
        application.launchEnvironment["BIT101_UI_TEST_RUN_ID"] = runIdentifier
        application.launchEnvironment["BIT101_UI_TEST_RESET_STORAGE"] = resetStorage ? "1" : "0"
        if let ddlFixture { application.launchEnvironment["BIT101_UI_TEST_DDL_FIXTURE"] = ddlFixture }
        if resetStorage, let account {
            application.launchEnvironment["BIT101_UI_TEST_ACCOUNT"] = account
        }
        app = UIElement(application, path: [])
        UITestSnapshotReader.application = application
        UITestSnapshotReader.invalidate()
        UIElement.beforeNativeTap = { [weak self] in
            self?.dismissNotificationBanner()
            _ = UITestControlClient.request(["command": "observe"])
        }
        var expectedScene: String?
        if Self.sessionApplication == nil {
            application.launch()
            Self.sessionApplication = application
        } else {
            let state = application.state
            assertUI(state == .runningForeground || state == .runningBackground || state == .runningBackgroundSuspended,
                     "场景切换应复用持续运行的原 App 进程。")
            if state != .runningForeground { application.activate() }
            let response = UITestControlClient.request(application.launchEnvironment)
            assertUI(response?.hasPrefix("\(Self.sessionProcess ?? ""):") == true, "配置响应应来自原 App 进程：\(response ?? "empty")。")
            assertUI(response != Self.sessionScene, "场景配置应推进页面版本。")
            expectedScene = response
        }
        let settingsTitles = ["calendar": "课程表设置", "ddl": "DDL设置", "gallery": "话廊设置", "account": "账号设置", "about": "关于"]
        let tabTitles = ["gallery": "话廊", "map": "地图", "home": "成绩", "mine": "我的"]
        let initialElement: UIElement
        let checksSelectedTab: Bool
        if let initialSettings {
            guard let title = settingsTitles[initialSettings] else {
                assertUI(false, "初始设置页应使用已登记路由：\(initialSettings)。")
                return app
            }
            initialElement = app.navigationBars[title]
            checksSelectedTab = false
        } else if account == nil {
            initialElement = app.textFields["login.student-id"]
            checksSelectedTab = false
        } else if initialTab == "schedule" {
            initialElement = app.buttons["schedule.blank-context-menu"]
            checksSelectedTab = false
        } else if initialTab == "gallery" && (failureOnce || !content) {
            initialElement = app.alerts["加载话廊失败"]
            checksSelectedTab = false
        } else {
            guard let title = tabTitles[initialTab] else {
                assertUI(false, "初始分区应使用已登记路由：\(initialTab)。")
                return app
            }
            initialElement = app.tabBars.buttons[title]
            checksSelectedTab = true
        }
        let marker = app.descendants(matching: .any).matching(identifier: "ui-test.scene").firstMatch
        func renderedAttributes(_ element: UIElement) -> [String: Any]? {
            guard let path = element.path, let query = try? JSONSerialization.data(withJSONObject: path),
                  let response = UITestControlClient.request(["command": "query", "query": String(decoding: query, as: UTF8.self)], timeout: 5),
                  let elements = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [[String: Any]] else { return nil }
            return elements.first
        }
        let deadline = Date().addingTimeInterval(10)
        var identity: String?
        var lastSnapshot: (any XCUIElementSnapshot)?
        repeat {
            if let currentIdentity = renderedAttributes(marker)?["value"] as? String,
               expectedScene == nil || expectedScene == currentIdentity,
               let route = renderedAttributes(initialElement),
               !checksSelectedTab || route["selected"] as? Bool == true,
               let frame = renderedAttributes(app)?["frame"] as? [Double], frame.count == 4 {
                identity = currentIdentity
                UITestSnapshotReader.applicationOrigin = CGPoint(x: frame[0], y: frame[1])
                lastSnapshot = nil
                print("UI scene readiness: rendered")
                break
            }
            lastSnapshot = try? application.snapshot()
            if let snapshot = lastSnapshot,
               let scene = snapshot.firstSnapshot(where: { $0.identifier == "ui-test.scene" }),
               let currentIdentity = scene.value as? String,
               expectedScene == nil || expectedScene == currentIdentity {
                let ready: Bool
                if let initialSettings {
                    ready = snapshot.firstSnapshot {
                        $0.elementType == .navigationBar && $0.identifier == settingsTitles[initialSettings]
                    } != nil
                } else if account == nil {
                    ready = snapshot.firstSnapshot { $0.identifier == "login.student-id" } != nil
                } else if initialTab == "schedule" {
                    ready = snapshot.firstSnapshot { $0.identifier == "schedule.blank-context-menu" } != nil
                } else if initialTab == "gallery" && (failureOnce || !content) {
                    ready = snapshot.firstSnapshot { $0.elementType == .alert && $0.label == "加载话廊失败" } != nil
                } else {
                    ready = snapshot.firstSnapshot { $0.elementType == .tabBar }?.firstSnapshot {
                        $0.elementType == .button && $0.label == tabTitles[initialTab] && $0.isSelected
                    } != nil
                }
                if ready { identity = currentIdentity; break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        guard let identity else {
            assertUI(false, "同一界面快照中的场景身份与初始页面应完成加载：\(initialSettings ?? initialTab)。场景：\(String(describing: lastSnapshot?.firstSnapshot(where: { $0.identifier == "ui-test.scene" })?.value))，导航：\(lastSnapshot?.snapshots(matching: .tabBar).flatMap { $0.snapshots(matching: .button).map { "\($0.label)=\($0.isSelected)" } } ?? [])。")
            return app
        }
        if let lastSnapshot {
            UITestSnapshotReader.applicationOrigin = lastSnapshot.frame.origin
            UITestSnapshotReader.retain(lastSnapshot)
        }
        if Self.sessionProcess == nil {
            let process = String(identity.prefix(while: { $0 != ":" }))
            assertUI(!process.isEmpty, "场景身份应包含 App 进程。")
            Self.sessionProcess = process
            print("UI automation App process: \(process)")
        }
        Self.sessionScene = identity
        if animations {
            let report = UITestControlClient.request(["command": "coverage"])
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let speeds = report?["animationSpeeds"] as? [Double] ?? []
            assertUI(report?["animationsEnabled"] as? Bool == true && !speeds.isEmpty && speeds.allSatisfy { $0 == 1 },
                     "动画场景应启用系统动画并使用窗口默认速度。")
        }
        return app
    }
}
