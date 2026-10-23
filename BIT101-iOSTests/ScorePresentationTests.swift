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
