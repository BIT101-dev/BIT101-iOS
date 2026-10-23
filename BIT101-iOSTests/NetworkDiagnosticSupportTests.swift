import CommunityPersistence
import CommunityCore
import Combine
import ClientCore
import ScoreDomain
import ScorePorts
@testable import ScoreInfrastructure
import CommunityTransport
@testable import GalleryFeature
@testable import CommunityUI
@testable import MediaKit
import StorageCore
import Foundation
import os
import Testing
import DesignSystemKit
@testable import BIT101_iOS
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
import TransportCore
import ScheduleDomain
#if EXTENDED_AUTOMATION

@Suite("Network diagnostic utility contracts")
struct NetworkDiagnosticSupportTests {
    @Test(.timeLimit(.minutes(1))) @MainActor
    func canceledFeedbackSubmissionPreservesPageState() async throws {
        var release: CheckedContinuation<Void, Never>?
        let model = ErrorReportViewModel(alert: AppAlert(title: "fixture", message: "fixture"), submitReport: { _ in
            await withCheckedContinuation { release = $0 }
        })
        let task = Task { await model.submit() }
        defer { task.cancel(); release?.resume() }
        try await waitForTestEvent { release != nil }
        task.cancel(); release?.resume(); release = nil
        #expect(await task.value == false)
        #expect(model.resultMessage == nil && !model.isSubmitting)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func feedbackRetryRetainsTheOriginalPayloadAndEditsStartANewSubmission() async throws {
        var submitted: [ErrorReportPayload] = []
        let model = ErrorReportViewModel(alert: AppAlert(title: "fixture", message: "fixture"), submitReport: {
            submitted.append($0)
            throw URLError(.timedOut)
        })
        #expect(await model.submit() == false)
        #expect(await model.submit() == false)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(submitted[0]) == encoder.encode(submitted[1]))
        model.comment = "updated report"
        #expect(await model.submit() == false)
        #expect(submitted[2].requestID != submitted[1].requestID)
        #expect(submitted[2].comment == "updated report")
    }

