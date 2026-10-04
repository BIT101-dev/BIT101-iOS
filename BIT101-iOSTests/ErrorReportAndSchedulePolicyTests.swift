import SchedulePorts
import ScoreDomain
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
@testable import ScoreFeature
@testable import MapFeature
import ClientCore
import TransportCore
import DesignSystemKit
import ScheduleDomain
import XCTest
import UIKit
import CoreLocation
@testable import BIT101_iOS

nonisolated final class ErrorReportAndSchedulePolicyTests: XCTestCase {
    @MainActor
    func testProductionSchoolServiceRecordsNetworkFailures() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/production-school-diagnostic"))
        let service = ScheduleServiceFactory.make(transport: DiagnosticFailureTransport())
        do {
            _ = try await service.sendRequest(URLRequest(url: url))
            XCTFail("Expected the injected DNS failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotFindHost)
        }
        let records = await NetworkDiagnosticStore.shared.recent()
        let record = try XCTUnwrap(records.last(where: { $0.url == url.absoluteString }))
        XCTAssertNil(record.statusCode)
        XCTAssertEqual(record.error, URLError(.cannotFindHost).localizedDescription)
    }

    private nonisolated struct DiagnosticFailureTransport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            throw URLError(.cannotFindHost)
        }
    }

    @MainActor
    func testAuthenticationBusinessFailurePreservesCauseInDiagnostics() async throws {
        let store = NetworkDiagnosticStore()
        let url = try XCTUnwrap(URL(string: "https://login.bit101.flwfdd.xyz/api/auth/diagnostic-challenge"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let cause = "HTTPSConnectionPool: SSLCertVerificationError: certificate has expired; token=secret"
        let data = try JSONSerialization.data(withJSONObject: [
            "challenge_id": "diagnostic-challenge", "status": "failed", "error": cause
        ])
        await store.record(request: URLRequest(url: url), data: data, response: response, error: nil, elapsed: 0)
        let records = await store.recent()
        let record = try XCTUnwrap(records.last)
        XCTAssertEqual(record.statusCode, 200)
        XCTAssertEqual(record.error, cause)
        let summary = FeedbackDiagnosticSummary(diagnostics: records)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.statusCodes, ["200": 1])
        XCTAssertEqual(summary.latestFailure, cause)
        XCTAssertFalse(ErrorReportRedactor.sanitized(cause).contains("secret"))
    }

    @MainActor
    func testSuccessfulAuthenticationAndOtherHostsRetainHTTPDiagnostics() async throws {
        let store = NetworkDiagnosticStore()
        let authenticated = Data(#"{"challenge_id":"diagnostic-challenge","status":"authenticated"}"#.utf8)
        let failed = Data(#"{"challenge_id":"diagnostic-challenge","status":"failed","error":"school failure"}"#.utf8)
        for (address, data) in [
            ("https://login.bit101.flwfdd.xyz/api/auth/diagnostic-challenge", authenticated),
            ("https://example.invalid/api/auth/diagnostic-challenge", failed),
            ("https://login.bit101.flwfdd.xyz/api/other", failed)
        ] {
            let url = try XCTUnwrap(URL(string: address))
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            await store.record(request: URLRequest(url: url), data: data, response: response, error: nil, elapsed: 0)
        }
        let records = await store.recent()
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records.allSatisfy { $0.error == nil })
        XCTAssertEqual(FeedbackDiagnosticSummary(diagnostics: records).failed, 0)
    }

    @MainActor
    func testFeedbackBuildEnvironmentMatchesCompilationMode() {
#if DEBUG
        XCTAssertTrue(AppBuildEnvironment.isDevelopment)
#else
        XCTAssertFalse(AppBuildEnvironment.isDevelopment)
#endif
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
        let textField = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        window.addSubview(textField)
        defer {
            textField.resignFirstResponder()
            textField.removeFromSuperview()
        }

        XCTAssertTrue(textField.becomeFirstResponder())
        await Task.yield()
        XCTAssertTrue(textField.inputAccessoryView is UIToolbar)

        _ = coordinator
    }

    @MainActor
    func testForcedRedactionKeepsPersonalFieldsButRemovesCredentials() {
        let output = ErrorReportRedactor.forced("name=张三&student_id=1120260000&password=secret&token=abc&cookie=session&ticket=ST-secret")
        XCTAssertTrue(output.contains("张三"))
        XCTAssertTrue(output.contains("1120260000"))
        XCTAssertFalse(output.contains("secret"))
        XCTAssertFalse(output.contains("token=abc"))
        XCTAssertFalse(output.contains("cookie=session"))
        XCTAssertFalse(output.contains("ST-secret"))
        XCTAssertFalse(ErrorReportRedactor.forced(#"{"accessToken":"abc","sessionID":"xyz"}"#).contains("abc"))
        let sanitized = ErrorReportRedactor.sanitized("student_id=1120260000&name=张三&status=401")
        XCTAssertFalse(sanitized.contains("1120260000"))
        XCTAssertFalse(sanitized.contains("张三"))
        XCTAssertTrue(sanitized.contains("401"))
    }

    func testAutomaticWeekPositioningClampsOnlyCalculatedWeeks() {
        XCTAssertEqual(ScheduleAutomaticWeekPolicy.clamped(-20), -12)
        XCTAssertEqual(ScheduleAutomaticWeekPolicy.clamped(-12), -12)
        XCTAssertEqual(ScheduleAutomaticWeekPolicy.clamped(8), 8)
        XCTAssertEqual(ScheduleAutomaticWeekPolicy.clamped(20), 20)
        XCTAssertEqual(ScheduleAutomaticWeekPolicy.clamped(25), 20)

        // 手动翻页支持超出学期与课程周数范围的周次。
    }

    @MainActor
    func testUnpublishedScheduleResponsePreservesSchoolMessage() throws {
        let data = Data(#"{"datas":{"cxxszhxqkb":{"extParams":{"code":3,"msg":"此学年学期的课表未发布"},"rows":[]}}}"#.utf8)
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)
        XCTAssertTrue(response.datas.cxxszhxqkb.rows.isEmpty)
        XCTAssertEqual(response.datas.cxxszhxqkb.extParams?.code, 3)
        XCTAssertEqual(response.datas.cxxszhxqkb.extParams?.msg, "此学年学期的课表未发布")
        XCTAssertEqual(ScheduleService.schoolBusinessErrorMessage(from: data), "此学年学期的课表未发布")
        XCTAssertTrue(ScheduleServiceError.schoolResponse("此学年学期的课表未发布").isUnpublishedCourseSchedule)
        XCTAssertFalse(ScheduleNotice.userInput(title: "课表暂未发布", message: "此学年学期的课表未发布").allowsDiagnostics)
    }

    func testSecondFactorNoticeDoesNotOfferErrorReporting() {
        let notice = ScheduleNotice.userInput(
            title: "需要短信验证",
            message: "学校要求短信二次验证，请先在学校登录页面完成验证后再重试。"
        )

        XCTAssertFalse(notice.allowsDiagnostics)
    }

    func testCredentialFailureDoesNotOfferErrorReporting() {
        let alert = AppAlert.userInput(
            title: "学号或密码错误",
            message: LoginServiceError.invalidCredentials.localizedDescription
        )

        XCTAssertFalse(alert.allowsDiagnostics)
    }

    func testUserInputAlertDoesNotOfferErrorReporting() {
        let alert = AppAlert.userInput(title: "发布失败", message: "请至少添加 2 个标签。")

        XCTAssertFalse(alert.allowsDiagnostics)
    }

    func testUserInputScheduleNoticeDoesNotOfferErrorReporting() {
        let notice = ScheduleNotice.userInput(title: "验证码错误", message: "验证码不正确，请重试。")

        XCTAssertFalse(notice.allowsDiagnostics)
    }

    func testDeniedLocationFailureOffersSettingsWithoutErrorReporting() {
        let denied = NSError(domain: kCLErrorDomain, code: CLError.Code.denied.rawValue)
        let wrapped = NSError(domain: "MapKit", code: 1, userInfo: [NSUnderlyingErrorKey: denied])
        let notice = CampusLocationFailurePolicy.notice(for: wrapped)

        XCTAssertFalse(notice.allowsDiagnostics)
        XCTAssertEqual(notice.recoveryAction, .openAppSettings)
        let deep = (0 ..< 20).reduce(denied) { underlying, _ in
            NSError(domain: "MapKit", code: 1, userInfo: [NSUnderlyingErrorKey: underlying])
        }
        XCTAssertEqual(CampusLocationFailurePolicy.notice(for: deep).recoveryAction, .openAppSettings)
    }

    @MainActor
    func testUserCancelledTranscriptVerificationDoesNotOfferErrorReporting() async {
        let viewModel = TrustedTranscriptViewModel(service: StubTrustedTranscriptService())
        await viewModel.apply()

        viewModel.dismissSMSChallenge()

        XCTAssertFalse(viewModel.allowsDiagnostics)
    }

    @MainActor
    func testTranscriptSheetDismissalPreservesSuccessfulPages() async {
        let viewModel = TrustedTranscriptViewModel(service: StubTrustedTranscriptService())
        await viewModel.apply()
        XCTAssertNotNil(viewModel.smsChallenge)
        await viewModel.submitSMSCode("123456")
        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.images.count, 1)
        XCTAssertNil(viewModel.smsChallenge)

        viewModel.dismissSMSChallenge()
        viewModel.dismissSMSChallenge()
        await viewModel.applyIfNeeded()

        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.images.count, 1)
        XCTAssertNil(viewModel.smsChallenge)
        XCTAssertTrue(viewModel.allowsDiagnostics)
    }

    @MainActor
    func testTranscriptVerificationFailurePreservesChallengeAndRetryLoadsPages() async {
        let viewModel = TrustedTranscriptViewModel(service: StubTrustedTranscriptService())
        await viewModel.apply()
        let challengeID = viewModel.smsChallenge?.challengeID
        XCTAssertNotNil(challengeID)
        await viewModel.submitSMSCode("000000")
        XCTAssertEqual(viewModel.smsChallenge?.challengeID, challengeID)
        XCTAssertEqual(viewModel.smsVerificationError, "验证码错误")
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertTrue(viewModel.images.isEmpty)
        XCTAssertFalse(viewModel.isSubmittingSMSCode)
        await viewModel.submitSMSCode("123456")
        XCTAssertNil(viewModel.smsChallenge)
        XCTAssertNil(viewModel.smsVerificationError)
        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.images.count, 1)
    }

    private struct StubTrustedTranscriptService: TrustedTranscriptServicing {
        func fetchTrustedTranscriptPages() async throws -> [Data] {
            throw ScoreServiceError.secondFactorRequired(BITLoginAuthenticationChallenge(
                challengeID: "test-transcript", accessToken: "test-token", status: "sms_required",
                maskedPhone: "138****0000", expiresIn: 600
            ))
        }

        func submitTranscriptSMSCode(
            _ code: String,
            for challenge: BITLoginAuthenticationChallenge
        ) async throws -> [Data] {
            guard code == "123456" else { throw ScoreServiceError.queryFailed("验证码错误") }
            return [UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }]
        }
    }

    func testCalendarPermissionNoticeOffersSystemSettings() {
        XCTAssertTrue(ScheduleSystemCalendarError.permissionDenied.requiresCalendarSettings)
        XCTAssertTrue(ScheduleSystemCalendarError.noWritableCalendarSource.requiresCalendarSettings)
        XCTAssertFalse(ScheduleSystemCalendarError.missingSchedule.requiresCalendarSettings)
        XCTAssertEqual(ScheduleNotice(
            title: "导入失败",
            message: "日历权限需要调整。",
            recoveryAction: .openAppSettings
        ).recoveryAction, .openAppSettings)
    }

    func testCertificateFailureIsNotPresentedAsExpiredVerification() {
        let error = ScheduleServiceError.challengeInvalid(
            "HTTPSConnectionPool(host='webvpn.bit.edu.cn'): SSLCertVerificationError: certificate has expired"
        )

        XCTAssertTrue(error.isSchoolTransportFailure)
        let notice = ScheduleNotice(
            title: "学校服务连接失败",
            message: error.schoolTransportFailureMessage
        )
        XCTAssertTrue(notice.allowsDiagnostics)
    }

    func testSchoolBusinessInspectorDoesNotRejectSuccessfulOrLegitimateEmptyResponses() {
        let success = Data(#"{"datas":{"rows":[]},"code":"0"}"#.utf8)
        let nestedSuccess = Data(#"{"datas":{"rows":[],"extParams":{"code":1}},"code":"0"}"#.utf8)
        let alternateSuccessCode = Data(
            #"{"datas":{"rows":[],"extParams":{"code":2,"msg":"查询成功"}},"code":"0"}"#.utf8
        )
        XCTAssertNil(ScheduleService.schoolBusinessErrorMessage(from: success))
        XCTAssertNil(ScheduleService.schoolBusinessErrorMessage(from: nestedSuccess))
        XCTAssertNil(ScheduleService.schoolBusinessErrorMessage(from: alternateSuccessCode))
    }

    func testRealDeviceCourseResponseMetadataIsRecognizedAsSuccess() throws {
        // 真机 schedule smoke 响应；学生学号与姓名字段已脱敏。
        let bundle = Bundle(for: ErrorReportAndSchedulePolicyTests.self)
        let fixtureURL = bundle.url(
            forResource: "schedule-service-response",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "schedule-service-response", withExtension: "json")
        let fixture = try XCTUnwrap(fixtureURL)
        let data = try Data(contentsOf: fixture)
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)

        XCTAssertEqual(response.datas.cxxszhxqkb.extParams?.code, 1)
        XCTAssertEqual(response.datas.cxxszhxqkb.extParams?.msg, "查询成功")
        XCTAssertEqual(response.datas.cxxszhxqkb.rows.count, 14)
        XCTAssertNil(ScheduleService.schoolBusinessErrorMessage(from: data))

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let datas = try XCTUnwrap(root["datas"] as? [String: Any])
        let timetable = try XCTUnwrap(datas["cxxszhxqkb"] as? [String: Any])
        let rows = try XCTUnwrap(timetable["rows"] as? [[String: Any]])
        XCTAssertTrue(rows.allSatisfy { $0["XH"] == nil && $0["XM"] == nil })
    }

    func testSchoolBusinessInspectorIgnoresMessagesInsideCourseRows() {
        let data = Data(#"{"datas":{"cxxszhxqkb":{"rows":[{"msg":"课程暂未发布说明"}]}}}"#.utf8)

        XCTAssertNil(ScheduleService.schoolBusinessErrorMessage(from: data))
    }

    func testSchoolBusinessInspectorHonorsExplicitFailureStatus() {
        let data = Data(#"{"data":{"success":false,"code":0,"msg":"学校服务当前不可用"}}"#.utf8)
        let failureMessageWithSuccessCode = Data(#"{"code":0,"msg":"课表查询失败"}"#.utf8)

        XCTAssertEqual(
            ScheduleService.schoolBusinessErrorMessage(from: data),
            "学校服务当前不可用"
        )
        XCTAssertEqual(
            ScheduleService.schoolBusinessErrorMessage(from: failureMessageWithSuccessCode),
            "课表查询失败"
        )
    }

    func testSchoolBusinessInspectorIgnoresStatusLikeMetadataOutsideKnownEnvelopes() {
        let data = Data(#"{"data":{"metadata":{"code":9,"msg":"仅供诊断的字段"}}}"#.utf8)

        XCTAssertNil(ScheduleService.schoolBusinessErrorMessage(from: data))
    }

    func testSchoolBusinessInspectorReadsCaseInsensitiveEnvelopeFields() {
        let data = Data(#"{"DATA":{"ExtParams":{"CODE":"3","MSG":"查询失败"}}}"#.utf8)

        XCTAssertEqual(
            ScheduleService.schoolBusinessErrorMessage(from: data),
            "查询失败"
        )
    }

    func testSchoolBusinessInspectorUsesTypedStatusValuesAndEnglishFailureMessages() {
        let numericFlag = Data(#"{"success":0,"msg":"查询成功"}"#.utf8)
        let fractionalCode = Data(#"{"code":2.5,"msg":"其他提示"}"#.utf8)
        let englishFailure = Data(#"{"data":{"message":"Request failed"}}"#.utf8)

        XCTAssertNil(ScheduleService.schoolBusinessErrorMessage(from: numericFlag))
        XCTAssertNil(ScheduleService.schoolBusinessErrorMessage(from: fractionalCode))
        XCTAssertEqual(
            ScheduleService.schoolBusinessErrorMessage(from: englishFailure),
            "Request failed"
        )
    }

    func testSchoolBusinessInspectorSelectsNestedFailuresDeterministically() {
        let data = Data(
            #"{"datas":{"z":{"extParams":{"code":3,"msg":"课表暂未发布"}},"a":{"extParams":{"code":4,"msg":"此学年学期的课表未发布"}}}}"#.utf8
        )
        let messageInDataEnvelope = Data(#"{"datas":{"msg":"本学期课表未发布"}}"#.utf8)

        XCTAssertEqual(
            ScheduleService.schoolBusinessErrorMessage(from: data),
            "此学年学期的课表未发布"
        )
        XCTAssertEqual(
            ScheduleService.schoolBusinessErrorMessage(from: messageInDataEnvelope),
            "本学期课表未发布"
        )
    }

    private func course(id: String, name: String) -> CourseRecord {
        CourseRecord(id: id, term: "2024-2025-1", name: name, teacher: "教师", classroom: "教室",
                     description: "", weeks: [1, 2], weekday: 1, startSection: 1, endSection: 2,
                     campus: "", number: id, credit: 1, hour: 16, type: "", category: "", department: "")
    }
}
