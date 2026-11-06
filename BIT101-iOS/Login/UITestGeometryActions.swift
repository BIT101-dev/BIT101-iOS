#if BIT101_UI_TESTING || EXTENDED_AUTOMATION
nonisolated enum UITestControlIdentity {
    static func key(
        scope: String, ancestors: [String], identifier: String, label: String, type: Int
    ) -> String {
        let control = identifier.isEmpty ? "\(type):\(label)" : identifier
        var path = ancestors
        while !identifier.isEmpty && path.last == identifier { path.removeLast() }
        return ([scope] + path + [control]).map { "\($0.utf8.count):\($0)" }.joined(
            separator: ":")
    }
}

nonisolated enum UITestScrollGeometry {
    static func visibleDistance(_ points: Double, scale: Double) -> Double {
        max(0, (points * scale).rounded()) / scale
    }
}
#endif

#if BIT101_UI_TESTING
import StorageCore
import Foundation
import UIKit
import MapKit
import PhotosUI
import QuickLook

extension UITestAccessibilityActions {
    static func elementType(
        _ object: NSObject, window: UIWindow, accessible: Bool,
        traits: UIAccessibilityTraits, frame: CGRect
    ) -> (Int, UIView?) {
        var inputView: UIView?
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
            if accessible && traits.contains(.toggleButton) {
                type = 40
            } else if accessible && traits.contains(.link) {
                type = 42
            } else if accessible && traits.contains(.button) {
                type = 9
            } else if accessible, !frame.isEmpty {
                let point = window.convert(
                    CGPoint(x: frame.midX, y: frame.midY),
                    from: window.screen.coordinateSpace)
                inputView = window.hitTest(point, with: nil)
                while let view = inputView, !(view is UITextField || view is UITextView) {
                    inputView = view.superview
                }
                if let input = inputView as? UITextField {
                    type = input.isSecureTextEntry ? 50 : 49
                } else if inputView is UITextView {
                    type = 52
                } else {
                    type = traits.contains(.staticText) ? 48 : 1
                }
            } else {
                type = 1
            }
        }
        return (type, inputView)
    }

    static func mapCamera() throws -> Data {
        func find(in view: UIView) -> MKMapView? {
            guard !view.isHidden, view.alpha > 0 else { return nil }
            if let map = view as? MKMapView, let window = map.window,
                map.convert(map.bounds, to: window).intersects(window.bounds)
            {
                return map
            }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.windowLevel == .normal }
        guard let map = windows.lazy.compactMap({ find(in: $0) }).first else {
            throw NSError(
                domain: "BIT101.UITest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "地图相机采样需要当前可见的原生地图。"])
        }
        return try JSONSerialization.data(withJSONObject: [
            "latitude": map.region.center.latitude, "longitude": map.region.center.longitude,
            "latitudeDelta": map.region.span.latitudeDelta,
            "longitudeDelta": map.region.span.longitudeDelta,
            "distance": map.camera.centerCoordinateDistance,
            "configuration": String(describing: type(of: map.preferredConfiguration)),
            "scrollEnabled": map.isScrollEnabled, "zoomEnabled": map.isZoomEnabled,
        ])
    }

    static func previewPage(details: Bool = false) throws -> Data {
        func find(in controller: UIViewController) -> QLPreviewController? {
            if let preview = controller as? QLPreviewController,
                preview.viewIfLoaded?.window != nil
            {
                return preview
            }
            if let presented = controller.presentedViewController,
                let preview = find(in: presented)
            {
                return preview
            }
            return controller.children.lazy.compactMap { find(in: $0) }.first
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.windowLevel == .normal }
        guard
            let preview = windows.compactMap(\.rootViewController).lazy.compactMap({
                find(in: $0)
            }).first,
            let source = preview.dataSource
        else {
            throw NSError(
                domain: "BIT101.UITest", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "预览分页采样需要当前展示的系统预览器。"])
        }
        var result: [String: Any] = [
            "index": preview.currentPreviewItemIndex,
            "count": source.numberOfPreviewItems(in: preview),
        ]
        if details {
            result["items"] = (0..<source.numberOfPreviewItems(in: preview)).map {
                index -> [String: Any] in
                let item = source.previewController(preview, previewItemAt: index)
                guard let url = item.previewItemURL else {
                    return ["index": index, "readable": false]
                }
                let data = try? AppFileDirectories.files.readData(at: url)
                return [
                    "index": index, "extension": url.pathExtension,
                    "readable": data != nil,
                    "imageDecodable": data.flatMap { UIImage(data: $0) } != nil,
                    "canPreview": QLPreviewController.canPreview(item),
                ]
            }
            func viewTypes(_ view: UIView) -> [String] {
                [String(describing: type(of: view))] + view.subviews.flatMap(viewTypes)
            }
            result["viewTypes"] = viewTypes(preview.view)
        }
        return try JSONSerialization.data(withJSONObject: result)
    }

    static func scroll(_ parameters: [String: String]) throws -> Data {
        invalidate()
        let elements =
            tree()?.descendants.filter {
                [26, 32, 46].contains($0.attributes["elementType"] as? Int ?? 0)
                    && !($0.attributes["instance"] as? String ?? "").isEmpty
                    && $0.object is UIScrollView
            } ?? []
        if parameters["command"] == "scroll-inventory" {
            return try JSONSerialization.data(
                withJSONObject: elements.compactMap { element -> [String: Any]? in
                    guard let scroll = element.object as? UIScrollView, scroll.isScrollEnabled,
                        let window = scroll.window, let scene = window.windowScene,
                        scroll.convert(scroll.bounds, to: window).intersects(window.bounds)
                    else { return nil }
                    var values = element.attributes
                    values["scrollInstance"] = String(describing: ObjectIdentifier(scroll))
                    values["hasRefreshControl"] = scroll.refreshControl != nil
                    values["refreshing"] = scroll.refreshControl?.isRefreshing ?? false
                    values["scrolling"] =
                        scroll.isDragging || scroll.isDecelerating || scroll.isTracking
                    values["bounces"] = scroll.bounces
                    values["alwaysBounceVertical"] = scroll.alwaysBounceVertical
                    let insets = scroll.adjustedContentInset
                    let viewport = scroll.convert(
                        scroll.bounds.inset(
                            by: UIEdgeInsets(
                                top: insets.top, left: 0,
                                bottom: insets.bottom, right: 0)), to: window
                    )
                    .intersection(window.safeAreaLayoutGuide.layoutFrame)
                    if !viewport.isEmpty {
                        let visible = window.convert(viewport, to: scene.screen.coordinateSpace)
                        values["viewport"] = [
                            Double(visible.minX), Double(visible.minY), Double(visible.width),
                            Double(visible.height),
                        ]
                    }
                    let scale = Double(window.screen.scale)
                    func distance(_ points: CGFloat) -> Double {
                        UITestScrollGeometry.visibleDistance(Double(points), scale: scale)
                    }
                    values["offset"] = [
                        Double(scroll.contentOffset.x), Double(scroll.contentOffset.y),
                    ]
                    values["range"] = [
                        distance(
                            scroll.contentSize.width + scroll.adjustedContentInset.left
                                + scroll.adjustedContentInset.right - scroll.bounds.width),
                        distance(
                            scroll.contentSize.height + scroll.adjustedContentInset.top
                                + scroll.adjustedContentInset.bottom - scroll.bounds.height),
                    ]
                    values["remaining"] = [
                        distance(
                            scroll.contentSize.width + scroll.adjustedContentInset.right
                                - scroll.bounds.width - scroll.contentOffset.x),
                        distance(
                            scroll.contentSize.height + scroll.adjustedContentInset.bottom
                                - scroll.bounds.height - scroll.contentOffset.y),
                    ]
                    return values
                })
        }
        guard
            let element = elements.first(where: { element in
                guard let scroll = element.object as? UIScrollView else { return false }
                return String(describing: ObjectIdentifier(scroll))
                    == parameters["scrollInstance"]
            }),
            let scroll = element.object as? UIScrollView,
            let window = scroll.window,
            let x = parameters["offsetX"].flatMap(Double.init),
            let y = parameters["offsetY"].flatMap(Double.init)
        else { return Data("target missing".utf8) }
        if parameters["command"] == "scroll-restore" {
            guard !scroll.isDragging, !scroll.isDecelerating, !scroll.isTracking else {
                return Data("scrolling".utf8)
            }
            scroll.setContentOffset(CGPoint(x: x, y: y), animated: false)
            scroll.layoutIfNeeded()
            invalidate()
            let tolerance = 1 / window.screen.scale
            let restored =
                abs(scroll.contentOffset.x - x) <= tolerance
                && abs(scroll.contentOffset.y - y) <= tolerance
            return Data((restored ? "restored" : "layout pending").utf8)
        }
        let scale = Double(window.screen.scale)
        let fits =
            UITestScrollGeometry.visibleDistance(
                Double(
                    scroll.contentSize.width + scroll.adjustedContentInset.left
                        + scroll.adjustedContentInset.right - scroll.bounds.width), scale: scale
            ) == 0
            && UITestScrollGeometry.visibleDistance(
                Double(
                    scroll.contentSize.height + scroll.adjustedContentInset.top
                        + scroll.adjustedContentInset.bottom - scroll.bounds.height),
                scale: scale) == 0
        guard fits || scroll.contentOffset != CGPoint(x: x, y: y) else {
            return Data("unchanged".utf8)
        }
        record(
            element.attributes["identifier"] as? String ?? "",
            label: element.attributes["label"] as? String ?? "",
            type: element.attributes["elementType"] as? Int ?? 0,
            scope: element.attributes["scope"] as? String,
            instance: element.attributes["instance"] as? String,
            action: fits ? "scroll-fit" : "scroll")
        return Data((fits ? "fit" : "scrolled").utf8)
    }

    static func occlude(_ parameters: [String: String]) -> String {
        occlusionView?.removeFromSuperview()
        invalidate()
        guard parameters["enabled"] == "1" else { return "cleared" }
        guard
            let target = tree()?.descendants.first(where: {
                $0.attributes["identifier"] as? String == parameters["identifier"]
            })?.object,
            let window = UIApplication.shared.connectedScenes.compactMap({
                $0 as? UIWindowScene
            })
            .flatMap(\.windows).last(where: { !$0.isHidden && $0.windowLevel == .normal }),
            var controller = window.rootViewController
        else { return "target missing" }
        while let presented = controller.presentedViewController { controller = presented }
        let overlay = UIButton(type: .system)
        overlay.frame = controller.view.convert(
            target.accessibilityFrame, from: window.screen.coordinateSpace)
        overlay.backgroundColor = .systemBackground
        overlay.isAccessibilityElement = true
        overlay.accessibilityIdentifier = "ui-test.occlusion"
        overlay.accessibilityLabel = "遮挡测试覆盖层"
        controller.view.addSubview(overlay)
        occlusionView = overlay
        return "covered"
    }

    static var windowTraitValues: [[String: Any]] {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.filter { !$0.isHidden && $0.windowLevel == .normal }.map { window in
            let sceneSize: CGSize
            if #available(iOS 26.0, *) {
                sceneSize =
                    window.windowScene?.effectiveGeometry.coordinateSpace.bounds.size ?? .zero
            } else {
                sceneSize = window.bounds.size
            }
            let divisionX: CGFloat
            if #available(iOS 27.1, *) {
                divisionX =
                    window.reservedRegions(kind: .division, options: .includeInactive)
                    .first { $0.frame.height > $0.frame.width }?.frame.midX ?? -1
            } else {
                divisionX = -1
            }
            return [
                "idiom": window.traitCollection.userInterfaceIdiom.rawValue,
                "horizontal": window.traitCollection.horizontalSizeClass.rawValue,
                "vertical": window.traitCollection.verticalSizeClass.rawValue,
                "width": window.bounds.width, "height": window.bounds.height,
                "sceneWidth": sceneSize.width, "sceneHeight": sceneSize.height,
                "sceneHorizontal": window.windowScene?.traitCollection.horizontalSizeClass
                    .rawValue ?? 0,
                "sceneVertical": window.windowScene?.traitCollection.verticalSizeClass.rawValue
                    ?? 0,
                "safeTop": window.safeAreaInsets.top,
                "safeBottom": window.safeAreaInsets.bottom,
                "safeLeading": window.safeAreaInsets.left,
                "safeTrailing": window.safeAreaInsets.right,
                "divisionX": divisionX,
                "orientation": window.windowScene?.effectiveGeometry.interfaceOrientation
                    .rawValue ?? 0,
            ]
        }
    }

    static func windowLayout() throws -> Data {
        try JSONSerialization.data(withJSONObject: windowTraitValues)
    }

}
#endif
