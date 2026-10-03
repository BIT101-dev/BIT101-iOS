import XCTest
import CoreGraphics
import Network
import os

private nonisolated final class UITestControlReply: Sendable {
    private struct State {
        var content = Data()
        var result: String?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var message: String? {
        state.withLock { $0.result }
    }

    func receive(on connection: NWConnection, completion: @escaping @Sendable () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, complete, error in
            if append(data, error: error, complete: complete) {
                completion()
            } else if error == nil && !complete { receive(on: connection, completion: completion) }
        }
    }

    func append(_ data: Data?, error: NWError?, complete: Bool) -> Bool {
        state.withLock { state in
            if state.result != nil { return false }
            if let data { state.content.append(data) }
            if let end = state.content.firstIndex(of: 10) {
                state.result = String(decoding: state.content[..<end], as: UTF8.self)
                return true
            }
            if let error { state.result = error.localizedDescription; return true }
            if complete { state.result = "control channel closed"; return true }
            return false
        }
    }
}

@MainActor
extension XCUIElement {
    func tapBriefly() { press(forDuration: 0.01) }
}

@MainActor
extension XCUICoordinate {
    func tapBriefly() { press(forDuration: 0.01) }
}

@MainActor
extension XCUIElementSnapshot {
    func firstSnapshot(where matches: (any XCUIElementSnapshot) -> Bool) -> (any XCUIElementSnapshot)? {
        if matches(self) { return self }
        for child in children {
            if let match = child.firstSnapshot(where: matches) { return match }
        }
        return nil
    }
}

