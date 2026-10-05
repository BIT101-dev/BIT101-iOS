#if BIT101_UI_TESTING
import StorageCore
import TransportCore
import Foundation
import Network
import UIKit
import PhotosUI
import QuickLook
import ClientCore
import ScheduleDomain
import SchedulePorts
import CommunityCore
import CommunityPersistence
import DesignSystemKit
import SwiftUI

/// UI 自动化在本机连接中更新场景夹具，App 进程持续运行。
nonisolated final class UITestControlServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BIT101.UITestControl")

    init(handle: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 19101)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.receive(connection, buffer: Data(), handle: handle)
        }
        listener.start(queue: queue)
    }

    deinit { listener.cancel() }

    private static func receive(
        _ connection: NWConnection, buffer: Data,
        handle: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
            var content = buffer
            if let data { content.append(data) }
            if let end = content.firstIndex(of: 10) {
                handle(Data(content[..<end])) { response in
                    connection.send(content: response + Data([10]), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if error != nil || complete || content.count > 16_384 {
                connection.cancel()
            } else {
                receive(connection, buffer: content, handle: handle)
            }
        }
    }
}

@MainActor
enum UITestAccessibilityActions {
    private final class FrameClock: NSObject {
        var keyboardVisible = false
        override init() {
            super.init()
            CADisplayLink(target: self, selector: #selector(tick)).add(to: .main, forMode: .common)
            for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardShown), name: name, object: nil)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden), name: UIResponder.keyboardDidHideNotification, object: nil)
        }
        @objc private func tick() {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows where window.windowLevel == .normal && window.layer.speed != 10 {
                    window.layer.speed = 10
                }
            }
            UITestAccessibilityActions.invalidate()
        }
        @objc private func keyboardShown() { keyboardVisible = true }
        @objc private func keyboardHidden() { keyboardVisible = false }
    }
    private static let frameClock = FrameClock()
    private static var cachedTree: Element?
    private static var treeBuilt = false
    private static var observed = Set<String>()
    private static var visited = Set<String>()

    static func invalidate() {
        cachedTree = nil
        treeBuilt = false
    }

    static func record(_ identifier: String) {
        if !identifier.isEmpty { visited.insert(identifier) }
    }

    static func coverage() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "observed": observed.union(visited).count, "visited": visited.count,
            "pending": observed.subtracting(visited).sorted(),
        ])
    }
    private struct Element {
        let object: NSObject
        let attributes: [String: Any]
        let children: [Element]
        let scroll: UIScrollView?

        var descendants: [Element] { children.flatMap { [$0] + $0.descendants } }
    }

    static func read(_ parameters: [String: String]) throws -> Data {
        if parameters["command"] == "query-activate", parameters["hittable"] == "1",
           performVisibleMenuAction(parameters["label"] ?? "") {
            record(parameters["identifier"] ?? "")
            invalidate()
            return Data("control".utf8)
        }
        guard let query = parameters["query"],
              let steps = try JSONSerialization.jsonObject(with: Data(query.utf8)) as? [[String: String]],
              let root = tree() else { return Data("native".utf8) }
        if parameters["command"] == "query", !steps.contains(where: { ["5", "7"].contains($0["type"] ?? "") }), root.descendants.contains(where: { [5, 7].contains($0.attributes["elementType"] as? Int ?? -1) }) {
            return Data("native".utf8)
        }
        var elements = [root]
        for step in steps {
            if let type = step["type"].flatMap(Int.init) {
                elements = elements.flatMap(\.descendants).filter {
                    let actual = $0.attributes["elementType"] as? Int
                    return type == 0 || actual == type || type == 49 && actual == 52
                }
            } else if let format = step["predicate"] {
                let predicate = NSPredicate(format: format)
                elements = elements.filter { predicate.evaluate(with: $0.attributes) }
            } else if step["first"] != nil {
                elements = Array(elements.prefix(1))
            }
        }
        if parameters["command"] == "query-activate" {
            guard let element = elements.first, parameters["hittable"] == "1",
                  element.attributes["enabled"] as? Bool == true else { return Data("native".utf8) }
            invalidate()
            let target = element.object
            let control = control(for: target)
            if let control, control.showsMenuAsPrimaryAction {
                guard #available(iOS 17.4, *) else { return Data("native".utf8) }
                control.performPrimaryAction()
                record(element.attributes["identifier"] as? String ?? "")
                return Data("control".utf8)
            }
            if let control, control.isEnabled,
               control.isContextMenuInteractionEnabled {
                guard identifier(of: target) == "BackButton" else { return Data("native".utf8) }
                guard #available(iOS 17.4, *) else { return Data("native".utf8) }
                control.performPrimaryAction()
                record(element.attributes["identifier"] as? String ?? "")
                return Data("control".utf8)
            }
            if let control = control as? UISwitch, control.isEnabled {
                control.setOn(!control.isOn, animated: false)
                control.sendActions(for: .valueChanged)
                record(element.attributes["identifier"] as? String ?? "")
                return Data("control".utf8)
            }
            if performBarButton(["identifier": element.attributes["identifier"] as? String ?? "", "label": element.attributes["label"] as? String ?? ""], control: control) {
                record(element.attributes["identifier"] as? String ?? "")
                return Data("control".utf8)
            }
            if target.accessibilityActivate() {
                record(element.attributes["identifier"] as? String ?? "")
                return Data("activated".utf8)
            }
            if let control, control.isEnabled,
               control.allControlEvents.contains(.primaryActionTriggered) || control.allControlEvents.contains(.touchUpInside) {
                control.sendActions(for: control.allControlEvents.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside)
                record(element.attributes["identifier"] as? String ?? "")
                return Data("control".utf8)
            }
            return Data("native".utf8)
        }
        if parameters["command"] == "query-reveal" {
            guard let element = elements.first, let scroll = element.scroll, scroll.isScrollEnabled,
                  !scroll.isPagingEnabled,
                  scroll.contentSize.width <= scroll.bounds.width,
                  let window = scroll.window, let values = element.attributes["frame"] as? [Double] else { return Data("native".utf8) }
            let frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            guard !frame.isEmpty else { return Data("native".utf8) }
            let rect = scroll.convert(window.convert(frame, from: window.screen.coordinateSpace), from: window)
            scroll.scrollRectToVisible(rect, animated: false)
            invalidate()
            return Data("revealed".utf8)
        }
        if parameters["command"] == "query-input" {
            guard let element = elements.first, element.attributes["hittable"] as? Bool == true,
                  let frame = element.attributes["frame"] as? [Double] else { return Data("native".utf8) }
            invalidate()
            let response = input(["x": String(frame[0] + frame[2] / 2), "y": String(frame[1] + frame[3] / 2),
                                  "text": parameters["text"] ?? ""])
            if response == "entered" { record(element.attributes["identifier"] as? String ?? "") }
            return Data(response.utf8)
        }
        if steps.contains(where: { $0["type"] == "49" }), elements.first?.attributes["elementType"] as? Int == 52 {
            return Data("native".utf8)
        }
        return try JSONSerialization.data(withJSONObject: elements.map(\.attributes))
    }
    private static func tree() -> Element? {
        _ = frameClock
        if treeBuilt { return cachedTree }
        cachedTree = makeTree()
        treeBuilt = true
        return cachedTree
    }

    private static func makeTree() -> Element? {
        guard UIApplication.shared.applicationState == .active else { return nil }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.windowLevel == .normal }
        guard let window = windows.last, var controller = window.rootViewController, !platform(controller) else { return nil }
        while let presented = controller.presentedViewController { controller = presented }
        guard controller.view.convert(controller.view.bounds, to: window).intersects(window.bounds) else { return nil }
        var visited = Set<ObjectIdentifier>()
        func make(_ object: NSObject, scroll inherited: UIScrollView? = nil) -> Element? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object is UIDatePicker || object is UIPickerView { return nil }
            if object.accessibilityElementsHidden { return nil }
            if let view = object as? UIView, view.isHidden || view.alpha == 0 { return nil }
            let frame = object.accessibilityFrame
            var scroll = inherited
            if let view = object as? UIView {
                var ancestor: UIView? = view
                while let candidate = ancestor {
                    if let container = candidate as? UIScrollView { scroll = container; break }
                    ancestor = candidate.superview
                }
            }
            let point = window.convert(CGPoint(x: frame.midX, y: frame.midY), from: window.screen.coordinateSpace)
            let hit = window.hitTest(point, with: nil)
            var inputView = hit
            while let view = inputView, !(view is UITextField || view is UITextView) { inputView = view.superview }
            let type: Int
            switch object {
            case is UIWindow: type = 4
            case is UINavigationBar: type = 21
            case is UITabBar: type = 22
            case is UIToolbar: type = 24
            case is UITableView: type = 26
            case is UICollectionView: type = 32
            case is UISegmentedControl: type = 37
            case is UISwitch: type = 40
            case let field as UITextField: type = field.isSecureTextEntry ? 50 : 49
            case is UITextView: type = 52
            case is UIScrollView: type = 46
            default:
                if object.isAccessibilityElement && object.accessibilityTraits.contains(.toggleButton) { type = 40 }
                else if object.isAccessibilityElement && object.accessibilityTraits.contains(.link) { type = 42 }
                else if object.isAccessibilityElement && object.accessibilityTraits.contains(.button) { type = 9 }
                else if object.isAccessibilityElement, let input = inputView as? UITextField { type = input.isSecureTextEntry ? 50 : 49 }
                else if object.isAccessibilityElement, inputView is UITextView { type = 52 }
                else if object.isAccessibilityElement && object.accessibilityTraits.contains(.staticText) { type = 48 }
                else { type = 1 }
            }
            var label = object.accessibilityLabel ?? ""
            var id = identifier(of: object) ?? ""
            if let bar = object as? UINavigationBar {
                label = bar.topItem?.title ?? label
                if id.isEmpty { id = label }
            }
            var value = object.accessibilityValue
            var placeholder = ""
            if let field = (object as? UITextField) ?? (type == 49 || type == 50 ? inputView as? UITextField : nil) {
                value = field.isSecureTextEntry ? String(repeating: "•", count: field.text?.count ?? 0) : field.text
                placeholder = field.placeholder ?? ""
            } else if let field = (object as? UITextView) ?? (type == 52 ? inputView as? UITextView : nil) { value = field.text }
            else if let control = object as? UISwitch { value = control.isOn ? "1" : "0" }
            let enabled = !object.accessibilityTraits.contains(.notEnabled) && (object as? UIControl)?.isEnabled != false
            var selected = object.accessibilityTraits.contains(.selected) || (object as? UIControl)?.isSelected == true
            var clipped = false
            var container: Any? = object
            var ancestors = Set<ObjectIdentifier>()
            while let element = container as? NSObject, ancestors.insert(ObjectIdentifier(element)).inserted {
                if let view = element as? UIView {
                    if type == 9, let segmented = view as? UISegmentedControl, segmented.selectedSegmentIndex >= 0,
                       let title = segmented.titleForSegment(at: segmented.selectedSegmentIndex) {
                        selected = label == title
                    }
                    if view.clipsToBounds && !view.bounds.contains(view.convert(point, from: window)) { clipped = true }
                    container = view.superview
                } else { container = (element as? UIAccessibilityElement)?.accessibilityContainer }
            }
            let obscured = window.windowScene?.windows.contains { overlay in
                guard !overlay.isHidden, overlay.alpha > 0, overlay.windowLevel > window.windowLevel else { return false }
                let location = overlay.convert(CGPoint(x: frame.midX, y: frame.midY), from: window.screen.coordinateSpace)
                return overlay.hitTest(location, with: nil) != nil
            } == true
            let hittable = !clipped && !obscured && !frame.isEmpty && window.bounds.contains(point)
                && hit?.isDescendant(of: controller.view) == true
            if enabled && hittable && [9, 40, 49, 50, 52].contains(type) && !id.isEmpty {
                observed.insert(id)
            }
            var attributes: [String: Any] = [
                "identifier": id, "label": label, "elementType": type,
                "placeholderValue": placeholder,
                "exists": true, "enabled": enabled,
                "selected": selected, "hittable": hittable,
                "frame": [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)],
            ]
            if let value { attributes["value"] = value }
            var children: [Element] = []
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 && !object.accessibilityTraits.contains(.adjustable) {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let element = make(child, scroll: scroll) { children.append(element) }
                }
            }
            if let view = object as? UIView {
                children += view.subviews.compactMap { make($0, scroll: scroll) }
            }
            return Element(object: object, attributes: attributes, children: children, scroll: scroll)
        }
        guard var content = make(controller.view) else { return nil }
        if let alert = controller as? UIAlertController {
            var attributes = content.attributes
            attributes["elementType"] = alert.preferredStyle == .alert ? 7 : 5
            attributes["label"] = alert.title ?? ""
            content = Element(object: content.object, attributes: attributes, children: content.children, scroll: nil)
        }
        let windowAttributes: [String: Any] = [
            "identifier": "", "label": "", "elementType": 4, "exists": true,
            "enabled": true, "selected": false, "hittable": true,
            "frame": [Double(window.frame.minX), Double(window.frame.minY), Double(window.frame.width), Double(window.frame.height)],
        ]
        return Element(object: window, attributes: windowAttributes.merging(["elementType": 2]) { _, type in type },
                       children: [Element(object: window, attributes: windowAttributes, children: [content], scroll: nil)], scroll: nil)
    }

    private static func platform(_ controller: UIViewController) -> Bool {
        controller is PHPickerViewController || controller is QLPreviewController || controller is UIActivityViewController
            || controller is UIImagePickerController || controller is UIDocumentPickerViewController
            || controller.children.contains(where: platform)
            || controller.presentedViewController.map(platform) == true
    }

    static func finishInput() -> String {
        if let input = focusedInput(), let accessory = input.inputAccessoryView as? UIToolbar,
           let item = accessory.items?.first(where: { $0.accessibilityIdentifier == "keyboard.dismiss" }), let action = item.action {
            return UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil) ? "finished" : "input action missing"
        }
        func item(in view: UIView) -> UIBarButtonItem? {
            if let toolbar = view as? UIToolbar,
               let item = toolbar.items?.first(where: { $0.accessibilityIdentifier == "keyboard.dismiss" }) { return item }
            return view.subviews.lazy.compactMap { item(in: $0) }.first
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where !window.isHidden {
                if let item = item(in: window), let action = item.action {
                    return UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil) ? "finished" : "input action missing"
                }
            }
        }
        return "input toolbar missing"
    }

    private static func focusedInput() -> (UIResponder & UITextInput)? {
        func find(_ view: UIView) -> (UIResponder & UITextInput)? {
            if view.isFirstResponder, view is UITextField || view is UITextView,
               let input = view as? (UIResponder & UITextInput) { return input }
            return view.subviews.lazy.compactMap(find).first
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .lazy.compactMap(find).first
    }

    static func keyboardState() -> String {
        focusedInput() != nil || frameClock.keyboardVisible ? "active" : "hidden"
    }

    static func selectInput() -> String {
        func select(in view: UIView) -> Bool {
            if view.isFirstResponder, let input = view as? UITextInput,
               let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument) {
                input.selectedTextRange = range
                return true
            }
            return view.subviews.contains(where: select)
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).contains(where: { select(in: $0) }) ? "selected" : "input focus missing"
    }

    static func input(_ parameters: [String: String]) -> String {
        guard UIApplication.shared.applicationState == .active else { return "native" }
        guard let x = parameters["x"].flatMap(Double.init), let y = parameters["y"].flatMap(Double.init),
              let text = parameters["text"] else { return "invalid input" }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows.reversed() where !window.isHidden && window.windowLevel == .normal {
                let point = window.convert(CGPoint(x: x, y: y), from: scene.screen.coordinateSpace)
                var view = window.hitTest(point, with: nil)
                while let candidate = view {
                    if candidate is UITextField || candidate is UITextView,
                       let input = candidate as? (UIView & UITextInput) {
                        guard let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument) else {
                            return "input range missing"
                        }
                        input.selectedTextRange = range
                        input.insertText(text)
                        return "entered"
                    }
                    view = candidate.superview
                }
            }
        }
        return "input target missing"
    }

    static func activate(_ parameters: [String: String]) -> String {
        if performVisibleMenuAction(parameters["label"] ?? "") { return "control" }
        guard let element = button(parameters) else { return "native" }
        let control = control(for: element)
        if control?.showsMenuAsPrimaryAction == true { return "native" }
        if let control, control.isEnabled,
           control.isContextMenuInteractionEnabled {
            guard parameters["identifier"] == "BackButton" else { return "native" }
            guard #available(iOS 17.4, *) else { return "native" }
            control.performPrimaryAction()
            return "control"
        }
        if performBarButton(parameters, control: control) { return "control" }
        return element.accessibilityActivate() ? "activated" : "native:\(NSStringFromClass(type(of: element)))"
    }

    private static func performVisibleMenuAction(_ title: String) -> Bool {
        guard !title.isEmpty else { return false }
        func action(in menu: UIMenu) -> UIAction? {
            for child in menu.children {
                if let item = child as? UIAction, item.title == title, !item.attributes.contains(.disabled) { return item }
                if let submenu = child as? UIMenu, let item = action(in: submenu) { return item }
            }
            return nil
        }
        func perform(in view: UIView) -> Bool {
            guard !view.isHidden, view.alpha > 0 else { return false }
            if let control = view as? UIControl, let interaction = control.contextMenuInteraction {
                var selected: UIAction?
                interaction.updateVisibleMenu { menu in
                    selected = action(in: menu)
                    return menu
                }
                if let selected {
                    interaction.dismissMenu()
                    control.sendAction(selected)
                    return true
                }
            }
            return view.subviews.contains(where: perform)
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .filter { !$0.isHidden && $0.windowLevel == .normal }.contains(where: perform)
    }

    private static func control(for target: NSObject) -> UIControl? {
        if let control = target as? UIControl { return control }
        let frame = target.accessibilityFrame
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows.reversed() where !window.isHidden && window.windowLevel == .normal {
            let point = window.convert(CGPoint(x: frame.midX, y: frame.midY), from: window.screen.coordinateSpace)
            var hit = window.hitTest(point, with: nil)
            while let view = hit, !(view is UIControl) { hit = view.superview }
            if let control = hit as? UIControl { return control }
        }
        return nil
    }

    private static func performBarButton(_ parameters: [String: String], control: UIControl?) -> Bool {
        let id = parameters["identifier"] ?? ""
        let label = parameters["label"] ?? ""
        func find(in view: UIView) -> UIBarButtonItem? {
            guard !view.isHidden, view.alpha > 0, !view.accessibilityElementsHidden else { return nil }
            if let bar = view as? UINavigationBar, let window = bar.window,
               bar.convert(bar.bounds, to: window).intersects(window.bounds), let item = bar.topItem {
                for button in (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? []) where button.isEnabled && button.menu == nil {
                    if !id.isEmpty && button.accessibilityIdentifier == id
                        || !label.isEmpty && [button.title, button.accessibilityLabel, button.primaryAction?.title].contains(label) {
                        return button
                    }
                }
            }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows.reversed() where !window.isHidden && window.windowLevel == .normal {
            guard var controller = window.rootViewController else { continue }
            while let presented = controller.presentedViewController { controller = presented }
            guard !platform(controller), let item = find(in: controller.view) else { continue }
            if let action = item.primaryAction, let control, control.isEnabled {
                control.sendAction(action)
                return true
            }
            if item.primaryAction == nil, let action = item.action,
               UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil) { return true }
        }
        return false
    }

    static func resolve(_ parameters: [String: String]) throws -> Data {
        guard let element = button(parameters) ?? button(parameters, partialLabel: true) else { return Data("native".utf8) }
        return try JSONEncoder().encode([
            "identifier": identifier(of: element) ?? "",
            "label": element.accessibilityLabel ?? "",
        ])
    }

    private static func identifier(of object: NSObject) -> String? {
        object.responds(to: NSSelectorFromString("accessibilityIdentifier"))
            ? object.value(forKey: "accessibilityIdentifier") as? String : nil
    }

    private static func button(_ parameters: [String: String], partialLabel: Bool = false) -> NSObject? {
        let identifier = parameters["identifier"] ?? ""
        let label = parameters["label"] ?? ""
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.accessibilityElementsHidden { return nil }
            if let view = object as? UIView, view.isHidden || view.alpha == 0 { return nil }
            if object.accessibilityTraits.contains(.adjustable) { return nil }
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for index in (0..<count).reversed() {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let result = find(child) { return result }
                }
            }
            if let view = object as? UIView {
                for child in view.subviews.reversed() {
                    if let result = find(child) { return result }
                }
            }
            let actualIdentifier = Self.identifier(of: object)
            let actualLabel = object.accessibilityLabel ?? ""
            if object.isAccessibilityElement && object.accessibilityTraits.contains(.button),
               (!identifier.isEmpty && actualIdentifier == identifier) ||
                (identifier.isEmpty && (partialLabel ? actualLabel.contains(label) : actualLabel == label)) {
                return object
            }
            return nil
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.windowLevel == .normal }.reversed()
        for window in windows {
            guard var controller = window.rootViewController else { continue }
            while let presented = controller.presentedViewController { controller = presented }
            guard !platform(controller) else { continue }
            func hasSystemPicker(_ view: UIView) -> Bool {
                view is UIDatePicker || view is UIPickerView || view.subviews.contains(where: hasSystemPicker)
            }
            if hasSystemPicker(controller.view) { continue }
            if let element = find(controller.view) { return element }
        }
        return nil
    }
}

