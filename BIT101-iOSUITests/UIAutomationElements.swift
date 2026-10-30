import XCTest
import CoreGraphics
import Network
import os

nonisolated enum UITestMainNavigation {
    static func labels(_ title: String) -> [String] {
        let expanded = ["日程": "日程 / DDL", "话廊": "话题"]
        return expanded[title].map { [title, $0] } ?? [title]
    }
}

nonisolated final class UITestControlReply: Sendable {
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
enum UITestControlClient {
    static var port: UInt16 {
        guard let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"],
              let suffix = UInt16(device.suffix(4), radix: 16) else { return 19101 }
        return 20000 + suffix % 40000
    }

    static func activate(_ parameters: [String: String], element: XCUIElement) {
        let result = request(parameters.merging(["command": "activate"]) { _, command in command }, timeout: 5)
        if result?.hasPrefix("native") == true {
            if let result, result != "native" { print("UI native control: \(result)") }
            UIElement.beforeNativeTap?()
            element.press(forDuration: 0.01)
            return
        }
        XCTAssertTrue(result == "activated" || result == "control", "UI 动作应由实际控件执行：\(parameters["label"] ?? "")。")
    }

    static func request(_ parameters: [String: String], timeout: TimeInterval = 10) -> String? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { XCTFail("UI 通道端口需要有效。"); return nil }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let response = UITestControlReply()
        let received = XCTestExpectation(description: "本机 UI 操作")
        let payload: Data
        do { payload = try JSONEncoder().encode(parameters) + Data([10]) }
        catch {
            XCTFail("UI 通道应编码请求参数：\(error.localizedDescription)。")
            return nil
        }
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
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: timeout), .completed,
                       "本机 UI 通道应完成请求：\(parameters["command"] ?? "scene")。")
        connection.cancel()
        if parameters["command"] == nil || ["activated", "control", "entered", "revealed", "finished", "selected"].contains(response.message ?? "") {
            UITestSnapshotReader.invalidate()
        }
        return response.message
    }
}

/// 相邻原生查询共用 XCTest 快照，界面操作和等待轮询刷新读取。
@MainActor
enum UITestSnapshotReader {
    static var application: XCUIApplication?
    static var applicationOrigin = CGPoint.zero
    private(set) static var generation = 0
    private static var cached: (any XCUIElementSnapshot)?
    static var liveQueries: [Data: [String: Any]] = [:]
    private static var queryMetrics: [String: [String: Double]] = [:]

    static func recordTiming(_ kind: String, since start: TimeInterval) {
        queryMetrics[kind, default: ["count": 0, "seconds": 0]]["count", default: 0] += 1
        queryMetrics[kind, default: [:]]["seconds", default: 0] += ProcessInfo.processInfo.systemUptime - start
    }

    static func printTimingSummary() {
        if let data = try? JSONSerialization.data(withJSONObject: queryMetrics, options: .sortedKeys) {
            print("UI query metrics: \(String(decoding: data, as: UTF8.self))")
        }
        queryMetrics.removeAll(keepingCapacity: true)
    }

    static func invalidate() { cached = nil; liveQueries.removeAll(keepingCapacity: true); generation += 1 }

    static func retain(_ snapshot: any XCUIElementSnapshot) { cached = snapshot }

    static func snapshot(of application: XCUIApplication) throws -> any XCUIElementSnapshot {
        if let cached { return cached }
        let started = ProcessInfo.processInfo.systemUptime
        let snapshot = try application.snapshot()
        cached = snapshot
        recordTiming("sharedSnapshots", since: started)
        return snapshot
    }

    static func attributes(_ path: [[String: String]], loading: Bool = true) -> [String: Any]? {
        if cached == nil, loading, let application { _ = try? snapshot(of: application) }
        guard let cached else { return nil }
        func attributes(_ element: any XCUIElementSnapshot) -> [String: Any] {
            var result: [String: Any] = [
                "exists": true, "identifier": element.identifier, "label": element.label,
                "elementType": Int(element.elementType.rawValue), "enabled": element.isEnabled,
                "selected": element.isSelected, "placeholderValue": element.placeholderValue ?? "",
                "frame": [Double(element.frame.minX), Double(element.frame.minY), Double(element.frame.width), Double(element.frame.height)],
            ]
            if let value = element.value { result["value"] = value }
            return result
        }
        func descendants(_ element: any XCUIElementSnapshot) -> [any XCUIElementSnapshot] {
            element.children.flatMap { [$0] + descendants($0) }
        }
        var elements = [cached]
        for step in path {
            if let type = step["type"].flatMap(UInt.init) {
                elements = elements.flatMap(descendants).filter { type == 0 || $0.elementType.rawValue == type }
            } else if let format = step["predicate"] {
                let predicate = NSPredicate(format: format)
                elements = elements.filter { predicate.evaluate(with: attributes($0)) }
            } else if step["first"] != nil { elements = Array(elements.prefix(1)) }
        }
        return elements.first.map(attributes)
    }
}

