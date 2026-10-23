import SchedulePorts
import GalleryFeature
import CommunityCore
import PaperFeature
import CommunityTransport
import ScoreDomain
import ScorePorts
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
@testable import ScoreFeature
@testable import MapFeature
import ClientCore
import TransportCore
import DesignSystemKit
import ScheduleDomain
import XCTest
import Testing
import UIKit
import SwiftUI
import CoreLocation
@testable import BIT101_iOS
nonisolated final class ErrorReportAndSchedulePolicyTests: XCTestCase {
    private struct DiagnosisTranscriptService: TrustedTranscriptServicing {
        let transcriptServiceIdentity: AnyHashable = "diagnosis-transcript"
        let result: TrustedTranscriptPages
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages { result }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages { result }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { challenge }
    }

    @MainActor
    func testNetworkDiagnosisDistinguishesCompletePartialAndInvalidTranscriptPages() async throws {
        let identity = NetworkDiagnosisRunner.Identity(community: .init(accountIdentifier: "diagnosis"),
            school: .init(accountIdentifier: "diagnosis", generation: 0))
        let client = HTTPClient(transport: DiagnosticFailureTransport(), observer: nil)
        let session = CommunitySession(httpClient: client, baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: identity.community, cookie: "fixture") }, refresh: { _ in })
        let cases: [([Int], Int, Bool, String)] = [([1, 2, 3], 3, false, "通过"), ([1], 3, true, "部分可用"),
            ([1, 1, 3], 3, false, "部分可用"), ([0, 2, 4], 3, false, "部分可用"), ([], 3, false, "失败"),
            ([], 0, false, "失败"), ([1, 2, 3], 3, true, "部分可用")]
        for (numbers, expected, fails, status) in cases {
            let result = TrustedTranscriptPages(pages: numbers.map { .init(number: $0, data: Data([1])) },
                expectedPageCount: expected, failure: fails ? URLError(.timedOut) : nil)
            let dependencies = NetworkDiagnosisDependencies(identity: { identity },
                path: NetworkConnectionDescription(networkPath: NetworkPathState(snapshot: .init(status: .disconnected))),
                httpClient: client, gallery: GalleryService(session: session, preferences: { .init(hideBots: false,
                    hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false) }),
                paper: PaperService(session: session), school: .init(identity: { identity.school }, currentTerm: { "term" },
                    syncCourses: { _ in }, ddl: { DDLSyncPayload(url: "", events: [], warnings: fails ? ["课程中心待恢复"] : []) }), transcript: DiagnosisTranscriptService(result: result))
            let report = await NetworkDiagnosisRunner(dependencies: dependencies).run()
            XCTAssertTrue(try XCTUnwrap(report?.results.last).hasPrefix("可信成绩单：" + status))
            XCTAssertTrue(report?.results.contains { $0.hasPrefix("DDL 接口：" + (fails ? "部分可用" : "通过")) } == true)
        }
    }

    @MainActor
    func testFeedbackFitsWorkerMetadataAndRedactsPathIdentities() async throws {
        let encodedURL = "https://example.invalid/students/%32%30%32%36%31%32%33%34%35%36?note=%2532%2530%2532%2536%2531%2532%2533%2534%2535%2536#%2532%2530%2532%2536%2531%2532%2533%2534%2535%2536"
        let sensitiveHeaders = ["X-Challenge-Token", "x-CsRf-ToKeN", "X-Session-ID", "WWW-Authenticate", "Proxy-Authenticate", "Authentication-Info", "X-XSRF", "X-Api-Key"]
        for raw in [false, true] {
            var submitted: ErrorReportPayload?
            let model = ErrorReportViewModel(alert: AppAlert(title: encodedURL, message: encodedURL), submitReport: { submitted = $0 })
            model.mode = raw ? .raw : .sanitized
            model.comment = "用户描述 " + encodedURL
            let body = String(repeating: "诊断\"\\", count: 32_768)
            model.diagnostics = (0..<10).map { index in
                NetworkDiagnosticRecord(id: UUID(), occurredAt: Date(), method: "GET",
                    url: "https://example.invalid/students/" + (index % 2 == 0 ? "2026123456" : "%32%30%32%36%31%32%33%34%35%36") + "?student=2026123456",
                    statusCode: 500, elapsedMilliseconds: 1, error: encodedURL,
                    responseHeaders: Dictionary(uniqueKeysWithValues: sensitiveHeaders.map { ($0, "TEST_ONLY_SECRET") } + [("Content-Type", "text/plain")]), responseBody: body,
                    finalURL: encodedURL + "&token=TEST_ONLY_SECRET", finalMethod: "GET")
            }
            let submittedSuccessfully = await model.submit()
            XCTAssertTrue(submittedSuccessfully)
            let payload = try XCTUnwrap(submitted)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            XCTAssertLessThanOrEqual(try encoder.encode(payload).count, 1024 * 1024)
            XCTAssertEqual(payload.diagnostics.map(\.id), model.diagnostics.map(\.id))
            XCTAssertEqual(payload.diagnosticSummary.total, 10)
            XCTAssertEqual(payload.diagnosticSummary.failed, 10)
            XCTAssertTrue(try XCTUnwrap(payload.comment).hasPrefix("用户描述"))
            for text in [payload.comment, payload.errorTitle, payload.errorMessage] + payload.diagnostics.map(\.error) {
                let decoded = try XCTUnwrap(try XCTUnwrap(text).removingPercentEncoding?.removingPercentEncoding)
                XCTAssertEqual(decoded.contains("2026123456"), raw)
                XCTAssertTrue(decoded.contains("/students/"))
            }
            for record in payload.diagnostics {
                let path = try XCTUnwrap(URLComponents(string: record.url)).path
                XCTAssertEqual(path.contains("2026123456"), raw)
                let finalURL = try XCTUnwrap(record.finalURL)
                XCTAssertEqual(try XCTUnwrap(URLComponents(string: finalURL)).path.contains("2026123456"), raw)
                XCTAssertFalse(finalURL.contains("TEST_ONLY_SECRET"))
                XCTAssertEqual(record.finalMethod, "GET")
                if raw {
                    XCTAssertEqual(record.responseHeaders["Content-Type"], "text/plain")
                    for key in sensitiveHeaders { XCTAssertEqual(record.responseHeaders[key], "[REDACTED]") }
                    XCTAssertTrue(try XCTUnwrap(record.responseBody).hasSuffix("[响应正文已按反馈大小限制截取]"))
                } else { XCTAssertNil(record.responseBody) }
            }
        }
        var sent = false
        let model = ErrorReportViewModel(alert: AppAlert(title: "fixture", message: "fixture"), submitReport: { _ in sent = true })
        model.comment = String(repeating: "x", count: 1024 * 1024)
        let submittedSuccessfully = await model.submit()
        XCTAssertFalse(submittedSuccessfully)
        XCTAssertFalse(sent)
        XCTAssertTrue(try XCTUnwrap(model.resultMessage).contains("精简描述"))
        XCTAssertFalse(model.isSubmitting)
    }
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
    @MainActor
    private final class DiagnosticAccount {
        var identity = SchoolSessionIdentity(accountIdentifier: "diagnostic-a", generation: 0)
    }
    @MainActor
    func testDiagnosticsRetainFailuresAndAuthenticationContextThroughSuccessfulTraffic() async throws {
        let account = DiagnosticAccount()
        let store = NetworkDiagnosticStore(currentIdentity: { account.identity })
        func capture(_ path: String, status: Int) async throws {
            let url = try XCTUnwrap(URL(string: "https://sso.bit.edu.cn/" + path))
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            await store.record(owner: account.identity, request: URLRequest(url: url), data: nil,
                response: response, error: nil, elapsed: 0)
        }
        try await capture("cas/login", status: 200)
        try await capture("courses", status: 503)
        for index in 0..<60 { try await capture("images/\(index)", status: 200) }
        let recent = await store.recent()
        XCTAssertEqual(recent.count, 10)
        XCTAssertTrue(recent.contains { $0.url.hasSuffix("/cas/login") })
        XCTAssertTrue(recent.contains { $0.url.hasSuffix("/courses") && $0.statusCode == 503 })
        XCTAssertTrue(recent.contains { $0.url.hasSuffix("/images/59") })
        let recoveryURL = await store.latestSchoolServicePageURL()
        XCTAssertEqual(recoveryURL?.path, "/courses")
        for index in 0..<20 { try await capture("failed/\(index)", status: 503) }
        try await capture("current-request", status: 200)
        let updated = await store.recent()
        XCTAssertTrue(updated.contains { $0.url.hasSuffix("/current-request") })
    }

    @MainActor
    func testDiagnosticsFilterAccountsGenerationsAndLateResults() async throws {
        let account = DiagnosticAccount()
        let store = NetworkDiagnosticStore(currentIdentity: { account.identity })
        let owner = account.identity
        let url = try XCTUnwrap(URL(string: "https://sso.bit.edu.cn/cas/login"))
        let request = URLRequest(url: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil))
        await store.record(owner: owner, request: request, data: Data("account-a".utf8), response: response, error: nil, elapsed: 0)
        let count1 = await store.recent().count
        XCTAssertEqual(count1, 1)
        account.identity = .init(accountIdentifier: "diagnostic-b", generation: 1)
        await store.record(owner: owner, request: request, data: Data("late-account-a".utf8), response: response, error: nil, elapsed: 0)
        let empty1 = await store.recent().isEmpty
        XCTAssertTrue(empty1)
        let page1 = await store.latestSchoolServicePageURL()
        XCTAssertNil(page1)
        await store.record(owner: account.identity, request: request, data: Data("account-b".utf8), response: response, error: nil, elapsed: 0)
        let body1 = await store.recent().last?.responseBody
        XCTAssertEqual(body1, "account-b")
        let previous = account.identity
        account.identity = .init(accountIdentifier: "diagnostic-b", generation: 2)
        await store.record(owner: previous, request: request, data: Data("previous-generation".utf8), response: response, error: nil, elapsed: 0)
        let empty2 = await store.recent().isEmpty
        XCTAssertTrue(empty2)
        await store.record(owner: account.identity, request: request, data: nil, response: response, error: nil, elapsed: 0)
        await store.clear()
        let empty3 = await store.recent().isEmpty
        XCTAssertTrue(empty3)
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
        await store.record(owner: AppAccountSession.storage.schoolSessionIdentity, request: URLRequest(url: url), data: data, response: response, error: nil, elapsed: 0)
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
            await store.record(owner: AppAccountSession.storage.schoolSessionIdentity, request: URLRequest(url: url), data: data, response: response, error: nil, elapsed: 0)
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
    func testKeyboardBackgroundTouchPreservesSystemAutoFillFocus() throws {
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow))
        var controller = try XCTUnwrap(window.rootViewController)
        while let presented = controller.presentedViewController { controller = presented }
        let background = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let input = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        input.textContentType = .oneTimeCode
        let systemSuggestion = UIView(frame: CGRect(x: 0, y: 100, width: 200, height: 44))
        controller.view.addSubview(background)
        background.addSubview(input)
        window.addSubview(systemSuggestion)
        let coordinator = KeyboardBackgroundTapInstaller.Coordinator()
        coordinator.attach(to: window)
        defer {
            coordinator.detach()
            input.resignFirstResponder()
            background.removeFromSuperview()
            systemSuggestion.removeFromSuperview()
        }
        XCTAssertTrue(input.becomeFirstResponder())
        XCTAssertTrue(coordinator.acceptsBackgroundTouch(in: background))
        XCTAssertFalse(coordinator.acceptsBackgroundTouch(in: systemSuggestion))
        XCTAssertFalse(coordinator.acceptsBackgroundTouch(in: input))
        input.insertText("123456")
        XCTAssertEqual(input.text, "123456")
        XCTAssertTrue(input.isFirstResponder)
    }

    @MainActor
    func testVerificationAutoFillCapturesTheCodeAndSerializesSubmissions() async throws {
        executionTimeAllowance = 60
        let deadline = ContinuousClock.now.advanced(by: .seconds(executionTimeAllowance))
        var submissions: [String] = []
        var pending: CheckedContinuation<Void, Never>?
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: AppSMSVerificationSheet(
            maskedPhone: "138****0000", isSubmitting: false, errorMessage: nil,
            submitTitle: "验证", onCancel: {}, onSubmit: { code in
                submissions.append(code)
                await withCheckedContinuation { pending = $0 }
            }
        ))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            pending?.resume()
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        func findInput(_ view: UIView) -> UITextField? {
            if let field = view as? UITextField, field.accessibilityIdentifier == "verification.code" { return field }
            return view.subviews.lazy.compactMap(findInput).first
        }
        func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
            while !condition(), ContinuousClock.now < deadline {
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(condition(), "\(description) 提交次数：\(submissions.count)，输入使能：\(String(describing: findInput(controller.view)?.isEnabled))，窗口：\(window.bounds)，关键窗口：\(window.isKeyWindow)。")
        }
        try await waitUntil("布局") { findInput(controller.view) != nil }
        let input = try XCTUnwrap(findInput(controller.view))
        XCTAssertEqual(input.textContentType, .oneTimeCode)
        XCTAssertEqual(input.keyboardType, .numberPad)
        XCTAssertTrue(input.becomeFirstResponder())
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await waitUntil("输入焦点") { findInput(controller.view)?.isFirstResponder == true }
        func fill(_ code: String) throws {
            let input = try XCTUnwrap(findInput(controller.view))
            input.selectedTextRange = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
            input.insertText(code)
        }
        try fill("123456")
        try fill("654321")
        XCTAssertEqual(findInput(controller.view)?.text, "654321")
        try await waitUntil("首次提交") { submissions.count == 1 && findInput(controller.view)?.isEnabled == false }
        XCTAssertEqual(submissions, ["123456"])
        let first = pending
        pending = nil
        first?.resume()
        try await waitUntil("恢复输入") { findInput(controller.view)?.isEnabled == true }
        XCTAssertEqual(submissions.count, 1)
        try fill("123456")
        try await waitUntil("再次提交") { submissions.count == 2 && findInput(controller.view)?.isEnabled == false }
        XCTAssertEqual(submissions, ["123456", "123456"])
    }

    @MainActor
    func testDeeplyEncodedURLsAreMaskedWithinTheDecodingBudget() throws {
        let encoded = "%" + String(repeating: "25", count: 20_000)
        for suffix in [encoded, "?note=\(encoded)", "?\(encoded)=TEST_ONLY_SECRET", "#\(encoded)"] {
            XCTAssertEqual(ErrorReportRedactor.forced("https://example.invalid/\(suffix)"), "[REDACTED]")
        }
        var nested = "https://school.invalid/?ticket=TEST_ONLY_SECRET"
        for _ in 0..<12 { nested = try XCTUnwrap(nested.addingPercentEncoding(withAllowedCharacters: .alphanumerics)) }
        XCTAssertEqual(ErrorReportRedactor.forced("https://example.invalid/?service=\(nested)"), "[REDACTED]")
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
        XCTAssertFalse(ErrorReportRedactor.forced("https://example.invalid/%54%45%53%54", credentials: ["TEST"]).removingPercentEncoding?.contains("TEST") == true)
        for text in ["Authorization: Bearer TEST_ONLY_SECRET", "Authorization: Basic TEST_ONLY_SECRET",
                     "Cookie: first=TEST_ONLY_SECRET; second=TEST_ONLY_SECRET", "Proxy-Authorization: Basic TEST_ONLY_SECRET",
                     #"{"password":"TEST_ONLY_\"SECRET"}"#,
                     "https://example.invalid/?%70assword=TEST_ONLY_SECRET",
                     "https://example.invalid/?%2570assword=TEST_ONLY_SECRET",
                     "https://example.invalid/#%74oken=TEST_ONLY_SECRET",
                     "https://example.invalid/#%2574oken=TEST_ONLY_SECRET",
                     "https://example.invalid/#%74oken=TEST_ONLY_SECRET&note=%bad",
                     "https://example.invalid/?service=https%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET",
                     "https://example.invalid/?service=HTTPS%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET",
                     "https://fixture-user:TEST_ONLY_SECRET@example.invalid/"] {
            XCTAssertFalse(ErrorReportRedactor.forced(text).contains("TEST_ONLY"))
            XCTAssertFalse(ErrorReportRedactor.forced(text).contains("SECRET"))
        }
        XCTAssertEqual(ErrorReportRedactor.forced("https://example.invalid/#section"), "https://example.invalid/#section")
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
    func testNetworkDiagnosisStopsAtItsCapturedAccountAndCancellationBoundary() async throws {
        for interruption in ["account", "community-generation", "school-generation", "cancel"] {
            var owner = NetworkDiagnosisRunner.Identity(community: .init(accountIdentifier: "A"), school: .init(accountIdentifier: "A", generation: 0))
            var waiting: CheckedContinuation<Void, Never>?
            var shouldWait = true
            var executed: Set<NetworkDiagnosisRunner.Step> = []
            let client = HTTPClient(transport: DiagnosticFailureTransport(), observer: nil)
            let session = CommunitySession(httpClient: client, baseURL: AppURL.required("https://example.invalid"),
                credentials: { .init(identity: owner.community, cookie: "fixture") }, refresh: { _ in })
            let dependencies = NetworkDiagnosisDependencies(identity: { owner },
                path: NetworkConnectionDescription(networkPath: NetworkPathState(snapshot: .init(status: .disconnected))),
                httpClient: client, gallery: GalleryService(session: session, preferences: { .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false) }),
                paper: PaperService(session: session),
                school: NetworkDiagnosisSchool(identity: { owner.school }, currentTerm: { "fixture" }, syncCourses: { _ in }, ddl: { DDLSyncPayload(url: "", events: []) }),
                transcript: StubTrustedTranscriptService())
            let runner = NetworkDiagnosisRunner(dependencies: dependencies, diagnose: { step in
                executed.insert(step)
                if step == .currentTerm, shouldWait {
                    shouldWait = false
                    await withCheckedContinuation { waiting = $0 }
                }
                return step.title + "：通过"
            })
            let work = Task { await runner.run() }
            try await waitForTestEvent { !(waiting == nil || runner.completedCount < 4) }
            switch interruption {
            case "account": owner = .init(community: .init(accountIdentifier: "B"), school: .init(accountIdentifier: "B", generation: 0))
            case "community-generation": owner = .init(community: .init(accountIdentifier: "A", generation: 1), school: owner.school)
            case "school-generation": owner = .init(community: owner.community, school: .init(accountIdentifier: "A", generation: 1))
            default: work.cancel()
            }
            try XCTUnwrap(waiting).resume()
            let interrupted = await work.value
            XCTAssertNil(interrupted)
            XCTAssertFalse(runner.isRunning)
            XCTAssertEqual(runner.completedCount, 4)
            XCTAssertTrue(executed.isDisjoint(with: [.schedule, .ddl, .transcript]))
            executed = []
            let next = await runner.run()
            let resumed = try XCTUnwrap(next)
            XCTAssertEqual(resumed.results.count, runner.totalCount)
            XCTAssertEqual(executed, Set(NetworkDiagnosisRunner.Step.allCases))
            XCTAssertEqual(runner.completedCount, runner.totalCount)
        }
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

    @MainActor
    private final class RecoverableTranscriptService: TrustedTranscriptServicing {
        let page: Data
        let mode: String
        var submissions = 0
        var initialRequests = 0
        var downloads = 0
        init(page: Data, mode: String) { self.page = page; self.mode = mode }
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            initialRequests += 1
            throw ScoreServiceError.secondFactorRequired(.init(challengeID: "fixture", accessToken: "token", status: "waiting_sms",
                maskedPhone: nil, expiresIn: 600))
        }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge {
            submissions += 1
            return .init(challengeID: challenge.challengeID, accessToken: challenge.accessToken, status: "authenticated", maskedPhone: nil, expiresIn: 600)
        }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            downloads += 1
            if downloads == 1 {
                if mode == "download" { throw URLError(.networkConnectionLost) }
                if mode == "decode" { return .init([page, Data("damaged".utf8)]) }
                return .init(pages: [.init(number: 2, data: page)], expectedPageCount: 2, failure: URLError(.networkConnectionLost))
            }
            return .init([page, page])
        }
    }

    @MainActor
    func testTranscriptDownloadRetryConsumesSMSAndKeepsAvailablePages() async {
        for mode in ["download", "decode", "partial"] {
            let page = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }
            let service = RecoverableTranscriptService(page: page, mode: mode)
            let model = TrustedTranscriptViewModel(service: service)
            await model.apply()
            await model.submitSMSCode("123456")
            XCTAssertNil(model.smsChallenge)
            XCTAssertNil(model.smsVerificationError)
            if mode == "download" { if case .failed = model.state {} else { XCTFail("Expected download retry") } }
            else {
                XCTAssertEqual(model.state, .loaded)
                XCTAssertEqual(model.images.count, 1)
                XCTAssertNotNil(model.deliveryWarning)
                XCTAssertEqual(model.pageNumbers, mode == "decode" ? [1] : [2])
            }
            model.prepareRetry()
            await model.applyIfNeeded()
            XCTAssertEqual(model.state, .loaded)
            XCTAssertEqual(model.images.count, 2)
            XCTAssertNil(model.deliveryWarning)
            XCTAssertEqual(service.submissions, 1)
            XCTAssertEqual(service.initialRequests, 1)
            XCTAssertEqual(service.downloads, 2)
        }
    }

    @MainActor
    private final class RetryingTranscriptService: TrustedTranscriptServicing {
        let transcriptServiceIdentity: AnyHashable = UUID()
        let page: Data
        let returnsChallenge: Bool
        var requests = 0
        var pending: CheckedContinuation<Void, Never>?
        var cancelled = false
        init(page: Data, returnsChallenge: Bool) { self.page = page; self.returnsChallenge = returnsChallenge }
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            requests += 1
            if requests == 1 { throw ScoreServiceError.queryFailed("fixture") }
            if requests == 2 {
                await withCheckedContinuation { pending = $0 }
                cancelled = Task.isCancelled
                if returnsChallenge {
                    throw ScoreServiceError.secondFactorRequired(.init(challengeID: "fixture", accessToken: "fixture",
                        status: "waiting_sms", maskedPhone: nil, expiresIn: 60))
                }
            }
            return .init([page])
        }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { return challenge }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages { .init([page]) }
    }

    @MainActor
    func testTranscriptRetryCancellationRetiresImagesAndLateChallengesAndCanResume() async throws {
        for returnsChallenge in [false, true] {
            let page = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }
            let service = RetryingTranscriptService(page: page, returnsChallenge: returnsChallenge)
            let model = TrustedTranscriptViewModel(service: service)
            await model.applyIfNeeded()
            guard case .failed = model.state else { XCTFail("Expected initial failure"); continue }
            model.prepareRetry()
            let retry = Task { await model.applyIfNeeded() }
            try await waitForTestEvent { !(service.pending == nil) }
            retry.cancel()
            service.pending?.resume()
            await retry.value
            XCTAssertTrue(service.cancelled)
            XCTAssertEqual(model.state, .idle)
            XCTAssertTrue(model.images.isEmpty)
            XCTAssertNil(model.smsChallenge)
            await model.applyIfNeeded()
            XCTAssertEqual(model.state, .loaded)
            XCTAssertEqual(service.requests, 3)
        }
    }

    private struct TranscriptPageService: TrustedTranscriptServicing {
        let transcriptServiceIdentity: AnyHashable = UUID()
        let pages: [Data]
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages { .init(pages) }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { return challenge }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages { .init(pages) }
    }

    @MainActor
    func testTranscriptPreparesEveryPageWithinTheAggregateBitmapBudget() async throws {
        let page = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 128)).pngData { context in
            UIColor.label.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        }
        let model = TrustedTranscriptViewModel(service: TranscriptPageService(pages: [page, page]),
            limits: .init(maximumDecodedBytes: 4_096))
        await model.apply()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.images.count, 2)
        let bitmaps = try model.images.map { try XCTUnwrap($0.cgImage) }
        XCTAssertLessThanOrEqual(bitmaps.reduce(0) { $0 + $1.bytesPerRow * $1.height }, 4_096)
        for bitmap in bitmaps {
            XCTAssertLessThan(bitmap.width, 256)
            XCTAssertEqual(Double(bitmap.width) / Double(bitmap.height), 2, accuracy: 0.2)
        }
    }

    @MainActor
    func testTranscriptRejectsExcessPagesEncodedBytesAndUnusableBitmapBudgets() async {
        let page = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { _ in }
        for limits in [TrustedTranscriptResourceLimits(maximumPageCount: 1),
                       .init(maximumEncodedBytes: page.count * 2 - 1), .init(maximumDecodedBytes: 3)] {
            let model = TrustedTranscriptViewModel(service: TranscriptPageService(pages: [page, page]), limits: limits)
            await model.apply()
            guard case .failed = model.state else { XCTFail("Expected transcript resource limit failure"); continue }
            XCTAssertTrue(model.images.isEmpty)
        }
    }

    private struct StubTrustedTranscriptService: TrustedTranscriptServicing {
        let transcriptServiceIdentity: AnyHashable = UUID()
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            throw ScoreServiceError.secondFactorRequired(BITLoginAuthenticationChallenge(
                challengeID: "test-transcript", accessToken: "test-token", status: "sms_required",
                maskedPhone: "138****0000", expiresIn: 600
            ))
        }

        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge {
            guard code == "123456" else { throw ScoreServiceError.queryFailed("验证码错误") }
            return challenge
        }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            .init([UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }])
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