nonisolated class UIAutomationTestCase: XCTestCase {
    @MainActor var app: XCUIApplication!
    @MainActor private static var sessionApplication: XCUIApplication?
    @MainActor private static var sessionProcess: String?
    @MainActor private static var sessionScene: String?
    private let runIdentifier = "ui"

    @MainActor
    func assertSelectedWeek(_ week: Int) {
        let button = app.buttons["第\(week)周"]
        if button.isSelected { return }
        assertUI(waitUntil(NSPredicate(format: "selected == true"), on: button, timeout: 5), "周次选择应更新为第 \(week) 周。")
    }

    @MainActor
    func tap(_ title: String) {
        let exact = app.buttons.matching(NSPredicate(format: "label == %@", title))
        let exactExists = exact.firstMatch.exists
        let matches = exactExists ? exact : app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title))
        let button = matches.firstMatch
        if exactExists || button.exists {
            if button.isHittable {
                button.tapBriefly()
                return
            }
            if let visible = matches.allElementsBoundByAccessibilityElement.first(where: { $0.isHittable }) {
                visible.tapBriefly()
                return
            }
        }
        reveal(button, description: title)
        button.tapBriefly()
    }

    @MainActor
    func reveal(_ element: XCUIElement, description: String = "交互控件") {
        if element.exists && element.isHittable { return }
        let window = app.windows.firstMatch.frame
        let scroll: XCUIElement = interactionScrollArea() ?? app
        for _ in 0..<8 {
            let upward = !element.exists || element.frame.minY >= window.midY
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: upward ? 0.1 : 0.9))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
            if element.exists && element.isHittable { return }
        }
        assertUI(false, "滚动后目标应可触达：\(description)。存在：\(element.exists)，窗口：\(app.windows.firstMatch.frame)。\(focusedAccessibilitySnapshot(app, matching: [description, "Button", "Alert"]))")
    }

    @MainActor
    func interactionScrollArea() -> XCUIElement? {
        let types = [Int(XCUIElement.ElementType.collectionView.rawValue), Int(XCUIElement.ElementType.scrollView.rawValue)]
        let minimumHeight = app.frame.height / 2
        return app.descendants(matching: .any).matching(NSPredicate(format: "elementType IN %@", types))
            .allElementsBoundByAccessibilityElement.last(where: { $0.frame.height >= minimumHeight && $0.isHittable })
    }

    @MainActor
    func waitUntil(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        if predicate.evaluate(with: element) { return true }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
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
        let bar = app.navigationBars.allElementsBoundByAccessibilityElement.last(where: { $0.isHittable })
        assertUI(bar != nil, "返回操作应使用当前可交互的导航栏。")
        bar!.buttons.element(boundBy: 0).tapBriefly()
    }

    @MainActor
    func textElement(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    func waitForValue(_ value: String, of element: XCUIElement) {
        if element.value as? String == value { return }
        assertUI(waitUntil(NSPredicate(format: "value == %@", value), on: element, timeout: 5), "交互应更新为\(value)，实际值：\(String(describing: element.value))。")
    }

    @MainActor @discardableResult
    func toggle(_ title: String) -> String {
        let control = app.switches.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.switches.firstMatch
        reveal(control, description: title)
        let initial = control.value as? String
        control.tap()
        assertUI(control.appears(timeout: 5), "开关操作后应保留当前设置页：\(title)。")
        if control.value as? String == initial {
            assertUI(waitUntil(NSPredicate(format: "value != %@", initial ?? ""), on: control, timeout: 5), "开关应改变状态：\(title)")
        }
        return control.value as? String ?? ""
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
    func replaceText(_ text: String, in field: XCUIElement) {
        assertUI(field.appears(timeout: 5), "输入操作应等待字段出现。")
        guard let state = try? field.snapshot() else {
            assertUI(false, "输入字段应提供可读的界面状态。")
            return
        }
        reveal(field, description: state.placeholderValue ?? "文本输入")
        let value = state.value as? String ?? ""
        let empty = value.isEmpty || value == state.placeholderValue
        if empty || state.elementType == .textView {
            field.tapBriefly()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.9)).tapBriefly()
        }
        let nextKeyboard = app.buttons["下一个键盘"]
        if !app.keyboards.firstMatch.exists && nextKeyboard.exists {
            nextKeyboard.tapBriefly()
        }
        assertUI(app.keyboards.firstMatch.appears(timeout: 5), "文本输入应使用系统键盘。")
        var deletion = ""
        if !empty {
            if state.elementType == .textView {
                field.typeKey("a", modifierFlags: .command)
                deletion = XCUIKeyboardKey.delete.rawValue
            } else {
                deletion = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)
            }
        }
        field.typeText(deletion + text)
        let expected = state.elementType == .secureTextField
            ? String(repeating: "•", count: text.count)
            : text.trimmingCharacters(in: .newlines)
        if field.value as? String == expected { return }
        assertUI(waitUntil(NSPredicate(format: "value == %@", expected), on: field, timeout: 5), "输入应完整替换文本，当前值：\(String(describing: field.value))。")
    }

    @MainActor
    func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let button = app.buttons["keyboard.dismiss"]
        assertUI(button.appears(timeout: 5), "键盘应展示完成操作。")
        button.tapBriefly()
        if app.keyboards.firstMatch.exists {
            assertUI(waitUntil(NSPredicate(format: "exists == false"), on: app.keyboards.firstMatch, timeout: 5), "完成输入后键盘应收起。")
        }
    }

    @MainActor
    func closeAlertIfPresent() {
        guard app.alerts.firstMatch.exists else { return }
        let alert = app.alerts.firstMatch
        let close = alert.buttons["知道了"]
        if close.exists { close.tapBriefly() } else { alert.buttons.element(boundBy: 0).tapBriefly() }
        assertUI(alert.disappears(timeout: 5), "关闭提示应恢复页面交互。")
    }

    @MainActor
    func addCustomSchedule(_ titleText: String, in application: XCUIApplication) {
        let addContent = application.buttons["schedule.add-content"]
        assertUI(addContent.appears(timeout: 10), "课表页应展示添加内容入口。")
        assertUI(
            addContent.isHittable,
            "添加入口应处于可点击位置。frame=\(addContent.frame); \(focusedAccessibilitySnapshot(application, matching: ["Window", "Alert", "Sheet", "Menu", "添加", "课表", "保存", "密码", "之后", "稍后", "现在"]))"
        )
        addContent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapBriefly()

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
        title.tapBriefly()
        title.typeText("\(titleText)\n")

        let save = application.buttons["schedule.custom.save"]
        assertUI(save.appears(timeout: 5), "自定义日程面板应展示保存操作。")
        save.tapBriefly()
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
        for identifier in ["日程", "地图", "成绩", "话廊", "我的"] {
            let tab = app.tabBars.buttons[identifier]
            assertUI(tab.appears(timeout: 10), "辅助功能大字号下主 Tab 应可见：\(identifier)")
            tab.tapBriefly()
            assertUI(tab.isSelected, "辅助功能大字号下点按后应选中对应 Tab：\(identifier)")
            if identifier == "话廊" {
                let offlineAlert = app.alerts["加载话廊失败"]
                assertUI(offlineAlert.appears(timeout: 10), "离线话廊请求应展示失败提示。")
                offlineAlert.buttons["知道了"].tapBriefly()
            }
            let tabFrame = tab.frame
            let windowFrame = window.frame
            let tabIsHittable = tab.isHittable
            let tabLabel = tab.label
            assertUI(
                window.exists && tabIsHittable && windowFrame.contains(tabFrame) && tabLabel.count > 0,
                "辅助功能大字号下 Tab 应保持可见、可触达并具有名称：\(identifier)；window=\(windowFrame)，tab=\(tabFrame)，hittable=\(tabIsHittable)，label=\(tabLabel)"
            )
            let contentTarget: XCUIElement?
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
                    contentTarget.isHittable && windowFrame.contains(contentFrame),
                    "\(contentDescription)应位于可见窗口且保持可触达：\(contentFrame)"
                )
            }
        }
    }

    @MainActor
    func signIn(_ application: XCUIApplication, studentID inputStudentID: String = "ui-test-student") {
        let studentID = application.textFields["login.student-id"]
        let password = application.secureTextFields["login.password"]
        let submit = application.buttons["login.submit"]
        assertUI(studentID.appears(timeout: 10), "测试启动后应展示登录页。")

        replaceAccount(inputStudentID, in: studentID)
        studentID.typeText("\n")
        password.typeText("ui-test-password")
        assertUI(submit.isEnabled, "完整填写账号信息后，登录按钮应启用。")
        password.typeText("\n")
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
    func replaceAccount(_ value: String, in field: XCUIElement) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tapBriefly()
        let existingValue = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingValue.count) + value)
        assertUI(field.value as? String == value, "账号输入框应完整替换为指定测试账号。")
    }

    @MainActor
    func dismissCredentialSavePrompt(in application: XCUIApplication) {
        let prompt = application.sheets["保存密码？"]
        guard prompt.exists else { return }
        let nonSavingActions = ["取消", "不保存", "稍后", "暂不", "以后", "以后再说", "稍后再说", "关闭"]
        let buttons = prompt.buttons.allElementsBoundByAccessibilityElement
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
        if let application = app {
            let description = application.debugDescription
            let hierarchy = XCTAttachment(string: description)
            hierarchy.name = "失败时的界面元素树"
            add(hierarchy)
            if application.state == .runningForeground {
                let screenshot = XCTAttachment(screenshot: application.screenshot())
                screenshot.name = "失败时的界面截图"
                add(screenshot)
            }
            diagnostics = focusedAccessibilitySnapshot(description, matching: ["Alert", "NavigationBar", "TextField"])
        }
        XCTFail("\(message()) \(diagnostics)", file: file, line: line)
    }

    @MainActor
    func assertInteractiveLabelIsColored(_ title: String) {
        let label = app.staticTexts[title]
        assertUI(label.appears(timeout: 5), "交互行应展示左侧标题：\(title)")
        let screenshot = app.screenshot().image.cgImage!
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
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(glyphs, in: CGRect(x: 0, y: 0, width: width, height: height))
            return stride(from: 0, to: bytes.count, by: 4).filter { offset in
                let channels = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
                return channels.max()! - channels.min()! > 50
            }.count
        }
        assertUI(colored >= 10, "\(title)的左侧字形应包含页面主题色或警示色，当前彩色像素：\(colored)。")
    }

    @MainActor
    @nonobjc func focusedAccessibilitySnapshot(
        _ application: XCUIApplication,
        matching terms: [String]
    ) -> String {
        focusedAccessibilitySnapshot(application.debugDescription, matching: terms)
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
        school: Bool = false,
        media: Bool = false,
        failureOnce: Bool = false,
        update: String? = nil,
        schoolSMS: Bool = false,
        initialTab: String = "schedule",
        initialSettings: String? = nil
    ) -> XCUIApplication {
        let started = ProcessInfo.processInfo.systemUptime
        defer { print(String(format: "UI scene preparation: %.3f", ProcessInfo.processInfo.systemUptime - started)) }
        continueAfterFailure = false
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
        app = application
        var expectedScene: String?
        if Self.sessionApplication == nil {
            application.launch()
            Self.sessionApplication = application
        } else {
            if application.state != .runningForeground { application.activate() }
            let connection = NWConnection(host: "127.0.0.1", port: 19101, using: .tcp)
            let response = UITestControlReply()
            let received = XCTestExpectation(description: "进程内场景配置")
            let payload = try! JSONEncoder().encode(application.launchEnvironment) + Data([10])
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if response.append(nil, error: error, complete: false) { received.fulfill() }
                    })
                } else if case let .failed(error) = state {
                    if response.append(nil, error: error, complete: false) { received.fulfill() }
                }
            }
            connection.start(queue: DispatchQueue(label: "BIT101.UITestControlClient"))
            response.receive(on: connection) { received.fulfill() }
            assertUI(XCTWaiter.wait(for: [received], timeout: 10) == .completed, "场景配置应收到本机响应。")
            connection.cancel()
            assertUI(response.message?.hasPrefix("\(Self.sessionProcess ?? ""):") == true, "配置响应应来自原 App 进程：\(response.message ?? "empty")。")
            assertUI(response.message != Self.sessionScene, "场景配置应推进页面版本。")
            expectedScene = response.message
        }
        let settingsTitles = ["calendar": "课程表设置", "ddl": "DDL设置", "gallery": "话廊设置", "account": "账号设置", "about": "关于"]
        let tabTitles = ["gallery": "话廊", "map": "地图", "home": "成绩", "mine": "我的"]
        let deadline = Date().addingTimeInterval(10)
        var identity: String?
        repeat {
            if let snapshot = try? application.snapshot(),
               let scene = snapshot.firstSnapshot(where: { $0.identifier == "ui-test.scene" }),
               let currentIdentity = scene.value as? String,
               expectedScene == nil || expectedScene == currentIdentity {
                let ready: Bool
                if let initialSettings {
                    ready = snapshot.firstSnapshot {
                        $0.elementType == .navigationBar && $0.identifier == settingsTitles[initialSettings]!
                    } != nil
                } else if account == nil {
                    ready = snapshot.firstSnapshot { $0.identifier == "login.student-id" } != nil
                } else if initialTab == "schedule" {
                    ready = snapshot.firstSnapshot { $0.identifier == "schedule.blank-context-menu" } != nil
                } else {
                    ready = snapshot.firstSnapshot { $0.elementType == .tabBar }?.firstSnapshot {
                        $0.elementType == .button && $0.label == tabTitles[initialTab]! && $0.isSelected
                    } != nil
                }
                if ready { identity = currentIdentity; break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        assertUI(identity != nil, "同一界面快照中的场景身份与初始页面应完成加载：\(initialSettings ?? initialTab)。")
        if Self.sessionProcess == nil {
            let process = identity!.components(separatedBy: ":").first!
            Self.sessionProcess = process
            print("UI automation App process: \(process)")
        }
        Self.sessionScene = identity
        return application
    }
}

nonisolated final class LoginAndScheduleUITests: UIAutomationTestCase {
    @MainActor
    func testScheduleWeekButtonsAndSectionSwipes() {
        app = configureApp(resetStorage: true)
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
        app.segmentedControls.buttons.element(boundBy: 0).tapBriefly()
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
        app.segmentedControls.buttons["放假"].tapBriefly()
        tap("确定")
        assertUI(app.alerts["确认放假"].appears(timeout: 5), "放假应展示确认。")
        app.alerts.buttons["取消"].tapBriefly()
        app.segmentedControls.buttons["调至某天"].tapBriefly()
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
        let initial = timeline.value as? String
        timeline.pinch(withScale: 1.5, velocity: 1)
        assertUI(waitUntil(NSPredicate(format: "value != %@", initial ?? ""), on: timeline, timeout: 5), "双指展开应放大时间轴，当前值：\(String(describing: timeline.value))，\(timeline.label)。")
        let enlarged = timeline.value as? String
        timeline.swipeUp()
        timeline.swipeDown()
        timeline.pinch(withScale: 0.8, velocity: -1)
        assertUI(timeline.value as? String != enlarged, "双指收拢应缩小时间轴。")
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
        replaceText("invalid", in: editor)
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
            toggle(title)
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
        tap("滞留天数")
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "10 天")
        tap("取消")
        tap("滞留天数")
        assertUI(app.pickerWheels.firstMatch.value as? String != "10 天", "取消应保留原值。")
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "5 天")
        tap("完成")
        app = configureApp(resetStorage: false, initialSettings: "ddl")
        tap("变色天数")
        assertUI(app.pickerWheels.firstMatch.value as? String == "7 天", "重新装载应保留变色天数。")
        tap("取消")
        tap("滞留天数")
        assertUI(app.pickerWheels.firstMatch.value as? String == "5 天", "重新装载应保留滞留天数。")
        tap("取消")
    }


    @MainActor
    func testGallerySettingsValidationTogglesAndPersistence() {
        app = configureApp(resetStorage: true)
        openSettings("gallery")
        for title in ["隐藏机器人帖子", "隐藏匿名内容", "使用网页话廊"] { toggle(title) }
        let ids = app.textFields["屏蔽用户 UID（逗号分隔）"]
        ids.tapBriefly()
        ids.typeText("abc\n")
        assertUI(app.alerts["UID 格式错误"].appears(timeout: 5), "无效 UID 应给出校验提示。")
        closeAlertIfPresent()
        replaceText("12,34", in: ids)
        ids.typeText("\n")
        dismissKeyboard()
        app = configureApp(resetStorage: false, initialSettings: "gallery")
        assertUI(app.textFields["屏蔽用户 UID（逗号分隔）"].value as? String == "12,34", "重新装载应保留屏蔽 UID。")
        for title in ["隐藏机器人帖子", "隐藏匿名内容", "使用网页话廊"] { toggle(title) }
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
        replaceText("临时标签\n", in: app.textFields["自定义标签"])
        dismissKeyboard()
        tap("删除标签")
        assertUI(!app.textFields["自定义标签"].exists, "删除应移除自定义标签输入行。")
        toggle("匿名发布")
        toggle("公开显示")
        toggle("公开显示")
        replaceText("测试发布的话题\n", in: app.textFields["标题"])
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
        app.segmentedControls.buttons["文章"].tapBriefly()
        tap("发布文章")
        let paperComposer = app.navigationBars["发布文章"]
        for (title, text) in [("标题", "测试发布文章"), ("简介", "文章发布测试简介"), ("正文", "文章发布测试正文")] {
            replaceText(text, in: app.textFields[title])
            dismissKeyboard()
        }
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
        assertUI(textElement("文章发布测试正文").exists, "修改标题应保留完整正文。")
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
    func testPaperSearchDetailLikeAndComposer() {
        app = configureApp(resetStorage: true, content: true, initialTab: "gallery")
        app.segmentedControls.buttons["文章"].tapBriefly()
        assertUI(textElement("自动化测试文章").appears(timeout: 5), "文章分区应展示固定文章。")
        tap("搜索文章")
        let search = app.textFields.firstMatch
        search.tapBriefly()
        search.typeText("文章\n")
        tap("清除搜索")
        tap("取消")
        tap("自动化测试文章")
        assertUI(app.navigationBars["文章详情"].appears(timeout: 5), "文章行应打开详情。")
        tap("点赞文章")
        assertUI(app.buttons["取消文章点赞"].appears(timeout: 5), "文章点赞应更新状态。")
        tap("取消文章点赞")
        back()
        tap("发布文章")
        tap("发布")
        assertUI(app.alerts["发布失败"].appears(timeout: 5), "空文章应提示必填字段。")
        closeAlertIfPresent()
        assertUI(app.textFields["标题"].exists && app.textFields["简介"].exists, "文章编辑器应提供标题和简介。")
        toggle("匿名发布")
        tap("取消")
    }


    @MainActor
    func testSuggestionDraftRestoreAndDiscard() {
        app = configureApp(resetStorage: true, animations: true)
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
            dismissKeyboard()
        }
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
        tap("删除这门课")
        app.alerts.buttons["取消"].tapBriefly()
        assertUI(app.buttons["删除这门课"].exists, "取消删除应保留课程详情。")
        tap("删除这门课")
        app.alerts.buttons["删除"].tapBriefly()
        assertUI(!course.exists, "确认删除应移除课程。")
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
    func testCourseSearchHistoryLikeAndRatingComposer() {
        app = configureApp(resetStorage: true, content: true, initialTab: "home")
        app.segmentedControls.buttons.element(boundBy: 1).tapBriefly()
        let search = app.textFields.firstMatch
        assertUI(search.appears(timeout: 5), "课程评价应提供搜索字段。")
        search.tapBriefly()
        search.typeText("测试\n")
        tap("自动化测试课程")
        assertUI(app.navigationBars["课程详情"].appears(timeout: 5), "课程搜索应打开详情。")
        tap("点赞课程")
        assertUI(app.buttons["取消课程点赞"].appears(timeout: 5), "课程点赞应更新操作。")
        tap("取消课程点赞")
        tap("评论课程")
        let field = app.textFields.firstMatch
        assertUI(field.appears(timeout: 5), "课程评论应展示输入字段。")
        tap("评分 3.5 星")
        field.tapBriefly()
        field.typeText("测试课程评价\n")
        dismissKeyboard()
        tap("发送")
        assertUI(waitUntil(NSPredicate(format: "exists == false"), on: app.buttons["发送"], timeout: 5), "提交成功后应关闭评价窗口。")
        reveal(textElement("测试课程评价"), description: "测试课程评价")
        assertUI(textElement("测试课程评价").appears(timeout: 5), "提交评价应更新评论区。")
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
        app.buttons["取消"].tapBriefly()
        app = configureApp(resetStorage: false)
        app.segmentedControls.buttons["DDL"].tapBriefly()
        let restored = app.buttons["ddl.done.eclass:ui"]
        assertUI(restored.appears(timeout: 5), "重新启动后应恢复课程中心作业。")
        assertUI(restored.value as? String == "已完成", "重新启动后应恢复完成状态。")
    }

    @MainActor
    func testDDLEmptyStateExplainsTheRetentionWindow() throws {
        app = configureApp(resetStorage: true, ddlFixture: "overdue")
        app.segmentedControls.buttons["DDL"].tapBriefly()
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
        app = configureApp(resetStorage: true, account: "ui-test-account-a")
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
