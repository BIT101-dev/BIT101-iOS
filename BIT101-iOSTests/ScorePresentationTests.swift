import Combine
import ScoreDomain
import ScorePorts
import ScheduleDomain
import SchedulePorts
@testable import ScoreInfrastructure
import CommunityTransport
import CommunityCore
@testable import GalleryFeature
@testable import CommunityUI
@testable import ScheduleFeature
@testable import MediaKit
@testable import ScoreFeature
import StorageCore
import TransportCore
import ClientCore
import ScheduleContracts
import ScheduleActivityContracts
import Foundation
import Network
import os
import Security
import Testing
import UIKit
import XCTest
import SwiftUI
import DesignSystemKit
@testable import BIT101_iOS

@Suite("Score presentation logic", .serialized)
struct ScorePresentationTests {
    @Test func serviceFailuresProvidePresentationDetails() {
        let challenge = BITLoginAuthenticationChallenge(challengeID: "fixture", accessToken: "token",
            status: "sms_required", maskedPhone: nil, expiresIn: 120)
        for error in [ScoreServiceError.missingCredentials, .invalidResponse, .requestTimedOut, .secondFactorRequired(challenge)] {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(ScoreServiceError.challengeInvalid("认证上下文已变化").errorDescription == "认证上下文已变化")
        #expect(ScoreServiceError.queryFailed("课程查询失败").errorDescription == "课程查询失败")
    }

    @Test("Successful empty score response returns an empty result")
    func successfulEmptyScoreResponse() throws {
        let response = Data(#"{"msg":"查询成功OvO","data":[]}"#.utf8)

        #expect(try ScoreService.decodeScoreRows(response).isEmpty)
    }

    @Test("Empty score response preserves the server failure message")
    func emptyScoreFailureMessage() {
        let response = Data(#"{"msg":"成绩服务暂不可用","data":[]}"#.utf8)

        #expect(throws: ScoreServiceError.self) {
            try ScoreService.decodeScoreRows(response)
        }
    }

}

@MainActor
@Suite("Adaptive page lifetime")
struct AdaptivePageLifetimeTests {
    @Test(.timeLimit(.minutes(1)))
    func switchingSectionsPreservesDraftsAndInheritedVisibility() async throws {
        let probe = Probe()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: Host(probe: probe, showsFirst: true, isVisible: true))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true; window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        func wait(_ phase: String, _ condition: () -> Bool) async throws {
            do { try await waitForTestEvent { condition() } }
            catch { Issue.record("\(phase)：可见性 \(probe.visibility)，草稿页 \(probe.drafts.keys.sorted())"); throw error }
        }
        func display(_ showsFirst: Bool, _ isVisible: Bool = true) {
            controller.rootView = Host(probe: probe, showsFirst: showsFirst, isVisible: isVisible)
            window.layoutIfNeeded()
        }
        try await wait("首次挂载") { probe.visibility["score"] == true }
        let score = try #require(probe.drafts["score"])
        score.wrappedValue = "成绩阅读草稿"
        display(false)
        try await wait("切换课程") { probe.visibility["course"] == true && probe.visibility["score"] == false }
        let course = try #require(probe.drafts["course"])
        course.wrappedValue = "课程阅读草稿"
        display(true)
        try await wait("返回成绩") { probe.visibility["score"] == true && probe.visibility["course"] == false }
        #expect(probe.drafts["score"]?.wrappedValue == "成绩阅读草稿")
        #expect(probe.drafts["course"]?.wrappedValue == "课程阅读草稿")
        display(true, false)
        try await wait("隐藏父页") { probe.visibility.values.allSatisfy { !$0 } }
        display(true)
        try await wait("恢复父页") { probe.visibility["score"] == true && probe.visibility["course"] == false }
        #expect(probe.drafts["score"]?.wrappedValue == "成绩阅读草稿")
        #expect(probe.drafts["course"]?.wrappedValue == "课程阅读草稿")
    }

    private final class Probe {
        var drafts: [String: Binding<String>] = [:]
        var visibility: [String: Bool] = [:]
    }
    private struct Host: View {
        let probe: Probe
        let showsFirst: Bool
        let isVisible: Bool
        var body: some View {
            AppPairedPages(showsFirst: showsFirst, pairsInLandscape: false) {
                Page(name: "score", probe: probe)
            } second: { Page(name: "course", probe: probe) }
            .environment(\.appWindowLayout, AppWindowLayout(size: CGSize(width: 1_194, height: 834), isRegularWidth: true))
            .environment(\.appPageIsVisible, isVisible)
        }
    }
    private struct Page: View {
        let name: String
        let probe: Probe
        @State private var draft = ""
        @Environment(\.appPageIsVisible) private var isVisible
        var body: some View {
            TextField("阅读草稿", text: $draft)
                .onAppear { probe.drafts[name] = $draft }
                .onChange(of: isVisible, initial: true) { _, value in probe.visibility[name] = value }
        }
    }
}

nonisolated final class KeyboardAccessoryOwnershipTests: XCTestCase {
    @MainActor
    func testAccessoryActionSurvivesCoordinatorReplacement() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        let inputs: [UIView & UITextInput] = [
            UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44)),
            UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100)),
        ]
        for input in inputs {
            var owner: KeyboardBackgroundTapInstaller.Coordinator? = .init()
            owner?.attach(to: window)
            window.addSubview(input)
            defer { input.resignFirstResponder(); input.removeFromSuperview() }
            XCTAssertTrue(input.becomeFirstResponder())
            try await waitForTestEvent { input.inputAccessoryView is UIToolbar }
            let toolbar = try XCTUnwrap(input.inputAccessoryView as? UIToolbar)
            let button = try XCTUnwrap(toolbar.items?.first { $0.accessibilityIdentifier == "keyboard.dismiss" })
            owner?.detach()
            owner = nil
            var replacement: KeyboardBackgroundTapInstaller.Coordinator? = .init()
            replacement?.attach(to: window)
            await Task.yield()
            replacement?.detach()
            replacement = nil
            XCTAssertNotNil(button.customView, "键盘附件动作应与输入控件共享存活期。")
            XCTAssertTrue(input.inputAccessoryView === toolbar)
            try XCTUnwrap(button.customView as? UIButton).sendActions(for: .touchUpInside)
            XCTAssertFalse(input.isFirstResponder)
        }
    }
    @MainActor
    func testGlobalKeyboardAccessory() async throws {
        let coordinator = KeyboardBackgroundTapInstaller.Coordinator()
        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
        )
        coordinator.attach(to: window)
        defer { coordinator.detach() }
        let inputs: [UIView & UITextInput] = [
            UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44)),
            UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100)),
        ]
        for input in inputs {
            window.addSubview(input)
            defer {
                input.resignFirstResponder()
                input.removeFromSuperview()
            }
            XCTAssertTrue(input.becomeFirstResponder())
            await Task.yield()
            XCTAssertTrue(input.inputAccessoryView is UIToolbar)
            let original = try XCTUnwrap(input.inputAccessoryView as? UIToolbar)
            XCTAssertTrue(input.resignFirstResponder())
            if let field = input as? UITextField { field.inputAccessoryView = nil }
            if let view = input as? UITextView { view.inputAccessoryView = nil }
            XCTAssertTrue(input.becomeFirstResponder())
            try await waitForTestEvent { input.inputAccessoryView is UIToolbar }
            let toolbar = try XCTUnwrap(input.inputAccessoryView as? UIToolbar)
            XCTAssertTrue(toolbar === original, "键盘附件恢复应保留原控件及其动作身份。")
            NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil)
            await Task.yield()
            XCTAssertTrue(input.inputAccessoryView === toolbar, "键盘显示周期应保留已安装的附件。")
            let buttons = toolbar.items?.filter { $0.accessibilityIdentifier == "keyboard.dismiss" } ?? []
            XCTAssertEqual(buttons.count, 1)
            let button = try XCTUnwrap(buttons.first)
            try XCTUnwrap(button.customView as? UIButton).sendActions(for: .touchUpInside)
            XCTAssertFalse(input.isFirstResponder)
        }
    }

}