/// 场景参数在同一个进程中更新，传输夹具与页面共同读取这份配置。
@MainActor
final class UITestSceneConfiguration {
    static let shared = UITestSceneConfiguration()
    private var values = ProcessInfo.processInfo.environment
    private var revision = 0

    var snapshot: (environment: [String: String], revision: Int) {
        return (values, revision)
    }

    func replace(with environment: [String: String]) {
        values = environment
        revision += 1
    }
}


enum AppUITestBootstrap {
    static var environment: [String: String] { UITestSceneConfiguration.shared.snapshot.environment }

    static func prepareSessionIfNeeded() async {
        let environment = Self.environment
        guard environment["BIT101_UI_TEST_RESET_STORAGE"] == "1",
              let account = environment["BIT101_UI_TEST_ACCOUNT"], !account.isEmpty else { return }
        do {
            _ = try await UITestLoginService().login(studentID: account, password: "ui-test-password")
            if environment["BIT101_UI_TEST_MEDIA"] == "1" {
                let image = ComposerImageDraftSnapshot(filename: "ui-image.png", previewData: mediaData, uploadData: mediaData)
                let drafts = AppAccountStores.shared.composerDrafts
                guard await drafts.saveGallery(GalleryComposerDraftSnapshot(title: "图片测试草稿", text: "图片草稿正文",
                    selectedTags: [], customTags: [], anonymous: false, isPublic: true, selectedClaimID: 0, images: [image])),
                      await drafts.saveSuggestion(DeveloperSuggestionDraftSnapshot(text: "图片建议草稿", images: [image], contact: "测试联系信息")) else {
                    throw URLError(.cannotWriteToFile)
                }
            }
        } catch {
            preconditionFailure("UI test session preparation failed: \(error)")
        }
    }

