import ClientCore
import Foundation
import Testing
import TransportCore

@testable import BIT101_iOS

#if DEBUG || RELEASE_NETWORK_SMOKE
@MainActor
struct NetworkSmokeSMSPromptTests {
    @Test(.timeLimit(.minutes(1))) func submissionResumesWaitingKeepsIsolated() async throws {
        let prompt = ReleaseNetworkSmokeSMSPrompt()
        let request = SchoolSMSCodeRequest(maskedPhone: "138****0000", purpose: "jwb")
        let waiting = Task { try await prompt.requestCode(request) }
        try await waitForTestEvent { !(prompt.request == nil) }
        do {
            _ = try await prompt.requestCode(
                SchoolSMSCodeRequest(maskedPhone: "", purpose: "webvpn"))
            Issue.record("并行请求应保留当前验证码等待")
        } catch { #expect(TaskCancellation.matches(error)) }
        #expect(prompt.request?.id == request.id)
        prompt.submit("123456")
        #expect(try await waiting.value == "123456")
        #expect(prompt.request == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancelReleasesWait() async throws {
        let prompt = ReleaseNetworkSmokeSMSPrompt()
        let request = SchoolSMSCodeRequest(maskedPhone: "138****0000", purpose: "jwb")
        let waiting = Task { try await prompt.requestCode(request) }
        try await waitForTestEvent { !(prompt.request == nil) }
        waiting.cancel()
        do {
            _ = try await waiting.value
            Issue.record("取消应终止验证码等待")
        } catch { #expect(TaskCancellation.matches(error)) }
        #expect(prompt.request == nil)
        let next = Task { try await prompt.requestCode(request) }
        try await waitForTestEvent { !(prompt.request == nil) }
        prompt.submit("654321")
        #expect(try await next.value == "654321")
        #expect(prompt.request == nil)
    }
}
#endif
