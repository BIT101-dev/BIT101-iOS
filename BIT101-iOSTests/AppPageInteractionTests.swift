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
                sawBothPages = sawBothPages || current == [red, blue]
                return current == [target, target]
            }
            XCTAssertTrue(sawBothPages, "两个方向都应呈现新旧页面同时移动的中间帧。")
        }
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
