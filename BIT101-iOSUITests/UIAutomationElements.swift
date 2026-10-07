import XCTest
import CoreGraphics
import Network
import os

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
enum UITestSnapshotReader {
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
    let path: [[String: String]]?
    private var capturedSnapshot: (any XCUIElementSnapshot)?
    private var capturedGeneration = -1

    init(_ native: XCUIElement, path: [[String: String]]? = nil) {
        self.native = native
        self.path = path
    }

    func attributes() -> [String: Any]? {
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
