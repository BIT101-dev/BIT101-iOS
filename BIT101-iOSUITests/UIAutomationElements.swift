import CoreGraphics
import Darwin
import Network
import UIKit
import XCTest
import os

@MainActor
enum UITestIdleBudget {
    static func exchange(_ timeout: TimeInterval) -> TimeInterval? {
        guard let library = dlopen(nil, RTLD_NOW) else {
            XCTFail("测试运行时应提供动态符号查询。")
            return nil
        }
        defer { dlclose(library) }
        guard let read = dlsym(library, "_XCTApplicationStateTimeout"),
            let write = dlsym(library, "_XCTSetApplicationStateTimeout")
        else {
            XCTFail("测试运行时应提供应用空闲等待设置。")
            return nil
        }
        typealias Reader = @convention(c) () -> Double
        typealias Writer = @convention(c) (Double) -> Void
        let previous = unsafeBitCast(read, to: Reader.self)()
        unsafeBitCast(write, to: Writer.self)(timeout)
        return previous
    }
}

@MainActor
enum UITestSystemAlerts {
    static func allowLocation(timeout: TimeInterval = 0) {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = system.alerts.firstMatch
        let allow = permission.buttons.matching(
            NSPredicate(format: "label IN %@", ["允许一次", "Allow Once"])
        ).firstMatch
        let presented = timeout > 0 ? allow.waitForExistence(timeout: timeout) : allow.exists
        guard presented else { return }
        allow.tap()
        XCTAssertTrue(UIElement(permission).disappears(timeout: 2), "定位授权后应关闭系统提示。")
    }
}

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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [self] data, _, complete, error in
            if append(data, error: error, complete: complete) {
                completion()
            } else if error == nil && !complete {
                receive(on: connection, completion: completion)
            }
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
            if let error {
                state.result = error.localizedDescription
                return true
            }
            if complete {
                state.result = "control channel closed"
                return true
            }
            return false
        }
    }
}

@MainActor
enum UITestControlClient {
    static var port: UInt16 {
        guard let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"],
            let suffix = UInt16(device.suffix(4), radix: 16)
        else { return 19101 }
        return 20000 + suffix % 40000
    }

    static func activate(_ parameters: [String: String], element: XCUIElement) {
        let result = request(
            parameters.merging(["command": "activate"]) { _, command in command }, timeout: 5)
        if result?.hasPrefix("native") == true {
            if let result, result != "native" { print("UI native control: \(result)") }
            UIElement.beforeNativeTap?()
            element.press(forDuration: 0.01)
            return
        }
        XCTAssertTrue(
            result == "activated" || result == "control",
            "UI 动作应由实际控件执行：\(parameters["label"] ?? "")。")
    }

