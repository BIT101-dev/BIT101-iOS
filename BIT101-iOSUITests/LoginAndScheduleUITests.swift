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
private enum UITestControlClient {
    static func activate(_ parameters: [String: String], element: XCUIElement) {
        let started = ProcessInfo.processInfo.systemUptime
        let result = request(parameters.merging(["command": "activate"]) { _, command in command }, timeout: 5)
        if result?.hasPrefix("native") == true {
            if let result, result != "native" { print("UI native control: \(result)") }
            UIElement.beforeNativeTap?()
            element.press(forDuration: 0.01)
            return
        }
        XCTAssertTrue(result == "activated" || result == "control", "UI 动作应由实际控件执行：\(parameters["label"] ?? "")。")
        print(String(format: result == "control" ? "UI control action: %.3f" : "UI accessibility activate: %.3f", ProcessInfo.processInfo.systemUptime - started))
    }

    static func request(_ parameters: [String: String], timeout: TimeInterval = 10) -> String? {
        let connection = NWConnection(host: "127.0.0.1", port: 19101, using: .tcp)
        let response = UITestControlReply()
        let received = XCTestExpectation(description: "本机 UI 操作")
        let payload = try! JSONEncoder().encode(parameters) + Data([10])
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
private enum UITestSnapshotReader {
    static var application: XCUIApplication?
    static var applicationOrigin = CGPoint.zero
    private(set) static var generation = 0
    private static var cached: (any XCUIElementSnapshot)?
    static var liveQueries: [Data: [String: Any]] = [:]

    static func invalidate() { cached = nil; liveQueries.removeAll(keepingCapacity: true); generation += 1 }

    static func retain(_ snapshot: any XCUIElementSnapshot) { cached = snapshot }

    static func snapshot(of application: XCUIApplication) throws -> any XCUIElementSnapshot {
        if let cached { return cached }
        let started = ProcessInfo.processInfo.systemUptime
        let snapshot = try application.snapshot()
        cached = snapshot
        print(String(format: "UI shared snapshot: %.3f", ProcessInfo.processInfo.systemUptime - started))
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
    let native: XCUIElement
    fileprivate let path: [[String: String]]?
    private var capturedSnapshot: (any XCUIElementSnapshot)?
    private var capturedGeneration = -1

    init(_ native: XCUIElement, path: [[String: String]]? = nil) {
        self.native = native
        self.path = path
    }

    fileprivate func attributes() -> [String: Any]? {
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
        print(String(format: "UI live query: %.3f", ProcessInfo.processInfo.systemUptime - started))
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
    @objc var isEnabled: Bool { attributes()?["enabled"] as? Bool ?? native.isEnabled }
    @objc var isSelected: Bool { attributes()?["selected"] as? Bool ?? native.isSelected }
    @objc var isHittable: Bool {
        let state = attributes()
        if state?["hittable"] as? Bool == true { return true }
        if let state, state["hittable"] == nil {
            guard state["exists"] as? Bool == true,
                  let frame = state["frame"] as? [Double], frame.count == 4, frame[2] > 0, frame[3] > 0 else { return false }
            return native.isHittable
        }
        return native.isHittable
    }
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
    var state: XCUIApplication.State { (native as! XCUIApplication).state }
    func screenshot() -> XCUIScreenshot { native.screenshot() }
    func snapshot() throws -> any XCUIElementSnapshot {
        if let application = native as? XCUIApplication { return try UITestSnapshotReader.snapshot(of: application) }
        if path == nil, let state = currentNativeSnapshot() { return state }
        return try native.snapshot()
    }
    func activate() { UITestSnapshotReader.invalidate(); (native as! XCUIApplication).activate() }
    func coordinate(withNormalizedOffset offset: CGVector) -> UIAutomationCoordinate {
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
        let id = path == nil ? nil : attributes()?["identifier"] as? String
        if duration < 0.1 { Self.beforeNativeTap?() }
        native.press(forDuration: duration)
        if let id, !id.isEmpty { _ = UITestControlClient.request(["command": "record", "identifier": id]) }
    }
    func swipeLeft() { native.swipeLeft(); UITestSnapshotReader.invalidate() }
    func swipeRight() { native.swipeRight(); UITestSnapshotReader.invalidate() }
    func swipeUp() { native.swipeUp(); UITestSnapshotReader.invalidate() }
    func swipeDown() { native.swipeDown(); UITestSnapshotReader.invalidate() }
    func pinch(withScale scale: CGFloat, velocity: CGFloat) { native.pinch(withScale: scale, velocity: velocity); UITestSnapshotReader.invalidate() }
    func adjust(toPickerWheelValue value: String) { native.adjust(toPickerWheelValue: value); UITestSnapshotReader.invalidate() }
    func typeText(_ text: String) {
        defer { UITestSnapshotReader.invalidate() }
        let id = path == nil ? nil : attributes()?["identifier"] as? String
        native.typeText(text)
        if let id, !id.isEmpty { _ = UITestControlClient.request(["command": "record", "identifier": id]) }
    }

    func tapBriefly() {
        defer { UITestSnapshotReader.invalidate() }
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
            let started = ProcessInfo.processInfo.systemUptime
            let response = UITestControlClient.request(["command": "query-activate", "query": String(decoding: data, as: UTF8.self),
                                                       "hittable": isHittable ? "1" : "0", "label": label, "identifier": identifier], timeout: 5)
            if response == "activated" {
                print(String(format: "UI accessibility activate: %.3f", ProcessInfo.processInfo.systemUptime - started))
                return
            }
            if response == "control" {
                print(String(format: "UI control action: %.3f", ProcessInfo.processInfo.systemUptime - started))
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
        if path == nil {
            Self.beforeNativeTap?()
            native.tap()
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
    var switches: UIElementQuery { descendants(matching: .switch) }
    var navigationBars: UIElementQuery { descendants(matching: .navigationBar) }
    var tabBars: UIElementQuery { descendants(matching: .tabBar) }
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
    func withOffset(_ offset: CGVector) -> Self { Self(native: native.withOffset(offset)) }
    func tapBriefly() { native.press(forDuration: 0.01); UITestSnapshotReader.invalidate() }
    func press(forDuration duration: TimeInterval) { native.press(forDuration: duration); UITestSnapshotReader.invalidate() }
    func press(forDuration duration: TimeInterval, thenDragTo coordinate: Self,
               withVelocity velocity: XCUIGestureVelocity, thenHoldForDuration hold: TimeInterval) {
        native.press(forDuration: duration, thenDragTo: coordinate.native, withVelocity: velocity, thenHoldForDuration: hold)
        UITestSnapshotReader.invalidate()
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

nonisolated class UIAutomationTestCase: XCTestCase {
    @MainActor var app: UIElement!
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
        if element.revealInScrollView() == "revealed", element.exists && element.isHittable {
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
        let state = try? app.snapshot()
        let bar = state?.snapshots(matching: .navigationBar).last(where: { !$0.frame.isEmpty && state!.frame.intersects($0.frame) })
        assertUI(bar != nil, "返回操作应使用当前可见的导航栏。")
        let button = app.navigationBars[bar!.identifier].buttons.firstMatch
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
        assertUI(field.appears(timeout: 5), "输入操作应等待字段出现。")
        let secure = field.elementType == .secureTextField
        if text.hasSuffix("\n") {
            replaceTextWithKeyboard(text, in: field)
            return
        }
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
        waitForValue(secure ? String(repeating: "•", count: text.count) : text, of: field)
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
        if let application = app {
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
        app = UIElement(application, path: [])
        UITestSnapshotReader.application = application
        UITestSnapshotReader.invalidate()
        UIElement.beforeNativeTap = { [weak self] in self?.dismissNotificationBanner() }
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
            initialElement = app.navigationBars[settingsTitles[initialSettings]!]
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
            initialElement = app.tabBars.buttons[tabTitles[initialTab]!]
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
                        $0.elementType == .navigationBar && $0.identifier == settingsTitles[initialSettings]!
                    } != nil
                } else if account == nil {
                    ready = snapshot.firstSnapshot { $0.identifier == "login.student-id" } != nil
                } else if initialTab == "schedule" {
                    ready = snapshot.firstSnapshot { $0.identifier == "schedule.blank-context-menu" } != nil
                } else if initialTab == "gallery" && (failureOnce || !content) {
                    ready = snapshot.firstSnapshot { $0.elementType == .alert && $0.label == "加载话廊失败" } != nil
                } else {
                    ready = snapshot.firstSnapshot { $0.elementType == .tabBar }?.firstSnapshot {
                        $0.elementType == .button && $0.label == tabTitles[initialTab]! && $0.isSelected
                    } != nil
                }
                if ready { identity = currentIdentity; break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        assertUI(identity != nil, "同一界面快照中的场景身份与初始页面应完成加载：\(initialSettings ?? initialTab)。场景：\(String(describing: lastSnapshot?.firstSnapshot(where: { $0.identifier == "ui-test.scene" })?.value))，导航：\(lastSnapshot?.snapshots(matching: .tabBar).flatMap { $0.snapshots(matching: .button).map { "\($0.label)=\($0.isSelected)" } } ?? [])。")
        if let lastSnapshot {
            UITestSnapshotReader.applicationOrigin = lastSnapshot.frame.origin
            UITestSnapshotReader.retain(lastSnapshot)
        }
        if Self.sessionProcess == nil {
            let process = identity!.components(separatedBy: ":").first!
            Self.sessionProcess = process
            print("UI automation App process: \(process)")
        }
        Self.sessionScene = identity
        return app
    }
}

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
