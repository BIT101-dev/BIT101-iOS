#if BIT101_UI_TESTING
import Foundation
import UIKit
import PhotosUI
import QuickLook

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
    private static var visitedControls: [String: [String: Any]] = [:]
    private static var disabledObserved = Set<String>()
    private static var disabledChecked = Set<String>()
    private static var unidentified = Set<String>()
    private static var currentScope = ""
    private static weak var presentedController: UIViewController?
    private static weak var occlusionView: UIView?
    private static var presentationGeneration = 0

    static func invalidate() {
        cachedTree = nil
        treeBuilt = false
    }

    static func record(_ identifier: String, label: String = "", type: Int = 0, scope: String? = nil, instance: String? = nil, action: String = "activate") {
        let key = identifier.isEmpty && !label.isEmpty ? "\(type):\(label)" : identifier
        let identity = instance.flatMap { $0.isEmpty ? nil : $0 } ?? (scope ?? currentScope) + ":" + key + "#0"
        if !key.isEmpty {
            visited.insert(identity)
            let actions = Set(visitedControls[identity]?["actions"] as? [String] ?? []).union([action])
            visitedControls[identity] = ["identifier": identifier, "label": label, "type": type, "scope": scope ?? currentScope, "instance": identity, "actions": actions.sorted()]
        }
    }

    private static func record(_ attributes: [String: Any]) {
        record(attributes["identifier"] as? String ?? "", label: attributes["label"] as? String ?? "",
               type: attributes["elementType"] as? Int ?? 0, scope: attributes["scope"] as? String, instance: attributes["instance"] as? String)
    }

    static func checkDisabled(_ identifier: String, label: String, type: Int, scope: String?, instance: String?) {
        let key = identifier.isEmpty && !label.isEmpty ? "\(type):\(label)" : identifier
        if let instance, !instance.isEmpty { disabledChecked.insert(instance) }
        else if !key.isEmpty { disabledChecked.insert((scope ?? currentScope) + ":" + key + "#0") }
    }

    static func identity(_ parameters: [String: String]) -> String {
        guard let tree = tree() else { return "" }
        let identifier = parameters["identifier"] ?? ""
        let frame = ["x", "y", "width", "height"].compactMap { parameters[$0].flatMap(Double.init) }
        guard frame.count == 4 else { return "" }
        let matches = tree.descendants.filter { element in
            let attributes = element.attributes
            guard let bounds = attributes["frame"] as? [Double], bounds.count == 4,
                attributes["elementType"] as? Int == Int(parameters["type"] ?? ""),
                identifier.isEmpty ? attributes["label"] as? String == parameters["label"] : attributes["identifier"] as? String == identifier
            else { return false }
            return zip(bounds, frame).allSatisfy { abs($0 - $1) <= 1 }
        }
        return matches.count == 1 ? matches[0].attributes["instance"] as? String ?? "" : ""
    }

    @discardableResult
    static func observe() -> String { _ = tree(); return currentScope }

    static func occlude(_ parameters: [String: String]) -> String {
        occlusionView?.removeFromSuperview()
        invalidate()
        guard parameters["enabled"] == "1" else { return "cleared" }
        guard let target = tree()?.descendants.first(where: { $0.attributes["identifier"] as? String == parameters["identifier"] })?.object,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).last(where: { !$0.isHidden && $0.windowLevel == .normal }),
              var controller = window.rootViewController else { return "target missing" }
        while let presented = controller.presentedViewController { controller = presented }
        let overlay = UIView(frame: controller.view.convert(target.accessibilityFrame, from: window.screen.coordinateSpace))
        overlay.backgroundColor = .systemBackground
        overlay.isAccessibilityElement = true
        overlay.accessibilityIdentifier = "ui-test.occlusion"
        overlay.accessibilityLabel = "遮挡测试覆盖层"
        controller.view.addSubview(overlay)
        occlusionView = overlay
        return "covered"
    }

    static func coverage() throws -> Data {
        observe()
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return try JSONSerialization.data(withJSONObject: [
            "observed": observed.union(visited).count, "visited": visited.count,
            "pending": observed.subtracting(visited).sorted(),
            "visitedControls": Array(visitedControls.values),
            "scope": "mounted-controls", "unidentifiedControls": unidentified.count,
            "disabledObserved": disabledObserved.count,
            "pendingDisabled": disabledObserved.subtracting(disabledChecked).sorted(),
            "identityScope": "testCaseNavigationPresentationAndOccurrence",
            "animationSpeeds": windows.filter { $0.windowLevel == .normal }.map { $0.layer.speed },
            "animationsEnabled": UIView.areAnimationsEnabled,
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
            record(parameters["identifier"] ?? "", label: parameters["label"] ?? "", type: 9)
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
                if format.contains("hittable") { return Data("native".utf8) }
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
            if control?.showsMenuAsPrimaryAction == true { return Data("native".utf8) }
            if let control, control.isEnabled,
               control.isContextMenuInteractionEnabled {
                guard identifier(of: target) == "BackButton" else { return Data("native".utf8) }
                guard #available(iOS 17.4, *) else { return Data("native".utf8) }
                control.performPrimaryAction()
                record(element.attributes)
                return Data("control".utf8)
            }
            if let control = control as? UISwitch, control.isEnabled {
                control.setOn(!control.isOn, animated: false)
                control.sendActions(for: .valueChanged)
                record(element.attributes)
                return Data("control".utf8)
            }
            if performBarButton(["identifier": element.attributes["identifier"] as? String ?? "", "label": element.attributes["label"] as? String ?? ""], control: control) {
                record(element.attributes)
                return Data("control".utf8)
            }
            if target.accessibilityActivate() {
                record(element.attributes)
                return Data("activated".utf8)
            }
            if let control, control.isEnabled,
               control.allControlEvents.contains(.primaryActionTriggered) || control.allControlEvents.contains(.touchUpInside) {
                control.sendActions(for: control.allControlEvents.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside)
                record(element.attributes)
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
            guard let element = elements.first, parameters["hittable"] == "1",
                  let frame = element.attributes["frame"] as? [Double] else { return Data("native".utf8) }
            invalidate()
            let response = input(["x": String(frame[0] + frame[2] / 2), "y": String(frame[1] + frame[3] / 2),
                                  "text": parameters["text"] ?? ""])
            if response == "entered" { record(element.attributes) }
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
        func navigationPath(in view: UIView) -> [String] {
            guard !view.isHidden, view.alpha > 0 else { return [] }
            if let bar = view as? UINavigationBar { return (bar.items ?? []).compactMap(\.title) }
            if let bar = view as? UITabBar { return [bar.selectedItem?.title].compactMap { $0 } }
            return view.subviews.flatMap { navigationPath(in: $0) }
        }
        let scenario = AppUITestBootstrap.environment["BIT101_UI_TEST_CASE"] ?? "UIAutomation"
        let navigation = navigationPath(in: controller.view)
        var modal = [(controller as? UIAlertController)?.title].compactMap { $0 }
        if controller !== window.rootViewController {
            if presentedController !== controller { presentationGeneration += 1; presentedController = controller }
            modal.append("presentation:\(presentationGeneration)")
        } else { presentedController = nil }
        currentScope = ([scenario] + navigation + modal).joined(separator: " / ")
        var visited = Set<ObjectIdentifier>()
        var occurrences: [String: Int] = [:]
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
            case is UISlider: type = 33
            case is UIStepper: type = 79
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
            var container: Any? = object
            var ancestors = Set<ObjectIdentifier>()
            while let element = container as? NSObject, ancestors.insert(ObjectIdentifier(element)).inserted {
                if let view = element as? UIView {
                    if type == 9, let segmented = view as? UISegmentedControl, segmented.selectedSegmentIndex >= 0,
                       let title = segmented.titleForSegment(at: segmented.selectedSegmentIndex) {
                        selected = label == title
                    }
                    container = view.superview
                } else { container = (element as? UIAccessibilityElement)?.accessibilityContainer }
            }
            var instance = ""
            if object.isAccessibilityElement && [9, 33, 37, 40, 41, 42, 45, 49, 50, 52, 79].contains(type) {
                if id.isEmpty && label.isEmpty { unidentified.insert("\(currentScope):\(type)") }
                else {
                    let key = currentScope + ":" + (id.isEmpty ? "\(type):\(label)" : id)
                    let ordinal = occurrences[key, default: 0]
                    occurrences[key] = ordinal + 1
                    instance = key + "#\(ordinal)"
                    if enabled { observed.insert(instance) } else { disabledObserved.insert(instance) }
                }
            }
            var attributes: [String: Any] = [
                "identifier": id, "label": label, "elementType": type,
                "scope": currentScope,
                "instance": instance,
                "placeholderValue": placeholder,
                "exists": true, "enabled": enabled,
                "selected": selected,
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
            "enabled": true, "selected": false,
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
#endif
