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

    static func invalidate() {
        cachedTree = nil
        treeBuilt = false
    }

    static func record(_ identifier: String) {
        if !identifier.isEmpty { visited.insert(identifier) }
    }

    static func coverage() throws -> Data {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return try JSONSerialization.data(withJSONObject: [
            "observed": observed.union(visited).count, "visited": visited.count,
            "pending": observed.subtracting(visited).sorted(),
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
            if control?.showsMenuAsPrimaryAction == true { return Data("native".utf8) }
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
#endif
