import Observation
import SwiftUI
import UIKit
import XCTest

@testable import DesignSystemKit

nonisolated final class AppPageInteractionTests: XCTestCase {
    @MainActor
    func testPairedPagesBuildContentOnFirstVisit() async throws {
        var builds: [Bool] = []
        func pages(_ showsFirst: Bool) -> AppPairedPages<Text, Text> {
            AppPairedPages(showsFirst: showsFirst, pairsInLandscape: false) {
                builds.append(true)
                return Text("first")
            } second: {
                builds.append(false)
                return Text("second")
            }
        }
        let initial = pages(true)
        XCTAssertTrue(builds.isEmpty, "创建容器时应延后内容构造。")
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: initial)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitForTestEvent { builds.contains(true) }
        XCTAssertFalse(builds.contains(false), "首次进入只应构造可见分区。")
        controller.rootView = pages(false)
        try await waitForTestEvent { builds.contains(false) }
    }

    @MainActor
    func testRetainedPickersOnlyEmitForUserActions() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let selection = PageSelection()
        var feedbackCount = 0
        let originalFeedback = AppHapticFeedback.selectionFeedback
        AppHapticFeedback.selectionFeedback = { feedbackCount += 1 }
        let controller = UIHostingController(rootView: SelectionActionFixture(selection: selection))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            AppHapticFeedback.selectionFeedback = originalFeedback
            window.isHidden = true
            window.rootViewController = nil
        }
        func controls(in view: UIView) -> [UISegmentedControl] {
            if let control = view as? UISegmentedControl { return [control] }
            return view.subviews.flatMap { controls(in: $0) }
        }
        try await waitForTestEvent { controls(in: controller.view).count == 1 }
        selection.showsFirst = false
        try await waitForTestEvent { controls(in: controller.view).count == 2 }
        selection.hapticValue = 1
        try await waitForTestEvent {
            controls(in: controller.view).allSatisfy { $0.selectedSegmentIndex == 1 }
        }
        XCTAssertEqual(feedbackCount, 0, "程序更新和页面保留应保持静默。")
        let control = try XCTUnwrap(controls(in: controller.view).last)
        control.selectedSegmentIndex = 0
        control.sendActions(for: .valueChanged)
        try await waitForTestEvent { selection.hapticValue == 0 }
        XCTAssertEqual(feedbackCount, 1, "用户点击只应由当前控件发出一次反馈。")
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(feedbackCount, 1, "重复选择当前项应保持静默。")
        AppHapticFeedback.selection {
            selection.showsFirst = true
            selection.hapticValue = 1
            return true
        }
        try await waitForTestEvent {
            controls(in: controller.view).allSatisfy { $0.selectedSegmentIndex == 1 }
        }
        XCTAssertEqual(feedbackCount, 2, "一次操作更新页面及选择后，只应新增一次反馈。")
        let rejected = Binding(get: { selection.hapticValue }, set: { _ in }).appSelectionAction()
        rejected.wrappedValue = 0
        XCTAssertEqual(feedbackCount, 2, "操作未改变选择时应保持静默。")
    }

    @MainActor
    func testOnlyVisiblePageRequestsHaptics() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let selection = PageSelection()
        let controller = UIHostingController(rootView: HapticFixture(selection: selection))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func waitForFeedback(_ expected: [Bool]) async throws {
            do {
                try await waitForTestEvent {
                    controller.view.setNeedsLayout()
                    controller.view.layoutIfNeeded()
                    return selection.feedbackPages == expected
                }
            } catch {
                XCTFail(
                    "触感事件：\(selection.feedbackPages)，预期：\(expected)，"
                        + "页面数：\(selection.hapticViewsReady)")
                throw error
            }
        }
        try await waitForTestEvent {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return selection.hapticViewsReady == 2
        }
        selection.hapticValue = 1
        try await waitForFeedback([true])
        selection.showsFirst = false
        selection.hapticValue = 2
        try await waitForFeedback([true, false])
        selection.hapticValue = 3
        try await waitForFeedback([true, false, false])
    }

    @MainActor
    func testPairedPagesDrawIntoBottomInset() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: AppPairedPages(showsFirst: true, pairsInLandscape: false) {
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
                .appPageSwitch { _ in false })
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
            rootView: AppPairedPages(showsFirst: true, pairsInLandscape: false) {
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
            controller.rootView = AppPairedPages(showsFirst: showsFirst, pairsInLandscape: false) {
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
    var hapticValue = 0
    var hapticViewsReady = 0
    var feedbackPages: [Bool] = []
}

private struct HapticFixture: View {
    let selection: PageSelection
    var body: some View {
        VStack {
            forPage(true)
            forPage(false)
        }
    }
    private func forPage(_ first: Bool) -> some View {
        Text(first ? "首页" : "次页")
            .modifier(
                AppHapticFeedbackModifier(trigger: selection.hapticValue) {
                    selection.feedbackPages.append(first)
                }
            )
            .environment(\.appPageIsVisible, selection.showsFirst == first)
            .onAppear { selection.hapticViewsReady += 1 }
    }
}

private struct SelectionActionFixture: View {
    let selection: PageSelection
    var body: some View {
        AppPairedPages(showsFirst: selection.showsFirst, pairsInLandscape: false) {
            picker
        } second: {
            picker
        }
    }
    private var picker: some View {
        AppSegmentedPicker(
            title: "选择",
            selection: Binding(
                get: { selection.hapticValue }, set: { selection.hapticValue = $0 })
        ) {
            Text("第一项").tag(0)
            Text("第二项").tag(1)
        }
    }
}

private struct PageFixture: View {
    let selection: PageSelection
    var body: some View {
        AppPairedPages(showsFirst: selection.showsFirst, pairsInLandscape: false) {
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