    @Test(arguments: ["valid", "html", "missing", "bad-id", "wrong-id", "wrong-origin", "changed-method"])
    @MainActor
    func feedbackSuccessRequiresItsCreationReceipt(caseName: String) throws {
        let endpoint = AppURL.required("https://feedback.aihelpme.dev/api/error-reports")
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        let finalURL = caseName == "wrong-origin" ? AppURL.required("https://example.invalid/api/error-reports") : endpoint
        var finalRequest = URLRequest(url: finalURL); finalRequest.httpMethod = caseName == "changed-method" ? "GET" : "POST"
        let http = try #require(HTTPURLResponse(url: finalURL, statusCode: 201, httpVersion: nil, headerFields: nil))
        let body = caseName == "html" ? "<html>error</html>" : caseName == "missing" ? "{}" :
            caseName == "bad-id" ? #"{"id":"fixture"}"# : #"{"id":"11111111-1111-4111-8111-111111111111"}"#
        let response = HTTPResponse(data: Data(body.utf8), response: http, finalRequest: finalRequest)
        if caseName == "valid" { try FeedbackSubmissionClient.validateSubmissionResponse(response, request: request) }
        else { #expect(throws: URLError.self) {
            try FeedbackSubmissionClient.validateSubmissionResponse(response, request: request,
                expectedReportID: caseName == "wrong-id" ? UUID() : nil)
        } }
    }
    @Test("Forced redaction handles nested credentials")
    func nestedCredentialRedaction() {
        let value = #"{"profile":{"name":"张三"},"auth":{"password":"secret","access_token":"abc"}}"#
        let result = ErrorReportRedactor.forced(value)

        #expect(result.contains("张三"))
        #expect(!result.contains("secret"))
        #expect(!result.contains("abc"))
        #expect(result.contains("[REDACTED]"))
    }

    @Test(arguments: [
        #"<div id="login-page-flowkey">SENSITIVE_VALUE</div>"#,
        #"<p id="login-croypto">SENSITIVE_VALUE</p>"#,
        #"<div><p id="login-page-flowkey">SENSITIVE_VALUE</p><p>available</p></div>"#,
        #"<div id="login-page-flowkey"><div>SENSITIVE_VALUE</div>TAIL_VALUE</div><p>available</p>"#,
        #"<x-field name="csrf-token"><b>SENSITIVE_VALUE</b></x-field>"#,
        #"<p id="login-page-flowkey">SENSITIVE_VALUE"#,
        #"<span id="login-page-flowkey">SENSITIVE_VALUE</span>"#,
        #"<span id="login-page-flowkey">SENSITIVE_VALUE"#,
        #"<meta http-equiv="Set-Cookie" content="SENSITIVE_VALUE">"#,
        #"<meta name="csrf-token" content="SENSITIVE_VALUE">"#,
        #"<meta content="SENSITIVE_VALUE" property="csrf&#45;token">"#,
        #"<script>const csrfToken = "SENSITIVE_VALUE;TAIL_VALUE";</script>"#,
        #"<script>var _token = 'SENSITIVE_VALUE;TAIL_VALUE';</script>"#,
        #"<script>window["csrfToken"] = "SENSITIVE_VALUE";</script>"#,
        #"csrf_token=SENSITIVE_VALUE"#,
        #"<input type="password" value="SENSITIVE_VALUE">"#,
        #"<input TYPE=pass&#x77;ord value='SENSITIVE_VALUE'>"#,
        #"<input name="pass&#119;ord" value="SENSITIVE_VALUE">"#,
        #"<input name="pass&#x77ord" value="SENSITIVE_VALUE">"#,
        #"<textarea name="access&lowbar;token">SENSITIVE_VALUE</textarea>"#,
        #"<input id="login-page-flowkey" name="execution" value="SENSITIVE_VALUE">"#,
        #"<input id="login-croypto" value='SENSITIVE_VALUE'>"#,
        #"<input name=execution value=SENSITIVE_VALUE>"#,
        #"<input value="SENSITIVE_VALUE>TAIL_VALUE" name="execution">"#,
        #"<input name="execution" value="SENSITIVE_VALUE"#,
        #"<textarea name="password">SENSITIVE_VALUE</textarea>"#,
        #"<textarea name="password">SENSITIVE_VALUE"#,
        #"{"\u0070assword":"SENSITIVE_VALUE"#,
        #"{"access_token":{"value":"SENSITIVE_VALUE"},"status":"available"}"#,
        #"{"captcha_payload":["SENSITIVE_VALUE"]}"#,
        #"{"cookie_str":{"value":"SENSITIVE_VALUE"#
    ])
    func forcedRedactionCoversHTMLStructuredJSONAndTruncatedBodies(value: String) {
        let result = ErrorReportRedactor.forced(value)
        #expect(result.contains("SENSITIVE_VALUE") == false)
        #expect(result.contains("TAIL_VALUE") == false)
        #expect(result.contains("[REDACTED]"))
        if value.contains("available") { #expect(result.contains("available")) }
        let ordinary = #"<input type="text" name="summary" value="visible">"#
        #expect(ErrorReportRedactor.forced(ordinary) == ordinary)
    }

    @Test("Sanitized redaction hides numeric student identifiers")
    func numericIdentifierRedaction() {
        let result = ErrorReportRedactor.sanitized("student_id=1120260001&status=401")

        #expect(!result.contains("1120260001"))
        #expect(result.contains("401"))
    }

    @Test("Cancellation detection recognizes wrapped URL errors")
    func wrappedCancellation() {
        let wrapped = NSError(
            domain: "Test",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)]
        )

        #expect(TaskCancellation.matches(wrapped))
    }

    @Test("Host resolution detection recognizes nested DNS errors")
    func nestedHostResolution() {
        let wrapped = NSError(
            domain: "Test",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.cannotFindHost)]
        )

        #expect(isHostResolutionError(wrapped))
    }

    @Test("Non-DNS network errors are not reported as host resolution")
    func nonDNSError() {
        #expect(!isHostResolutionError(URLError(.timedOut)))
        #expect(!isHostResolutionError(URLError(.notConnectedToInternet)))
    }

    @Test("HTTPS upgrade preserves path query and fragment")
    func httpsUpgradePreservesComponents() throws {
        let source = try #require(URL(string: "http://example.com/a/b?q=1#fragment"))
        let upgraded = HTTPSURLUpgrade.upgradedURL(from: source)

        #expect(upgraded.absoluteString == "https://example.com/a/b?q=1#fragment")
    }


}
#endif
