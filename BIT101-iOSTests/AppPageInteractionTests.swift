import DesignSystemKit
import Observation
import SwiftUI
import UIKit
import XCTest

nonisolated final class AppPageInteractionTests: XCTestCase {
    @MainActor
    func testPairedPagesDrawIntoBottomInset() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: AppPairedPages(showsFirst: true) {
                Color(uiColor: .red).ignoresSafeArea(.container, edges: .bottom)
            } second: {
                Color(uiColor: .blue)
            }.appWindowLayout())
        controller.view.backgroundColor = .blue
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        var pixel: [UInt8] = []
        try? await waitForTestEvent {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let bounds = controller.view.bounds
            guard bounds.height > 0 else { return false }
            let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
                controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            let sample = try XCTUnwrap(
                image.cgImage?.cropping(
                    to:
                        CGRect(x: bounds.midX, y: bounds.maxY - 1, width: 1, height: 1)))
            pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(
                CGContext(
                    data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return pixel[0] > 240 && pixel[1] < 15 && pixel[2] < 15
        }
        XCTAssertEqual(Array(pixel.prefix(3)), [255, 0, 0], "可见页面应绘制到窗口底部。")
    }

    @MainActor
    func testPageSwitchObservesContentTouches() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: Button("条目") {}.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .appPageSwitch { _ in })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func pagePan(in view: UIView) -> UIPanGestureRecognizer? {
            if let pan = view.gestureRecognizers?.first(where: { $0.name == "app.page-switch" })
                as? UIPanGestureRecognizer
            {
                return pan
            }
            return view.subviews.lazy.compactMap { pagePan(in: $0) }.first
        }
        try await waitForTestEvent {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return pagePan(in: controller.view) != nil
        }
        let pan = try XCTUnwrap(pagePan(in: controller.view))
        let surface = try XCTUnwrap(pan.view)
        let point = CGPoint(x: controller.view.bounds.midX, y: controller.view.bounds.midY)
        let recipient = try XCTUnwrap(controller.view.hitTest(point, with: nil))
        XCTAssertTrue(recipient.isDescendant(of: surface), "切页识别器应覆盖条目的实际触摸视图。")
        XCTAssertTrue(pan.cancelsTouchesInView)
    }

    @MainActor
    func testPairedPagesAnimateBothDirections() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let selection = PageSelection()
        let controller = UIHostingController(rootView: PageFixture(selection: selection))
        let window = UIWindow(windowScene: scene)
        let animationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(true)
        controller.view.backgroundColor = .green
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            UIView.setAnimationsEnabled(animationsEnabled)
        }
        func colors() throws -> [[UInt8]] {
            controller.view.layoutIfNeeded()
            let bounds = controller.view.bounds
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
                controller.view.drawHierarchy(in: bounds, afterScreenUpdates: false)
            }
            let source = try XCTUnwrap(image.cgImage)
            return try [0.25, 0.75].map { fraction in
                let sample = try XCTUnwrap(
                    source.cropping(
                        to: CGRect(
                            x: bounds.width * fraction, y: bounds.midY, width: 1, height: 1)))
                var pixel = [UInt8](repeating: 0, count: 4)
                let context = try XCTUnwrap(
                    CGContext(
                        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return Array(pixel.prefix(3))
            }
        }
        let red: [UInt8] = [255, 0, 0]
        let blue: [UInt8] = [0, 0, 255]
        try await waitForTestEvent { try colors() == [red, red] }
        for showsFirst in [false, true] {
            var sawBothPages = false
            withAnimation(.linear(duration: 0.4)) { selection.showsFirst = showsFirst }
            let target = showsFirst ? red : blue
            try await waitForTestEvent {
                let current = try colors()
                sawBothPages =
                    sawBothPages
                    || (current[0] == current[1] && current[0][0] > 10 && current[0][2] > 10)
                return current == [target, target]
            }
            XCTAssertTrue(sawBothPages, "两个方向都应呈现整页均匀淡入淡出的中间帧。")
        }
    }
    @MainActor
    func testVisitedPagesKeepScrollViews() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let store = PageScrollStore()
        let controller = UIHostingController(
            rootView: AppPairedPages(showsFirst: true) {
                PageScrollProbe(store: store, key: "first")
            } second: {
                PageScrollProbe(store: store, key: "second")
            }.appWindowLayout())
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitForTestEvent { store.views["first"] != nil }
        let first = try XCTUnwrap(store.views["first"])
        XCTAssertNil(store.views["second"])
        first.contentOffset.y = 120
        for showsFirst in [false, true, false, true] {
            controller.rootView = AppPairedPages(showsFirst: showsFirst) {
                PageScrollProbe(store: store, key: "first")
            } second: {
                PageScrollProbe(store: store, key: "second")
            }.appWindowLayout()
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await waitForTestEvent { store.views["second"] != nil }
            XCTAssertTrue(store.views["first"] === first)
            XCTAssertEqual(first.contentOffset.y, 120)
            XCTAssertEqual(store.created, ["first": 1, "second": 1])
            XCTAssertEqual(store.removed, 0)
        }
    }

    @MainActor
    func testSegmentedPickerKeepsNativeControl() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let selection = PageSelection()
        let controller = UIHostingController(rootView: PickerFixture(selection: selection))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func segmentedControl(in view: UIView) -> UISegmentedControl? {
            if let control = view as? UISegmentedControl { return control }
            return view.subviews.lazy.compactMap { segmentedControl(in: $0) }.first
        }
        try await waitForTestEvent { segmentedControl(in: controller.view) != nil }
        let control = try XCTUnwrap(segmentedControl(in: controller.view))
        let frame = control.frame
        withAnimation(.linear(duration: 0.4)) { selection.showsFirst = false }
        try await waitForTestEvent { control.titleForSegment(at: 0) == "分享课表" }
        XCTAssertTrue(segmentedControl(in: controller.view) === control)
        XCTAssertEqual(control.numberOfSegments, 3)
        XCTAssertEqual(control.frame, frame)
        XCTAssertEqual(control.alpha, 1)
        XCTAssertEqual(control.layer.presentation()?.opacity ?? 1, 1)
    }

}