/// 普通页面读取当前渲染的无障碍树，平台控件沿用 XCTest 查询和手势。
@MainActor
final class UIElement: NSObject {
    static var beforeNativeTap: (() -> Void)?
    static var usesNativeInteraction = true
    let native: XCUIElement
    let path: [[String: String]]?
    private var capturedSnapshot: (any XCUIElementSnapshot)?
    private var capturedGeneration = -1

    init(_ native: XCUIElement, path: [[String: String]]? = nil) {
        self.native = native
        self.path = path
    }

    func attributes(renderedOnly: Bool = false) -> [String: Any]? {
        let started = ProcessInfo.processInfo.systemUptime
        guard let path else {
            guard let state = currentNativeSnapshot() else {
                return ["exists": false, "enabled": false, "selected": false,
                        "label": "", "identifier": "", "frame": [0.0, 0.0, 0.0, 0.0]]
            }
            var attributes: [String: Any] = [
                "exists": true, "identifier": state.identifier, "label": state.label,
                "elementType": Int(state.elementType.rawValue), "enabled": state.isEnabled, "selected": state.isSelected,
                "frame": [Double(state.frame.minX), Double(state.frame.minY), Double(state.frame.width), Double(state.frame.height)],
            ]
            if let value = state.value { attributes["value"] = value }
            return attributes
        }
        // 无筛选的 firstMatch 沿系统无障碍顺序读取。
        if path.last?["first"] != nil, !path.contains(where: { $0["predicate"] != nil }) {
            return UITestSnapshotReader.attributes(path)
        }
        if path.contains(where: { [18, 19, 38, 39, 42, 51, 57, 58].contains(Int($0["type"] ?? "") ?? -1)
            || ($0["predicate"] ?? "").contains("keyboard.dismiss") || ($0["predicate"] ?? "").contains("下一个键盘") }) {
            return UITestSnapshotReader.attributes(path)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: path, options: .sortedKeys) else { return nil }
        if let attributes = UITestSnapshotReader.liveQueries[data] { return attributes }
        guard
              let response = UITestControlClient.request(["command": "query", "query": String(decoding: data, as: UTF8.self)], timeout: 5),
              let elements = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [[String: Any]] else {
            return UITestSnapshotReader.attributes(path)
        }
        UITestSnapshotReader.recordTiming("liveQueries", since: started)
        if renderedOnly && elements.isEmpty { return ["exists": false] }
        if elements.isEmpty, path.contains(where: { [0, 1, 5, 7, 48].contains(Int($0["type"] ?? "") ?? -1) }) {
            return UITestSnapshotReader.attributes(path)
        }
        let attributes = elements.first ?? ["exists": false, "enabled": false, "selected": false, "hittable": false, "label": "", "identifier": ""]
        UITestSnapshotReader.liveQueries[data] = attributes
        return attributes
    }

    private func currentNativeSnapshot() -> (any XCUIElementSnapshot)? {
        if capturedGeneration == UITestSnapshotReader.generation { return capturedSnapshot }
        capturedSnapshot = native.exists ? try? native.snapshot() : nil
        capturedGeneration = UITestSnapshotReader.generation
        return capturedSnapshot
    }