    static func prepareForLaunch() {
        let environment = Self.environment
        guard AppFileDirectories.isRunningUITest else {
            preconditionFailure("The UI automation App requires its isolated launch configuration")
        }
        UIView.setAnimationsEnabled(environment["BIT101_UI_TEST_ANIMATIONS"] == "1")
        UIApplication.shared.isIdleTimerDisabled = true
        guard environment["BIT101_UI_TEST_RESET_STORAGE"] == "1" else { return }

        AppFileDirectories.defaults.removePersistentDomain(
            forName: AppFileDirectories.uiTestDefaultsSuiteName
        )
        LoginStorage.resetUITestCredentials()

        let supportDirectory = AppFileDirectories.applicationSupportDirectoryURL(named: "BIT101-iOS")
        guard AppFileDirectories.files.fileExists(at: supportDirectory) else { return }
        do {
            try AppFileDirectories.files.removeItem(at: supportDirectory)
        } catch {
            preconditionFailure("UI test account storage cleanup failed: \(error)")
        }
    }
}

extension AppUITestBootstrap {
    static var mediaData: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
    }
}

extension View {
    /// 外部链接的 UI 场景读取页面实际发出的地址。
    func uiTestExternalURLs() -> some View {
        environment(\.openURL, OpenURLAction { url in
            AppErrorPresenter.shared.present(AppAlert.informational(title: "打开链接", message: url.absoluteString))
            return .handled
        })
    }
}

