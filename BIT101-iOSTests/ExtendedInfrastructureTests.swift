#if EXTENDED_AUTOMATION
import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Extended infrastructure contracts")
struct ExtendedInfrastructureTests {
    @Test("Forced redaction handles nested credentials")
    func nestedCredentialRedaction() {
        let value = #"{"profile":{"name":"张三"},"auth":{"password":"secret","access_token":"abc"}}"#
        let result = ErrorReportRedactor.forced(value)

        #expect(result.contains("张三"))
        #expect(!result.contains("secret"))
        #expect(!result.contains("abc"))
        #expect(result.contains("[REDACTED]"))
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

    @Test("HTTPS upgrade leaves path and query unchanged")
    func httpsUpgradePreservesComponents() throws {
        let source = try #require(URL(string: "http://example.com/a/b?q=1#fragment"))
        let upgraded = HTTPSURLUpgrade.upgradedURL(from: source)

        #expect(upgraded.absoluteString == "https://example.com/a/b?q=1#fragment")
    }

    @Test("Time slots clamp negative formatting values")
    func timeSlotFormatting() {
        #expect(TimeSlot.parseMinutes("08:30") == 510)
        #expect(TimeSlot.formatMinutes(-1) == "00:00")
        #expect(TimeSlot.formatMinutes(510) == "08:30")
    }

    @Test("Relative DDL editor keeps completion state separate from sync")
    func ddlCompletionState() {
        let event = DDLEventRecord(
            id: "event",
            group: "main",
            title: "任务",
            text: "说明",
            dueAt: Date(timeIntervalSince1970: 100),
            done: false
        )

        let toggled = ScheduleDDLEditor.togglingDone(id: event.id, in: [event])
        #expect(toggled.first?.done == true)
        #expect(ScheduleDDLEditor.togglingDone(id: "missing", in: toggled) == toggled)
    }
}
#endif