    @objc var exists: Bool {
        guard let path else { return currentNativeSnapshot() != nil }
        if path.contains(where: { [18, 19, 21, 38, 39, 42, 51, 57, 58].contains(Int($0["type"] ?? "") ?? -1) }) {
            return UITestSnapshotReader.attributes(path, loading: false) != nil || native.exists
        }
        return attributes()?["exists"] as? Bool ?? native.exists
    }
    @objc var label: String { attributes()?["label"] as? String ?? native.label }
    @objc var identifier: String { attributes()?["identifier"] as? String ?? native.identifier }
    @objc var value: Any? {
        if let attributes = attributes() { return attributes["value"] }
        return native.value
    }
    @objc var isEnabled: Bool {
        attributes()?["enabled"] as? Bool ?? native.isEnabled
    }
    func assertDisabled(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let enabled = isEnabled
        XCTAssertFalse(enabled, message, file: file, line: line)
        guard !enabled else { return }
        _ = UITestControlClient.request(interactionIdentity.merging(["command": "state"]) { _, command in command })
    }
    @objc var isSelected: Bool { attributes()?["selected"] as? Bool ?? native.isSelected }
    @objc var isHittable: Bool { native.isHittable }
    var frame: CGRect {
        if let values = attributes()?["frame"] as? [Double], values.count == 4 {
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        return native.frame
    }
    var elementType: XCUIElement.ElementType {
        if let type = attributes()?["elementType"] as? Int, let value = XCUIElement.ElementType(rawValue: UInt(type)) { return value }
        return native.elementType
    }
    var state: XCUIApplication.State {
        guard let application = native as? XCUIApplication else {
            XCTFail("运行状态查询应使用 App 元素。")
            return .unknown
        }
        return application.state
    }
    func screenshot() -> XCUIScreenshot { native.screenshot() }
    func snapshot() throws -> any XCUIElementSnapshot {
        if let application = native as? XCUIApplication { return try UITestSnapshotReader.snapshot(of: application) }
        if path == nil, let state = currentNativeSnapshot() { return state }
        return try native.snapshot()
    }
    func activate() {
        guard let application = native as? XCUIApplication else {
            XCTFail("前台激活应使用 App 元素。")
            return
        }
        UITestSnapshotReader.invalidate()
        application.activate()
    }
    func coordinate(withNormalizedOffset offset: CGVector) -> UIAutomationCoordinate {
        if Self.usesNativeInteraction {
            let identity = interactionIdentity
            return UIAutomationCoordinate(native: native.coordinate(withNormalizedOffset: offset), identifier: identifier,
                                          label: label, type: Int(elementType.rawValue), scope: identity["scope"] ?? "", instance: identity["instance"] ?? "")
        }
        guard !(native is XCUIApplication), let application = UITestSnapshotReader.application else {
            return UIAutomationCoordinate(native: native.coordinate(withNormalizedOffset: offset))
        }
        let bounds = frame
        guard !bounds.isEmpty else { return UIAutomationCoordinate(native: native.coordinate(withNormalizedOffset: offset)) }
        let origin = UITestSnapshotReader.applicationOrigin
        return UIAutomationCoordinate(native: application.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: bounds.minX + bounds.width * offset.dx - origin.x,
                     dy: bounds.minY + bounds.height * offset.dy - origin.y)))
    }
    func press(forDuration duration: TimeInterval) {
        defer { UITestSnapshotReader.invalidate() }
        let identity = interactionIdentity
        Self.beforeNativeTap?()
        native.press(forDuration: duration)
        recordInteraction(identity, action: duration < 0.1 ? "tap" : "press")
    }
    func scrollGestureFrame(in bounds: CGRect) -> CGRect? {
        guard let response = UITestControlClient.request(["command": "safe-area"]),
              let safeArea = try? JSONDecoder().decode(CGRect.self, from: Data(response.utf8)) else {
            XCTFail("滚动定位应读取当前窗口的系统安全区。")
            return nil
        }
        let visible = bounds.intersection(safeArea)
        XCTAssertFalse(visible.isEmpty, "滚动区域应与窗口安全区相交。")
        return visible.isEmpty ? nil : visible
    }
    func swipeLeft() { performGesture("swipe") { native.swipeLeft() } }
    func swipeRight() { performGesture("swipe") { native.swipeRight() } }
    func swipeUp() { performGesture("swipe") { native.swipeUp() } }
    func swipeDown() { performGesture("swipe") { native.swipeDown() } }
    func dragScroll(vertical: Bool, towardEnd: Bool) {
        performGesture("swipe") {
            if vertical {
                if towardEnd { native.swipeUp() } else { native.swipeDown() }
            } else {
                if towardEnd { native.swipeLeft() } else { native.swipeRight() }
            }
        }
    }
    func pinch(withScale scale: CGFloat, velocity: CGFloat) { performGesture("pinch") { native.pinch(withScale: scale, velocity: velocity) } }
    func adjust(toPickerWheelValue value: String) { performGesture("selection") { native.adjust(toPickerWheelValue: value) } }
    private func performGesture(_ action: String, _ operation: () -> Void) {
        Self.beforeNativeTap?()
        let identity = interactionIdentity
        operation()
        UITestSnapshotReader.invalidate()
        recordInteraction(identity, action: action)
    }
    func typeText(_ text: String) {
        Self.beforeNativeTap?()
        defer { UITestSnapshotReader.invalidate() }
        let identity = interactionIdentity
        native.typeText(text)
        recordInteraction(identity)
    }

    private var interactionIdentity: [String: String] {
        let bounds = frame
        var identity = ["identifier": identifier, "label": label, "type": String(elementType.rawValue),
            "scope": UITestControlClient.request(["command": "observe"]) ?? "",
            "x": String(Double(bounds.minX)), "y": String(Double(bounds.minY)), "width": String(Double(bounds.width)), "height": String(Double(bounds.height))]
        identity["instance"] = attributes()?["instance"] as? String
            ?? UITestControlClient.request(identity.merging(["command": "identity"]) { _, command in command }) ?? ""
        if identity["instance"]?.isEmpty != false, !bounds.isEmpty {
            identity["enabled"] = isEnabled ? "1" : "0"
            identity["instance"] = UITestControlClient.request(identity.merging(["command": "native-observe"]) { _, command in command }) ?? ""
        }
        return identity
    }
    private func recordInteraction(_ identity: [String: String], action: String = "input") {
        _ = UITestControlClient.request(identity.merging(["command": "record", "action": action]) { _, command in command })
    }

    func performAccessibilityAction(named name: String) -> Bool {
        Self.beforeNativeTap?()
        defer { UITestSnapshotReader.invalidate() }
        guard let path, let data = try? JSONSerialization.data(withJSONObject: path) else { return false }
        return UITestControlClient.request(["command": "query-accessibility-action", "name": name,
            "query": String(decoding: data, as: UTF8.self)]) == "performed"
    }

    func pressReturnKey() {
        Self.beforeNativeTap?()
        let identity = interactionIdentity
        XCTAssertTrue(native.isHittable, "Return 默认动作应已完成原生弹窗布局。")
        native.typeKey(XCUIKeyboardKey.shift, modifierFlags: [])
        let title = native.label
        let deadline = Date().addingTimeInterval(5)
        var ready = false
        var keyboardState = "waiting"
        repeat {
            keyboardState = UITestControlClient.request(["command": "keyboard-state", "return-title": title]) ?? "empty"
            ready = keyboardState == "ready"
            if ready { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        XCTAssertTrue(ready, "原生弹窗应提供已启用的默认动作与 Return 按键命令：\(keyboardState)。")
        native.typeKey("\n", modifierFlags: [])
        recordInteraction(identity, action: "keyboard")
        UITestSnapshotReader.invalidate()
    }

    func tapBriefly(reveal: (() -> Void)? = nil) {
        if !Self.usesNativeInteraction { Self.beforeNativeTap?() }
        defer { UITestSnapshotReader.invalidate() }
        var preparedHittability: Bool?
        if let reveal {
            preparedHittability = isHittable
            if preparedHittability == false {
                reveal()
                preparedHittability = isHittable
            }
        }
        if Self.usesNativeInteraction {
            press(forDuration: 0.01)
            return
        }
        var actionPath = path
        if var query = path, let index = query.lastIndex(where: { $0["type"] == "0" }),
           attributes()?["elementType"] as? Int == 9 {
            query[index] = ["type": "9"]
            actionPath = query
        }
        if actionPath == nil || actionPath?.contains(where: { [0, 1, 49, 50, 52].contains(Int($0["type"] ?? "") ?? -1) }) == true {
            native.tapBriefly()
            return
        }
        if let actionPath, let data = try? JSONSerialization.data(withJSONObject: actionPath) {
            let response = UITestControlClient.request(["command": "query-activate", "query": String(decoding: data, as: UTF8.self),
                                                       "hittable": (preparedHittability ?? isHittable) ? "1" : "0", "label": label, "identifier": identifier], timeout: 5)
            if response == "activated" {
                return
            }
            if response == "control" {
                return
            }
            guard response == "native" else {
                XCTFail("控件动作应完成：\(response ?? "empty")。")
                return
            }
        }
        press(forDuration: 0.01)
    }
    func tap() {
        defer { UITestSnapshotReader.invalidate() }
        if Self.usesNativeInteraction || path == nil {
            Self.beforeNativeTap?()
            let identity = interactionIdentity
            native.tap()
            recordInteraction(identity, action: "tap")
        } else { tapBriefly() }
    }

    func insertText(_ text: String) -> String? {
        guard let path, let data = try? JSONSerialization.data(withJSONObject: path) else { return "native" }
        return UITestControlClient.request([
            "command": "query-input", "query": String(decoding: data, as: UTF8.self), "text": text,
        ], timeout: 5)
    }

    func revealInScrollView() -> String? {
        guard let path, let data = try? JSONSerialization.data(withJSONObject: path) else { return "native" }
        return UITestControlClient.request(["command": "query-reveal", "query": String(decoding: data, as: UTF8.self)], timeout: 5)
    }

    func descendants(matching type: XCUIElement.ElementType) -> UIElementQuery {
        let nestedSwitch = type == .switch && path?.contains(where: { $0["type"] == String(type.rawValue) }) == true
        return UIElementQuery(native: native.descendants(matching: type),
                              path: nestedSwitch ? nil : path.map { $0 + [["type": String(type.rawValue)]] })
    }
    var buttons: UIElementQuery { descendants(matching: .button) }
    var staticTexts: UIElementQuery { descendants(matching: .staticText) }
    var textFields: UIElementQuery { descendants(matching: .textField) }
    var secureTextFields: UIElementQuery { descendants(matching: .secureTextField) }
    var textViews: UIElementQuery { descendants(matching: .textView) }
    var steppers: UIElementQuery { descendants(matching: .stepper) }
    var switches: UIElementQuery { descendants(matching: .switch) }
    var navigationBars: UIElementQuery { descendants(matching: .navigationBar) }
    func mainTab(_ title: String) -> UIElement {
        let labels = UITestMainNavigation.labels(title)
        let query = native.buttons.matching(NSPredicate(format: "label IN %@", labels))
        guard let application = UITestSnapshotReader.application,
              let snapshot = try? application.snapshot() else {
            XCTFail("主导航查询需要当前应用的界面快照。")
            return UIElement(query.firstMatch)
        }
        let buttons = snapshot.snapshots(matching: .button)
        guard let map = buttons.first(where: { $0.identifier == "app.tab.map" }),
              let mine = buttons.first(where: { $0.identifier == "app.tab.mine" }) else {
            XCTFail("系统主导航应提供地图与个人页入口。")
            return UIElement(query.firstMatch)
        }
        let horizontal = abs(map.frame.midY - mine.frame.midY) <= 1
        let candidates = buttons.filter { labels.contains($0.label) }
        guard let index = candidates.firstIndex(where: {
            horizontal ? abs($0.frame.midY - map.frame.midY) <= 1 : abs($0.frame.midX - map.frame.midX) <= 1
        }) else { XCTFail("主导航应沿同一行或列呈现：\(title)。"); return UIElement(query.firstMatch) }
        let element = UIElement(query.element(boundBy: index))
        element.capturedSnapshot = candidates[index]
        element.capturedGeneration = UITestSnapshotReader.generation
        return element
    }
    func sectionTab(_ title: String) -> UIElement {
        let primaryTitle = ["课表": "日程 / DDL", "DDL": "日程 / DDL"][title] ?? title
        let primary = buttons.matching(NSPredicate(format: "label == %@", primaryTitle)).firstMatch
        return primary.isHittable ? primary : segmentedControls.buttons[title]
    }
    var segmentedControls: UIElementQuery { descendants(matching: .segmentedControl) }
    var collectionViews: UIElementQuery { descendants(matching: .collectionView) }
    var scrollViews: UIElementQuery { descendants(matching: .scrollView) }
    var otherElements: UIElementQuery { descendants(matching: .other) }
    var alerts: UIElementQuery { descendants(matching: .alert) }
    var sheets: UIElementQuery { descendants(matching: .sheet) }
    var popovers: UIElementQuery { descendants(matching: .popover) }
    var windows: UIElementQuery { descendants(matching: .window) }
    var keyboards: UIElementQuery { descendants(matching: .keyboard) }
    var pickerWheels: UIElementQuery { descendants(matching: .pickerWheel) }
    var datePickers: UIElementQuery { descendants(matching: .datePicker) }
    var links: UIElementQuery { descendants(matching: .link) }
    var maps: UIElementQuery { descendants(matching: .map) }
    var webViews: UIElementQuery { descendants(matching: .webView) }

    func appears(timeout: TimeInterval) -> Bool { waitForPresence(true, timeout: timeout) }
    func disappears(timeout: TimeInterval) -> Bool { waitForPresence(false, timeout: timeout) }
    private func waitForPresence(_ presence: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if exists == presence { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            UITestSnapshotReader.invalidate()
        } while Date() < deadline
        return false
    }
}

@MainActor
struct UIAutomationCoordinate {
    let native: XCUICoordinate
    var identifier = ""
    var label = ""
    var type = 0
    var scope = ""
    var instance = ""
    private func record(action: String) {
        if !identifier.isEmpty || !label.isEmpty {
            _ = UITestControlClient.request(["command": "record", "identifier": identifier, "label": label, "type": String(type), "scope": scope, "instance": instance, "action": action])
        }
        UITestSnapshotReader.invalidate()
    }
    func withOffset(_ offset: CGVector) -> Self { Self(native: native.withOffset(offset), identifier: identifier, label: label, type: type, scope: scope, instance: instance) }
    func tapBriefly() { UIElement.beforeNativeTap?(); native.press(forDuration: 0.01); record(action: "tap") }
    func press(forDuration duration: TimeInterval) { UIElement.beforeNativeTap?(); native.press(forDuration: duration); record(action: "press") }
    func press(forDuration duration: TimeInterval, thenDragTo coordinate: Self,
               withVelocity velocity: XCUIGestureVelocity, thenHoldForDuration hold: TimeInterval) {
        UIElement.beforeNativeTap?()
        native.press(forDuration: duration, thenDragTo: coordinate.native, withVelocity: velocity, thenHoldForDuration: hold)
        record(action: "drag")
        coordinate.record(action: "drop")
    }
}

@MainActor
struct UIElementQuery {
    let native: XCUIElementQuery
    fileprivate let path: [[String: String]]?
    var firstMatch: UIElement { UIElement(native.firstMatch, path: path.map { $0 + [["first": "1"]] }) }
    subscript(identifier: String) -> UIElement { matching(identifier: identifier).firstMatch }
    var count: Int { native.count }
    func element(boundBy index: Int) -> UIElement { UIElement(native.element(boundBy: index)) }
    var allElementsBoundByIndex: [UIElement] { native.allElementsBoundByIndex.map { UIElement($0) } }
    func matching(_ predicate: NSPredicate) -> UIElementQuery {
        UIElementQuery(native: native.matching(predicate), path: path.map { $0 + [["predicate": predicate.predicateFormat]] })
    }
    func matching(identifier: String) -> UIElementQuery {
        UIElementQuery(native: native.matching(identifier: identifier), path: path.map {
            $0 + [["predicate": NSPredicate(format: "identifier == %@ OR label == %@ OR placeholderValue == %@",
                                            identifier, identifier, identifier).predicateFormat]]
        })
    }
    func containing(_ type: XCUIElement.ElementType, identifier: String) -> UIElementQuery {
        UIElementQuery(native: native.containing(type, identifier: identifier), path: nil)
    }
    private func descendants(_ type: XCUIElement.ElementType, native query: XCUIElementQuery) -> UIElementQuery {
        UIElementQuery(native: query, path: path.map { $0 + [["type": String(type.rawValue)]] })
    }
    var buttons: UIElementQuery { descendants(.button, native: native.buttons) }
    var switches: UIElementQuery { descendants(.switch, native: native.switches) }
    var staticTexts: UIElementQuery { descendants(.staticText, native: native.staticTexts) }
}

@MainActor
extension XCUIElement {
    func tapBriefly() {
        defer { UITestSnapshotReader.invalidate() }
        guard let state = try? snapshot() else {
            XCTFail("点击目标应提供可读的界面状态。")
            return
        }
        if state.elementType == .button && state.identifier != "keyboard.dismiss" {
            if !isHittable {
                press(forDuration: 0.01)
                return
            }
            UITestControlClient.activate(["identifier": state.identifier, "label": state.label], element: self)
        } else { press(forDuration: 0.01) }
    }
}

@MainActor
extension XCUICoordinate {
    func tapBriefly() { UITestSnapshotReader.invalidate(); press(forDuration: 0.01) }
}

@MainActor
extension XCUIElementSnapshot {
    func snapshots(matching type: XCUIElement.ElementType) -> [any XCUIElementSnapshot] {
        let matches: [any XCUIElementSnapshot] = elementType == type ? [self] : []
        return matches + children.flatMap { $0.snapshots(matching: type) }
    }

    func firstSnapshot(where matches: (any XCUIElementSnapshot) -> Bool) -> (any XCUIElementSnapshot)? {
        if matches(self) { return self }
        for child in children {
            if let match = child.firstSnapshot(where: matches) { return match }
        }
        return nil
    }
}

@MainActor
extension UIAutomationTestCase {
    func captureBrowserScreenshot(_ title: String) {
        let attachment = XCTAttachment(screenshot: app.native.screenshot())
        attachment.name = "界面截图：\(title)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func checkSideToolbar(_ labels: [String]) {
        let window = app.native.windows.firstMatch.frame
        guard let safe = app.scrollGestureFrame(in: window) else { return }
        let navigation = ["日程", "地图", "话廊", "成绩", "我的"].map { app.native.buttons[$0].frame }
            .reduce(CGRect.null) { $0.union($1) }
        var previous: CGRect?
        let buttons = labels.map { app.native.buttons[$0] }
        let visible = buttons.filter { $0.exists && $0.isHittable }
        assertUI(!visible.isEmpty, "侧栏应直接呈现主要操作。")
        for button in visible {
            assertUI(button.frame.minX >= safe.maxX - 0.5 && button.frame.maxX <= window.maxX
                && button.frame.maxY <= navigation.minY,
                "工具应完整排列在主导航上方的系统侧栏：\(button.label)，按钮 \(button.frame)。")
            if let previous { assertUI(button.frame.minY >= previous.maxY, "侧栏工具应按顺序竖向排列。") }
            previous = button.frame
        }
        let hidden = labels.filter { !app.native.buttons[$0].exists || !app.native.buttons[$0].isHittable }
        if !hidden.isEmpty {
            let overflow = app.native.buttons["BottomOverflowBarButtonItem"]
            assertUI(overflow.exists && overflow.isHittable && overflow.frame.minX >= safe.maxX
                && overflow.frame.maxY <= navigation.minY, "剩余操作应由系统侧栏更多菜单承载。")
            overflow.press(forDuration: 0.01)
            for label in hidden {
                let item = app.native.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
                assertUI(item.waitForExistence(timeout: 5) && item.isHittable, "更多菜单应提供原有操作：\(label)。")
            }
            dismissBrowserActionMenu()
        }
    }

    func checkBrowserActionBounds(_ labels: [String]) {
        let window = app.native.windows.firstMatch.frame
        if window.height > window.width && (windowTraits()["safeTrailing"] ?? 0) > 0 { checkSideToolbar(labels); return }
        let navigation = ["日程", "地图", "话廊", "成绩", "我的"].map { app.mainTab($0).native.frame }
            .reduce(CGRect.null) { $0.union($1) }
        for label in labels {
            let button = app.native.buttons[label]
            assertUI(button.isHittable && window.contains(button.frame) && !button.frame.intersects(navigation),
                "悬浮工具应完整显示在主导航之外：\(label)。")
        }
    }

    func revealBrowserAction(_ label: String) -> UIElement {
        if !app.native.buttons[label].exists {
            let overflow = app.native.buttons["BottomOverflowBarButtonItem"]
            assertUI(overflow.exists && overflow.isHittable, "折叠操作应提供系统更多菜单：\(label)。")
            overflow.press(forDuration: 0.01)
        }
        assertUI(app.native.buttons[label].waitForExistence(timeout: 5) && app.native.buttons[label].isHittable,
            "当前操作应可触达：\(label)。")
        return app.buttons[label]
    }

    func dismissBrowserActionMenu() {
        app.native.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75)).tapBriefly()
    }

    func checkScheduleGeometry() {
        let schedule = app.mainTab("日程")
        guard schedule.exists, schedule.isSelected else { return }
        let window = app.native.windows.firstMatch.frame
        let traits = windowTraits()
        let grid = app.native.descendants(matching: .any)["schedule.calendar"]
        if grid.exists {
            let bar = ["日程", "地图", "话廊", "成绩", "我的"].map { app.mainTab($0).native.frame }
                .reduce(CGRect.null) { $0.union($1) }
            let hasBottomBar = bar.width > bar.height && bar.minY > window.midY
            let gap = (hasBottomBar ? bar.minY : window.maxY) - grid.frame.maxY
            assertUI(hasBottomBar ? gap >= 8 : abs(gap) <= 1,
                "课表底部应按系统导航位置分配空间：课表 \(grid.frame)，导航 \(bar)，间隙 \(gap)。")
            let action = app.native.buttons["schedule.add-content"]
            let bottom = hasBottomBar ? bar.minY : window.maxY - CGFloat(traits["safeBottom"] ?? 0)
            assertUI(action.exists && action.frame.maxY <= bottom + 0.5,
                "课表操作应保持在系统可触达区域：按钮 \(action.frame)，底部边界 \(bottom)。")
        }
        guard app.native.segmentedControls.buttons["空教室"].exists else { return }
        let header = app.native.segmentedControls.firstMatch.frame
        let top = CGFloat(traits["safeTop"] ?? 0)
        let side = (traits["safeLeading"] ?? 0) + (traits["safeTrailing"] ?? 0)
        let minimumTop = window.minY + (top == 0 && side > 0 ? 16 : top)
        assertUI(header.minY >= minimumTop - 0.5,
            "日程各分区应保留窗口安全距离：分区栏 \(header)，顶部边界 \(minimumTop)。")
        let key = "\(window):\(traits["safeTop"] ?? 0):\(side):\(header.height)"
        if let reference = scheduleHeaderFrames[key] {
            assertUI(abs(header.minY - reference.minY) <= 1,
                "日程各分区应共享顶部位置：当前 \(header)，参考 \(reference)。")
        } else { scheduleHeaderFrames[key] = header }
    }

    func assertRefreshBelowSectionTabs(referenceHeader: CGRect? = nil) {
        let header = app.native.segmentedControls.firstMatch
        guard let list = app.native.collectionViews.allElementsBoundByIndex.first(where: { $0.frame.width > 0 }) else {
            assertUI(false, "当前分区应提供可见的原生列表。")
            return
        }
        if let referenceHeader {
            assertUI(abs(header.frame.minY - referenceHeader.minY) <= 1 && abs(header.frame.height - referenceHeader.height) <= 1,
                "课表、DDL 与空教室应共享分区栏安全距离：当前 \(header.frame)，参考 \(referenceHeader)。")
        }
        let row = list.cells.containing(.button, identifier: "app.refresh-status.action").firstMatch
        let stamp = row.staticTexts["app.refresh-status.timestamp"]
        assertUI(header.exists && row.exists && stamp.exists && row.frame.minY >= header.frame.maxY
            && stamp.frame.minY >= header.frame.maxY && stamp.isHittable,
            "刷新行与时间文字应完整显示在分区栏下方：分区栏 \(header.frame)，刷新行 \(row.frame)，时间 \(stamp.frame)。")
    }

    func windowTraits() -> [String: Int] {
        guard let response = UITestControlClient.request(["command": "window-layout"]),
              let values = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [[String: Any]],
              let traits = values.first else { XCTFail("当前窗口应提供布局信息。"); return [:] }
        return traits.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    @MainActor
    func openSettings(_ route: String) {
        let mine = app.mainTab("我的")
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
        let button = UIElement(app.native.buttons["BackButton"].exists ? app.native.buttons["BackButton"]
            : app.native.navigationBars[bar.identifier].buttons.firstMatch)
        assertUI(button.isHittable, "当前导航栏的返回按钮应可交互。")
        button.tapBriefly()
    }

    @MainActor
    func waitForRequest(_ key: String) {
        assertUI(waitUntil(NSPredicate { _, _ in
            UITestControlClient.request(["command": "request-state", "key": key]) == "pending"
        }, on: app), "请求应进入受控等待状态：\(key)。滚动状态：\(UITestControlClient.request(["command": "scroll-inventory"]) ?? "缺失")。")
    }

    @MainActor
    func releaseRequest(_ key: String) {
        assertUI(UITestControlClient.request(["command": "release-request", "key": key]) == "released", "场景应释放原请求。")
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
                : NSPredicate(format: "identifier == %@ AND label CONTAINS %@", identifier, label)
            let button = app.buttons.matching(predicate).firstMatch
            if button.exists {
                button.tapBriefly { self.reveal(button, description: title) }
                return
            }
        }
        let exact = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", title, title))
        let exactExists = exact.firstMatch.exists
        let matches = exactExists ? exact : app.buttons.matching(NSPredicate(format: "identifier == %@ OR label CONTAINS %@", title, title))
        let button = matches.firstMatch
        if exactExists || button.exists {
            if UIElement.usesNativeInteraction ? button.native.isHittable : button.isHittable {
                button.tapBriefly()
                return
            }
            if let visible = matches.allElementsBoundByIndex.first(where: { UIElement.usesNativeInteraction ? $0.native.isHittable : $0.isHittable }) {
                visible.press(forDuration: 0.01)
                return
            }
        }
        let cardTitle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "community.poster.card."))
            .containing(.staticText, identifier: title).firstMatch.staticTexts[title]
        if cardTitle.exists {
            cardTitle.tapBriefly { self.reveal(cardTitle, description: title) }
            return
        }
        reveal(button, description: title)
        button.press(forDuration: 0.01)
    }
}