/// 固定响应通过生产 Service 解码，交互修改保留到当前测试场景结束。
final class UITestHTTPTransport: HTTPTransport {
    private var fixtureRevision = -1
    private var likedObjects: Set<String> = []
    private var comments: [[String: Any]] = []
    private var createdPosters: [[String: Any]] = []
    private var createdPapers: [[String: Any]] = []
    private var deletedIDs: Set<Int> = []
    private var deletedCommentIDs: Set<Int> = []
    private var profileChanges: [String: Any] = [:]
    private var posterChanges: [String: Any] = [:]
    private var following = false
    private var imageUploads = 0
    private var failedPaths: Set<String> = []
    private let timestamp = "2026-10-01T10:00:00Z"

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let snapshot = UITestSceneConfiguration.shared.snapshot
        if fixtureRevision != snapshot.revision {
            fixtureRevision = snapshot.revision
            likedObjects = []
            comments = []
            createdPosters = []
            createdPapers = []
            deletedIDs = []
            deletedCommentIDs = []
            profileChanges = [:]
            posterChanges = [:]
            following = false
            imageUploads = 0
            failedPaths = []
        }
        guard let url = request.url else { throw URLError(.badURL) }
        if url.host == "feedback.aihelpme.dev", AppUITestBootstrap.environment["BIT101_UI_TEST_CONTENT"] == "1" {
            return try jsonResponse([:] as [String: String], url: url)
        }
        if url.host == "itunes.apple.com", let fixture = AppUITestBootstrap.environment["BIT101_UI_TEST_UPDATE"] {
            return try jsonResponse(["results": [["version": fixture == "current" ? "0.0" : "999.0",
                "releaseNotes": "自动化测试更新", "trackViewUrl": BIT101AppStore.url.absoluteString]]], url: url)
        }
        guard AppUITestBootstrap.environment["BIT101_UI_TEST_CONTENT"] == "1",
              url.host == "bit101.flwfdd.xyz" else {
            throw URLError(.notConnectedToInternet)
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if AppUITestBootstrap.environment["BIT101_UI_TEST_FAILURE_ONCE"] == "1",
           ["posters", "papers", "courses"].contains(path), failedPaths.insert(path).inserted {
            throw URLError(.networkConnectionLost)
        }
        if path.hasPrefix("ui-images/") {
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"]) else {
                throw URLError(.badServerResponse)
            }
            return (AppUITestBootstrap.mediaData, response)
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = query.first(where: { $0.name == "page" })?.value ?? "0"
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        let method = request.httpMethod ?? "GET"
        let payload: Any
        switch path {
        case "posters/claims": payload = [["id": 1, "text": "日常"]]
        case "manage/report_types": payload = [["id": 1, "text": "其他"]]
        case "manage/reports": payload = [:] as [String: String]
        case "upload/image":
            imageUploads += 1
            if imageUploads == 1 { throw URLError(.networkConnectionLost) }
            payload = mediaImage
        case "messages/unread_nums": payload = ["comment": 1, "follow": 1, "like": 1, "system": 1]
        case "messages":
            payload = query.contains(where: { $0.name == "last_id" }) ? [] : [[
                "id": 1, "from_user": user, "link_obj": "poster1", "obj": "poster1",
                "text": "自动化测试消息", "update_time": timestamp,
            ]]
        case "reaction/like":
            let object = body["obj"] as? String ?? "poster1"
            if likedObjects.contains(object) { likedObjects.remove(object) } else { likedObjects.insert(object) }
            payload = ["like": likedObjects.contains(object), "like_num": likedObjects.contains(object) ? 2 : 1]
        case "reaction/comments":
            if method == "POST" {
                var comment = makeComment(id: comments.count + 2, text: body["text"] as? String ?? "测试回复")
                comment["reply_obj"] = body["reply_obj"] ?? ""
                comment["obj"] = body["obj"] ?? "poster1"
                comments.append(comment)
                payload = comment
            } else {
                payload = page == "0" ? ([makeComment(id: 1, text: "自动化测试评论")] + comments)
                    .filter { !deletedCommentIDs.contains($0["id"] as? Int ?? 0) } : []
            }
        case "posters":
            if method == "POST" {
                var poster = self.poster
                let id = createdPosters.count + 10
                poster["id"] = id
                poster["title"] = body["title"]
                poster["text"] = body["text"]
                poster["tags"] = body["tags"]
                poster["anonymous"] = body["anonymous"]
                poster["public"] = body["public"]
                createdPosters.append(poster)
                payload = ["id": id]
            } else {
                payload = page == "0" ? ([poster] + createdPosters).filter { !deletedIDs.contains($0["id"] as? Int ?? 0) } : []
            }
        case "papers":
            if method == "POST" {
                var paper = self.paper
                let id = createdPapers.count + 10
                paper["id"] = id
                paper["title"] = body["title"]
                paper["intro"] = body["intro"]
                paper["content"] = body["content"]
                createdPapers.append(paper)
                payload = ["id": id]
            } else {
                payload = page == "0" ? ([paper] + createdPapers).filter { !deletedIDs.contains($0["id"] as? Int ?? 0) } : []
            }
        case "courses":
            var schoolCourse = course
            schoolCourse["id"] = 2
            schoolCourse["name"] = "学校测试课程"
            schoolCourse["number"] = "UI-002"
            payload = page == "0" ? (AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL"] == "1" ? [course, schoolCourse] : [course]) : []
        case "courses/1": payload = course
        case "courses/2":
            var schoolCourse = course
            schoolCourse["id"] = 2
            schoolCourse["name"] = "学校测试课程"
            schoolCourse["number"] = "UI-002"
            payload = schoolCourse
        case "courses/histories/UI-002": payload = []
        case "courses/histories/UI-001":
            payload = [["term": "2025-2026-1", "avg_score": 85, "max_score": 98, "student_num": 30],
                       ["term": "2025-2026-2", "avg_score": 88, "max_score": 99, "student_num": 35]]
        case "user/followers", "user/followings": payload = page == "0" ? [user] : []
        case "user/info":
            profileChanges.merge(body) { _, new in new }
            payload = [:] as [String: String]
        default:
            if path.hasPrefix("posters/") || path.hasPrefix("papers/") {
                let id = Int(url.lastPathComponent) ?? 1
                if method == "DELETE" { deletedIDs.insert(id) }
                if path.hasPrefix("posters/") {
                    if method == "PUT", id == 1 { posterChanges.merge(body) { _, new in new } }
                    if method == "PUT", let index = createdPosters.firstIndex(where: { $0["id"] as? Int == id }) {
                        for (key, value) in body { createdPosters[index][key] = value }
                    }
                    payload = createdPosters.first(where: { $0["id"] as? Int == id }) ?? poster
                } else {
                    if method == "PUT", let index = createdPapers.firstIndex(where: { $0["id"] as? Int == id }) {
                        for (key, value) in body { createdPapers[index][key] = value }
                    }
                    payload = createdPapers.first(where: { $0["id"] as? Int == id }) ?? paper
                }
            } else if path.hasPrefix("reaction/comments/") {
                if let id = Int(url.lastPathComponent) { deletedCommentIDs.insert(id) }
                payload = [:] as [String: String]
            } else if path.hasPrefix("user/info/") || path.hasPrefix("user/follow/") {
                if path.hasPrefix("user/follow/"), method == "POST" { following.toggle() }
                payload = ["user": user, "following_num": 1, "follower_num": 1,
                           "following": following, "follower": false, "own": path == "user/info/0"]
            } else {
                throw URLError(.unsupportedURL)
            }
        }
        return try jsonResponse(payload, url: url)
    }

    private func jsonResponse(_ payload: Any, url: URL) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    private var user: [String: Any] {
        var base: [String: Any] = ["id": 1, "create_time": timestamp, "nickname": "自动化测试用户", "motto": "测试签名"]
        let emptyAvatar: [String: Any] = ["mid": "", "url": "", "low_url": ""]
        base["avatar"] = mediaEnabled ? mediaImage : emptyAvatar
        base["identity"] = ["id": 1, "color": "#FF9500", "text": "测试", "create_time": timestamp, "update_time": timestamp] as [String: Any]
        return base.merging(profileChanges) { _, new in new }
    }

    private var poster: [String: Any] {
        let base: [String: Any] = ["id": 1, "anonymous": false, "claim": ["id": 1, "text": "日常"], "comment_num": 1,
         "create_time": timestamp, "edit_time": timestamp, "update_time": timestamp,
         "images": mediaEnabled ? [mediaImage] : [], "like": likedObjects.contains("poster1"), "like_num": 1, "own": true,
         "plugins": "[]", "public": true, "tags": ["测试", "自动化"], "text": "自动化测试话题正文", "title": "自动化测试话题", "user": user]
        return base.merging(posterChanges) { _, new in new }
    }

    private var paper: [String: Any] {
        ["id": 1, "title": "自动化测试文章", "intro": "测试文章简介", "content": paperContent,
         "create_time": timestamp, "update_time": timestamp, "update_user": user, "anonymous": false,
         "like_num": 1, "comment_num": 1, "public_edit": true, "like": likedObjects.contains("paper1"), "own": true]
    }

    private var paperContent: String {
        guard mediaEnabled else { return "# 测试文章\n\n自动化测试文章正文" }
        return #"""
        {"blocks":[
          {"id":"ui-header","type":"header","data":{"text":"测试文章","level":1}},
          {"id":"ui-paragraph","type":"paragraph","data":{"text":"自动化测试文章正文"}},
          {"id":"ui-link","type":"paragraph","data":{"text":"<a href=\"https://github.com/BIT101-dev/BIT101-iOS\">正文链接</a>"}},
          {"id":"ui-image","type":"image","data":{"file":{"url":"https://bit101.flwfdd.xyz/ui-images/image.png"},"caption":"测试图片"}}
        ]}
        """#
    }

    private var course: [String: Any] {
        ["id": 1, "name": "自动化测试课程", "number": "UI-001", "credit": 3, "like_num": 1,
         "comment_num": 1, "rate": 4, "teachers_name": "测试教师", "teachers_number": "T001",
         "like": likedObjects.contains("course1")]
    }

    private func makeComment(id: Int, text: String) -> [String: Any] {
        var replyUser = user
        replyUser["id"] = 0
        replyUser["nickname"] = ""
        return ["id": id, "obj": "comment\(id)", "images": mediaEnabled ? [mediaImage] : [], "user": user, "anonymous": false,
         "create_time": timestamp, "update_time": timestamp, "like": likedObjects.contains("comment\(id)"), "like_num": likedObjects.contains("comment\(id)") ? 1 : 0,
         "comment_num": 0, "own": true, "rate": 4, "reply_user": replyUser, "reply_obj": "", "text": text, "sub": []]
    }
}

extension UITestHTTPTransport {
    private var mediaEnabled: Bool { AppUITestBootstrap.environment["BIT101_UI_TEST_MEDIA"] == "1" }
    private var mediaImage: [String: Any] {
        ["mid": "ui-image", "url": "https://bit101.flwfdd.xyz/ui-images/image.png", "low_url": "https://bit101.flwfdd.xyz/ui-images/image.png"]
    }
}

@MainActor
final class UITestPreferenceCloudStore: PreferenceCloudStoring {
    private(set) var dictionaryRepresentation: [String: Any] = [:]
    func data(forKey key: String) -> Data? { dictionaryRepresentation[key] as? Data }
    func set(_ value: Any?, forKey key: String) { dictionaryRepresentation[key] = value }
    func synchronize() -> Bool { true }
}

/// UI 宿主的文件与缓存目录归固定测试根路径。
nonisolated struct UITestAppFileService: AppFileService {
    private let local = LocalAppFileService()
    private var root: URL {
        guard let support = local.directoryURL(.applicationSupportDirectory) else {
            preconditionFailure("UI test Application Support directory is unavailable")
        }
        return support.appending(path: "BIT101-UITests", directoryHint: .isDirectory)
    }
    func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL? {
        root.appending(path: String(directory.rawValue), directoryHint: .isDirectory)
    }
    func appGroupContainerURL(identifier: String) -> URL? { root.appending(path: "AppGroup", directoryHint: .isDirectory) }
    var temporaryDirectoryURL: URL { root.appending(path: "Temporary", directoryHint: .isDirectory) }
    func fileExists(at url: URL) -> Bool { local.fileExists(at: url) }
    func readData(at url: URL) throws -> Data { try local.readData(at: url) }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws { try local.writeData(data, to: url, options: options) }
    func createDirectory(at url: URL) throws { try local.createDirectory(at: url) }
    func removeItem(at url: URL) throws { try local.removeItem(at: url) }
    func setPrivateFileProtection(at url: URL) throws { try local.setPrivateFileProtection(at: url) }
    func setExcludedFromBackup(at url: URL) throws { try local.setExcludedFromBackup(at: url) }
    func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] { try local.contentsOfDirectory(at: url, options: options) }
    func regularFileSize(at url: URL) -> Int? { local.regularFileSize(at: url) }
    func isRegularFile(at url: URL) -> Bool { local.isRegularFile(at: url) }
    func modificationDate(at url: URL) -> Date? { local.modificationDate(at: url) }
    func setModificationDate(_ date: Date, at url: URL) throws { try local.setModificationDate(date, at: url) }
    func removeContents(of directory: URL) -> Bool { local.removeContents(of: directory) }
    func totalRegularFileSize(at directory: URL) -> Int64 { local.totalRegularFileSize(at: directory) }
    func canonicalFileURL(_ url: URL) -> URL { local.canonicalFileURL(url) }
}

/// 学校交互场景使用课程、考试和空教室端口的固定响应。
final class UITestSchoolService: ScheduleServicing {
    private var authenticated = AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL_SMS"] != "1"
    private let challenge = BITLoginAuthenticationChallenge(challengeID: "ui-school-sms", accessToken: "ui-school-token",
        status: "sms_required", maskedPhone: "138****0000", expiresIn: 600)
    static var payload: CourseSyncPayload { payload(term: "ui-test-term") }

    private static func payload(term: String) -> CourseSyncPayload {
        let firstDay = ScheduleDateCodec.formatDate(ScheduleDateCodec.monday(containing: Date()))
        return CourseSyncPayload(term: term, firstDayString: firstDay, sourceFirstDayString: firstDay,
            normalizationOffset: 0, rawWeeksByCourse: [[1, 2, 3]], courses: [
                CourseRecord(id: "ui-school", term: term, name: "学校测试课程", teacher: "测试教师",
                    classroom: "文萃A101", description: "学校课程详情", weeks: [1, 2, 3], weekday: 1,
                    startSection: 1, endSection: 2, campus: "良乡校区", number: "UI-002", credit: 2,
                    hour: 32, type: "必修", category: "专业", department: "测试学院")
            ], exams: [
                ExamRecord(id: "ui-exam", term: term, name: "测试考试", courseID: "UI-002",
                    teacher: "测试教师", classroom: "文萃A101", dateString: firstDay,
                    beginTime: "10:00", endTime: "11:00", examMode: "闭卷", seatID: "1")
            ])
    }

    func syncCourses(term: String?) async throws -> CourseSyncPayload {
        guard authenticated else { throw ScheduleServiceError.secondFactorRequired(challenge) }
        return Self.payload(term: term ?? "ui-test-term")
    }
    func fetchAvailableTerms() async throws -> [String] {
        guard authenticated else { throw ScheduleServiceError.secondFactorRequired(challenge) }
        return ["ui-test-term", "ui-test-term-2"]
    }
    func fetchCurrentTermOnly() async throws -> String { "ui-test-term" }
    func prepareTeachingCenterAccess() async throws {}
    func submitSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge, term: String?) async throws -> CourseSyncPayload {
        try verify(code)
        return try await syncCourses(term: term)
    }
    func submitSMSCodeForTeachingCenterAuthentication(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws { try verify(code) }
    func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> DDLSyncPayload {
        if !authenticated, let schoolSMSCodeHandler {
            try verify(await schoolSMSCodeHandler(SchoolSMSCodeRequest(maskedPhone: "138****0000", purpose: "测试学校认证")))
        }
        return DDLSyncPayload(url: "https://lexue.bit.edu.cn/ui-test.ics", events: [
            DDLEventRecord(id: "eclass:ui", group: "eclass", title: "课程中心测试作业", text: "刷新后的学校详情",
                dueAt: Date().addingTimeInterval(86400), done: false)
        ], syncedGroups: ["eclass", "lexue"])
    }
    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String { "https://lexue.bit.edu.cn/ui-test.ics" }
    func fetchCampuses() async throws -> [CampusRecord] {
        [CampusRecord(id: "1", name: "良乡校区", code: "1"), CampusRecord(id: "2", name: "中关村校区", code: "2")]
    }
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] {
        [BuildingRecord(id: "A", name: "文萃楼A", buildingCode: "A", campusName: "良乡校区", campusCode: campusCode ?? "1"),
         BuildingRecord(id: "B", name: "文萃楼B", buildingCode: "B", campusName: "良乡校区", campusCode: campusCode ?? "1")]
    }
    func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord] {
        [ClassroomRecord(id: buildingID + "101", name: buildingID + "101", busyTimeCodes: [])]
    }
    private func verify(_ code: String) throws {
        guard code == "123456" else { throw ScheduleServiceError.schoolSMSCodeInvalid("测试学校验证码错误。") }
        authenticated = true
    }
}

/// 日历确认分支通过应用层端口记录测试场景的导入及移除状态。
@MainActor
final class UITestSchedulePlatformActions: SchedulePlatformActions {
    private var imported = false
    func enableCloudSync(session: AppStorageSession) async {}
    func enableCourseReminder(session: AppStorageSession) async {}
    func importSystemCalendar(courses: ScheduleCourseSnapshot, term: String) async throws -> Int { imported = true; return 1 }
    func importSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> Int { imported = true; return 1 }
    func deleteSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> ScheduleSystemCalendarMutationResult { remove() }
    func deleteSystemCalendarEntries(markerIDs: Set<String>, term: String) async throws -> ScheduleSystemCalendarMutationResult { remove() }
    func deleteImportedSystemCalendarEvents() async throws -> ScheduleSystemCalendarMutationResult { remove() }
    private func remove() -> ScheduleSystemCalendarMutationResult {
        let result: ScheduleSystemCalendarMutationResult = imported ? .changed(1) : .noOp
        imported = false
        return result
    }
}
#endif