    static func request(_ parameters: [String: String], timeout: TimeInterval = 10) -> String? {
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            UITestSnapshotReader.recordTiming(
                "control." + (parameters["command"] ?? "scene"), since: started)
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            XCTFail("UI 通道端口需要有效。")
            return nil
        }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let response = UITestControlReply()
        let received = XCTestExpectation(description: "本机 UI 操作")
        let payload: Data
        do { payload = try JSONEncoder().encode(parameters) + Data([10]) } catch {
            XCTFail("UI 通道应编码请求参数：\(error.localizedDescription)。")
            return nil
        }
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(
                    content: payload,
                    completion: .contentProcessed { error in
                        if response.append(nil, error: error, complete: false) {
                            received.fulfill()
                        }
                    })
            } else if case .failed(let error) = state {
                if response.append(nil, error: error, complete: false) { received.fulfill() }
            }
        }
        connection.start(queue: DispatchQueue(label: "BIT101.UITestControlClient"))
        response.receive(on: connection) { received.fulfill() }
        XCTAssertEqual(
            XCTWaiter.wait(for: [received], timeout: timeout), .completed,
            "本机 UI 通道应完成请求：\(parameters["command"] ?? "scene")。")
        connection.cancel()
        if parameters["command"] == nil
            || ["activated", "control", "entered", "revealed", "finished", "selected"].contains(
                response.message ?? "")
        {
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
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        queryMetrics[kind, default: [:]]["seconds", default: 0] += elapsed
        if elapsed >= 1 {
            print("UI slow step: \(kind) seconds=\(String(format: "%.3f", elapsed))")
        }
    }

    static func measure<T>(_ phase: String, operation: () throws -> T) rethrows -> T {
        let started = ProcessInfo.processInfo.systemUptime
        print("UI phase begin: \(phase)")
        defer {
            recordTiming(phase, since: started)
            print("UI phase end: \(phase)")
        }
        return try operation()
    }

    static func poll() {
        let started = ProcessInfo.processInfo.systemUptime
        defer { recordTiming("poll.run-loop", since: started) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    static func printTimingSummary() {
        if let data = try? JSONSerialization.data(
            withJSONObject: queryMetrics, options: .sortedKeys)
        {
            print("UI query metrics: \(String(decoding: data, as: UTF8.self))")
        }
        queryMetrics.removeAll(keepingCapacity: true)
    }

    static func invalidate() {
        cached = nil
        liveQueries.removeAll(keepingCapacity: true)
        generation += 1
    }

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
            let label = element.label.isEmpty ? (element.placeholderValue ?? "") : element.label
            var result: [String: Any] = [
                "exists": true, "identifier": element.identifier, "label": label,
                "elementType": Int(element.elementType.rawValue), "enabled": element.isEnabled,
                "selected": element.isSelected, "placeholderValue": element.placeholderValue ?? "",
                "frame": [
                    Double(element.frame.minX), Double(element.frame.minY),
                    Double(element.frame.width), Double(element.frame.height),
                ],
            ]
            if let value = element.value { result["value"] = value }
            return result
        }
        func descendants(_ element: any XCUIElementSnapshot) -> [any XCUIElementSnapshot] {
            var result: [any XCUIElementSnapshot] = []
            func append(_ node: any XCUIElementSnapshot) {
                for child in node.children {
                    result.append(child)
                    append(child)
                }
            }
            append(element)
            return result
        }
        var elements = [cached]
        for step in path {
            if let type = step["type"].flatMap(UInt.init) {
                elements = elements.flatMap(descendants).filter {
                    type == 0 || $0.elementType.rawValue == type
                }
            } else if let format = step["predicate"] {
                let predicate = NSPredicate(format: format)
                elements = elements.filter { predicate.evaluate(with: attributes($0)) }
            } else if step["first"] != nil {
                elements = Array(elements.prefix(1))
            }
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

    init(
        _ native: XCUIElement, path: [[String: String]]? = nil,
        snapshot: (any XCUIElementSnapshot)? = nil
    ) {
        self.native = native
        self.path = path
        if let snapshot {
            self.capturedSnapshot = snapshot
            self.capturedGeneration = UITestSnapshotReader.generation
        }
    }

    func attributes(renderedOnly: Bool = false) -> [String: Any]? {
        let started = ProcessInfo.processInfo.systemUptime
        guard let path else {
            guard let state = currentNativeSnapshot() else {
                return [
                    "exists": false, "enabled": false, "selected": false,
                    "label": "", "identifier": "", "frame": [0.0, 0.0, 0.0, 0.0],
                ]
            }
            let label = state.label.isEmpty ? (state.placeholderValue ?? "") : state.label
            var attributes: [String: Any] = [
                "exists": true, "identifier": state.identifier, "label": label,
                "elementType": Int(state.elementType.rawValue), "enabled": state.isEnabled,
                "selected": state.isSelected,
                "frame": [
                    Double(state.frame.minX), Double(state.frame.minY), Double(state.frame.width),
                    Double(state.frame.height),
                ],
            ]
            if let value = state.value { attributes["value"] = value }
            return attributes
        }
        // 无筛选的 firstMatch 沿系统无障碍顺序读取。
        if path.last?["first"] != nil, !path.contains(where: { $0["predicate"] != nil }) {
            return UITestSnapshotReader.attributes(path)
        }
        if path.contains(where: {
            [18, 19, 38, 39, 42, 51, 57, 58].contains(Int($0["type"] ?? "") ?? -1)
                || ($0["predicate"] ?? "").contains("keyboard.dismiss")
                || ($0["predicate"] ?? "").contains("下一个键盘")
        }) {
            return UITestSnapshotReader.attributes(path)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: path, options: .sortedKeys)
        else { return nil }
        if let attributes = UITestSnapshotReader.liveQueries[data] { return attributes }
        guard
            let response = UITestControlClient.request(
                ["command": "query", "query": String(decoding: data, as: UTF8.self)], timeout: 5),
            let elements = try? JSONSerialization.jsonObject(with: Data(response.utf8))
                as? [[String: Any]]
        else {
            return UITestSnapshotReader.attributes(path)
        }
        UITestSnapshotReader.recordTiming("liveQueries", since: started)
        if renderedOnly && elements.isEmpty { return ["exists": false] }
        if elements.isEmpty,
            path.contains(where: { [0, 1, 5, 7, 48].contains(Int($0["type"] ?? "") ?? -1) })
        {
            return UITestSnapshotReader.attributes(path)
        }
        let attributes =
            elements.first ?? [
                "exists": false, "enabled": false, "selected": false, "hittable": false,
                "label": "", "identifier": "",
            ]
        UITestSnapshotReader.liveQueries[data] = attributes
        return attributes
    }

    private func currentNativeSnapshot() -> (any XCUIElementSnapshot)? {
        if capturedGeneration == UITestSnapshotReader.generation { return capturedSnapshot }
        capturedSnapshot = try? native.snapshot()
        capturedGeneration = UITestSnapshotReader.generation
        return capturedSnapshot
    }

    @objc var exists: Bool {
        guard let path else { return currentNativeSnapshot() != nil }
        if path.contains(where: {
            [18, 19, 21, 38, 39, 42, 51, 57, 58].contains(Int($0["type"] ?? "") ?? -1)
        }) {
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
        _ = UITestControlClient.request(
            interactionIdentity.merging(["command": "state"]) { _, command in command })
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
        if let type = attributes()?["elementType"] as? Int,
            let value = XCUIElement.ElementType(rawValue: UInt(type))
        {
            return value
        }
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
        if let application = native as? XCUIApplication {
            return try UITestSnapshotReader.snapshot(of: application)
        }
        if path == nil, let state = currentNativeSnapshot() { return state }
        return try native.snapshot()
    }
    func selectedButtonIdentities() throws -> [(String, String)] {
        guard let path else {
            return try snapshot().snapshots(matching: .button)
                .filter(\.isSelected).map { ($0.identifier, $0.label) }
        }
        let query = path + [["type": "9"], ["predicate": "selected == true"]]
        let data = try JSONSerialization.data(withJSONObject: query)
        guard
            let response = UITestControlClient.request([
                "command": "query", "query": String(decoding: data, as: UTF8.self),
            ]),
            let values = try JSONSerialization.jsonObject(with: Data(response.utf8))
                as? [[String: Any]]
        else { throw CocoaError(.coderInvalidValue) }
        return try values.map { value in
            guard let identifier = value["identifier"] as? String,
                let label = value["label"] as? String
            else { throw CocoaError(.coderInvalidValue) }
            return (identifier, label)
        }
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
            return UIAutomationCoordinate(
                native: native.coordinate(withNormalizedOffset: offset), identifier: identifier,
                label: label, type: Int(elementType.rawValue), scope: identity["scope"] ?? "",
                instance: identity["instance"] ?? "")
        }
        guard !(native is XCUIApplication), let application = UITestSnapshotReader.application
        else {
            return UIAutomationCoordinate(native: native.coordinate(withNormalizedOffset: offset))
        }
        let bounds = frame
        guard !bounds.isEmpty else {
            return UIAutomationCoordinate(native: native.coordinate(withNormalizedOffset: offset))
        }
        let origin = UITestSnapshotReader.applicationOrigin
        return UIAutomationCoordinate(
            native: application.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(
                    dx: bounds.minX + bounds.width * offset.dx - origin.x,
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
            let safeArea = try? JSONDecoder().decode(CGRect.self, from: Data(response.utf8))
        else {
            XCTFail("滚动定位应读取当前窗口的系统安全区。")
            return nil
        }
        let visible = bounds.intersection(safeArea)
        XCTAssertFalse(visible.isEmpty, "滚动区域应与窗口安全区相交：容器 \(bounds)，安全区 \(safeArea)。")
        return visible.isEmpty ? nil : visible
    }
    func swipeLeft() { performGesture("swipe") { native.swipeLeft() } }
    func swipeRight() { performGesture("swipe") { native.swipeRight() } }
    func swipeUp() { performGesture("swipe") { native.swipeUp() } }
    func swipeDown() { performGesture("swipe") { native.swipeDown() } }
    func dragScroll(vertical: Bool, towardEnd: Bool) {
        performGesture("swipe") {
            let begin: CGFloat = towardEnd ? 0.75 : 0.25
            let end = 1 - begin
            let start = CGVector(dx: vertical ? 0.5 : begin, dy: vertical ? begin : 0.5)
            let finish = CGVector(dx: vertical ? 0.5 : end, dy: vertical ? end : 0.5)
            native.coordinate(withNormalizedOffset: start).press(
                forDuration: 0.01,
                thenDragTo: native.coordinate(withNormalizedOffset: finish),
                withVelocity: .slow, thenHoldForDuration: 0.1)
        }
    }
    func pinch(withScale scale: CGFloat, velocity: CGFloat) {
        performGesture("pinch") { native.pinch(withScale: scale, velocity: velocity) }
    }
    func adjust(toPickerWheelValue value: String) {
        performGesture("selection") { native.adjust(toPickerWheelValue: value) }
    }
    private func performGesture(_ action: String, _ operation: () -> Void) {
        Self.beforeNativeTap?()
        let identity = interactionIdentity
        UITestSnapshotReader.measure("gesture.\(action)", operation: operation)
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
        if let path, path.count > 2,
            Array(path.suffix(2)) == [["type": "40"], ["first": "1"]]
        {
            return UIElement(native, path: Array(path.dropLast(2))).interactionIdentity
        }
        let bounds = frame
        var identity = [
            "identifier": identifier, "label": label, "type": String(elementType.rawValue),
            "scope": UITestControlClient.request(["command": "observe"]) ?? "",
            "x": String(Double(bounds.minX)), "y": String(Double(bounds.minY)),
            "width": String(Double(bounds.width)), "height": String(Double(bounds.height)),
        ]
        identity["instance"] =
            attributes()?["instance"] as? String
            ?? UITestControlClient.request(
                identity.merging(["command": "identity"]) { _, command in command }) ?? ""
        if identity["instance"]?.isEmpty != false, !bounds.isEmpty {
            identity["enabled"] = isEnabled ? "1" : "0"
            identity["instance"] =
                UITestControlClient.request(
                    identity.merging(["command": "native-observe"]) { _, command in command }) ?? ""
        }
        return identity
    }
    func recordInput() {
        recordInteraction(interactionIdentity, action: "input")
    }
    func recordTap() {
        recordInteraction(interactionIdentity, action: "tap")
    }
    private func recordInteraction(_ identity: [String: String], action: String = "input") {
        _ = UITestControlClient.request(
            identity.merging(["command": "record", "action": action]) { _, command in command })
    }

    func performAccessibilityAction(named name: String = "activate") -> Bool {
        Self.beforeNativeTap?()
        defer { UITestSnapshotReader.invalidate() }
        guard let path, let data = try? JSONSerialization.data(withJSONObject: path) else {
            return false
        }
        return UITestControlClient.request([
            "command": "query-accessibility-action", "name": name,
            "query": String(decoding: data, as: UTF8.self),
        ]) == "performed"
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
            keyboardState =
                UITestControlClient.request(["command": "keyboard-state", "return-title": title])
                ?? "empty"
            ready = keyboardState == "ready"
            if ready { break }
            UITestSnapshotReader.poll()
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
            attributes()?["elementType"] as? Int == 9
        {
            query[index] = ["type": "9"]
            actionPath = query
        }
        if actionPath == nil
            || actionPath?.contains(where: {
                [0, 1, 49, 50, 52].contains(Int($0["type"] ?? "") ?? -1)
            }) == true
        {
            native.tapBriefly()
            return
        }
        if let actionPath, let data = try? JSONSerialization.data(withJSONObject: actionPath) {
            let response = UITestControlClient.request(
                [
                    "command": "query-activate", "query": String(decoding: data, as: UTF8.self),
                    "hittable": (preparedHittability ?? isHittable) ? "1" : "0", "label": label,
                    "identifier": identifier,
                ], timeout: 5)
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
        } else {
            tapBriefly()
        }
    }

    func insertText(_ text: String) -> String? {
        guard let path, let data = try? JSONSerialization.data(withJSONObject: path) else {
            return "native"
        }
        return UITestControlClient.request(
            [
                "command": "query-input", "query": String(decoding: data, as: UTF8.self),
                "text": text,
            ], timeout: 5)
    }

    func revealInScrollView() -> String? {
        guard let path, let data = try? JSONSerialization.data(withJSONObject: path) else {
            return "native"
        }
        return UITestControlClient.request(
            ["command": "query-reveal", "query": String(decoding: data, as: UTF8.self)], timeout: 5)
    }

    func descendants(matching type: XCUIElement.ElementType) -> UIElementQuery {
        let nestedSwitch =
            type == .switch
            && path?.contains(where: { $0["type"] == String(type.rawValue) }) == true
        return UIElementQuery(
            native: native.descendants(matching: type),
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
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let match = snapshotMainTab(for: labels, in: query) { return match }
            guard query.firstMatch.exists else { return UIElement(query.firstMatch) }
            let map = native.buttons["地图"].firstMatch
            let mine = native.buttons["我的"].firstMatch
            if map.exists && mine.exists {
                let reference = map.frame
                let horizontal = abs(reference.midY - mine.frame.midY) <= 1
                if let match = matchingMainTabButton(
                    in: query, reference: reference, horizontal: horizontal)
                {
                    return match
                }
            }
            UITestSnapshotReader.poll()
            UITestSnapshotReader.invalidate()
        } while Date() < deadline
        XCTFail("主导航应沿同一行或列呈现：\(title)。")
        return UIElement(query.firstMatch)
    }

    private func snapshotMainTab(
        for labels: [String], in query: XCUIElementQuery
    ) -> UIElement? {
        guard let root = try? snapshot() else { return nil }
        let buttons = root.snapshots(matching: .button)
        let matches = buttons.filter { labels.contains($0.label) }
        if matches.isEmpty { return UIElement(query.firstMatch) }
        guard let map = buttons.first(where: { $0.label == "地图" }),
            let mine = buttons.first(where: { $0.label == "我的" })
        else { return nil }
        let reference = map.frame
        let horizontal = abs(reference.midY - mine.frame.midY) <= 1
        if matches.count == 1, let target = matches.first,
            horizontal
                ? abs(target.frame.midY - reference.midY) <= 1
                : abs(target.frame.midX - reference.midX) <= 1
        {
            return UIElement(query.firstMatch, snapshot: target)
        }
        return matchingMainTabButton(in: query, reference: reference, horizontal: horizontal)
    }

    private func matchingMainTabButton(
        in query: XCUIElementQuery,
        reference: CGRect,
        horizontal: Bool
    ) -> UIElement? {
        for button in query.allElementsBoundByIndex {
            let frame = button.frame
            let aligned =
                horizontal
                ? abs(frame.midY - reference.midY) <= 1
                : abs(frame.midX - reference.midX) <= 1
            if aligned {
                return UIElement(button)
            }
        }
        return nil
    }
    func sectionTab(_ title: String) -> UIElement {
        let primaryTitle = ["课表": "日程 / DDL", "DDL": "日程 / DDL"][title] ?? title
        let primary = buttons.matching(NSPredicate(format: "label == %@", primaryTitle)).firstMatch
        return primary.exists && primary.isHittable ? primary : segmentedControls.buttons[title]
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

    func appears(timeout: TimeInterval, line: UInt = #line, file: String = #fileID) -> Bool {
        waitForPresence(true, timeout: timeout, line: line, file: file)
    }
    func disappears(timeout: TimeInterval, line: UInt = #line, file: String = #fileID) -> Bool {
        waitForPresence(false, timeout: timeout, line: line, file: file)
    }
    private func waitForPresence(
        _ presence: Bool, timeout: TimeInterval, line: UInt, file: String
    ) -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            UITestSnapshotReader.recordTiming("wait.presence \(file):\(line)", since: started)
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if exists == presence { return true }
            UITestSnapshotReader.poll()
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
            _ = UITestControlClient.request([
                "command": "record", "identifier": identifier, "label": label, "type": String(type),
                "scope": scope, "instance": instance, "action": action,
            ])
        }
        UITestSnapshotReader.invalidate()
    }
    func withOffset(_ offset: CGVector) -> Self {
        Self(
            native: native.withOffset(offset), identifier: identifier, label: label, type: type,
            scope: scope, instance: instance)
    }
    func tapBriefly() {
        UIElement.beforeNativeTap?()
        native.press(forDuration: 0.01)
        record(action: "tap")
    }
    func press(forDuration duration: TimeInterval) {
        UIElement.beforeNativeTap?()
        native.press(forDuration: duration)
        record(action: "press")
    }
    func press(
        forDuration duration: TimeInterval, thenDragTo coordinate: Self,
        withVelocity velocity: XCUIGestureVelocity, thenHoldForDuration hold: TimeInterval
    ) {
        UIElement.beforeNativeTap?()
        native.press(
            forDuration: duration, thenDragTo: coordinate.native, withVelocity: velocity,
            thenHoldForDuration: hold)
        record(action: "drag")
        coordinate.record(action: "drop")
    }
}

@MainActor
struct UIElementQuery {
    let native: XCUIElementQuery
    fileprivate let path: [[String: String]]?
    var firstMatch: UIElement {
        UIElement(native.firstMatch, path: path.map { $0 + [["first": "1"]] })
    }
    subscript(identifier: String) -> UIElement { matching(identifier: identifier).firstMatch }
    var count: Int { native.count }
    func element(boundBy index: Int) -> UIElement { UIElement(native.element(boundBy: index)) }
    var allElementsBoundByIndex: [UIElement] {
        native.allElementsBoundByIndex.map { UIElement($0) }
    }
    func matching(_ predicate: NSPredicate) -> UIElementQuery {
        UIElementQuery(
            native: native.matching(predicate),
            path: path.map { $0 + [["predicate": predicate.predicateFormat]] })
    }
    func matching(identifier: String) -> UIElementQuery {
        UIElementQuery(
            native: native.matching(identifier: identifier),
            path: path.map {
                $0 + [
                    [
                        "predicate": NSPredicate(
                            format: "identifier == %@ OR label == %@ OR placeholderValue == %@",
                            identifier, identifier, identifier
                        ).predicateFormat
                    ]
                ]
            })
    }
    func containing(_ type: XCUIElement.ElementType, identifier: String) -> UIElementQuery {
        UIElementQuery(native: native.containing(type, identifier: identifier), path: nil)
    }
    private func descendants(_ type: XCUIElement.ElementType, native query: XCUIElementQuery)
        -> UIElementQuery
    {
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
            UITestControlClient.activate(
                ["identifier": state.identifier, "label": state.label], element: self)
        } else {
            press(forDuration: 0.01)
        }
    }
}

@MainActor
extension XCUICoordinate {
    func tapBriefly() {
        UITestSnapshotReader.invalidate()
        press(forDuration: 0.01)
    }
}

@MainActor
extension XCUIElementSnapshot {
    func snapshots(matching type: XCUIElement.ElementType) -> [any XCUIElementSnapshot] {
        let matches: [any XCUIElementSnapshot] = elementType == type ? [self] : []
        return matches + children.flatMap { $0.snapshots(matching: type) }
    }

    func firstSnapshot(where matches: (any XCUIElementSnapshot) -> Bool) -> (
        any XCUIElementSnapshot
    )? {
        if matches(self) { return self }
        for child in children {
            if let match = child.firstSnapshot(where: matches) { return match }
        }
        return nil
    }
}

extension XCUIDevice {
    @MainActor
    func orient(to target: UIDeviceOrientation) {
        guard orientation != target else { return }
        orientation = target
    }
}