@MainActor
@Observable
private final class PageSelection {
    var showsFirst = true
}

private struct PageFixture: View {
    let selection: PageSelection
    var body: some View {
        AppPairedPages(showsFirst: selection.showsFirst) {
            Color(uiColor: .red).ignoresSafeArea(.container, edges: .bottom)
        } second: {
            Color(uiColor: .blue).ignoresSafeArea(.container, edges: .bottom)
        }
        .appWindowLayout()
    }
}

@MainActor
private final class PageScrollStore {
    var views: [String: UIScrollView] = [:]
    var created: [String: Int] = [:]
    var removed = 0
}

private struct PageScrollProbe: UIViewRepresentable {
    let store: PageScrollStore
    let key: String
    func makeUIView(context: Context) -> UIScrollView {
        let view = UIScrollView()
        view.contentSize = CGSize(width: 100, height: 2000)
        store.views[key] = view
        store.created[key, default: 0] += 1
        return view
    }
    func updateUIView(_ uiView: UIScrollView, context: Context) {}
    func makeCoordinator() -> PageScrollStore { store }
    static func dismantleUIView(_ uiView: UIScrollView, coordinator: PageScrollStore) {
        coordinator.removed += 1
    }
}

private struct PickerFixture: View {
    let selection: PageSelection
    var body: some View {
        AppSegmentedPicker(title: "日程模块", selection: .constant(0)) {
            Text(selection.showsFirst ? "课表" : "分享课表").tag(0)
            Text("DDL").tag(1)
            Text("空教室").tag(2)
        }
        .appWindowLayout()
    }
}
