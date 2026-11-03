import BIT101TestSupport
import ClientCore
import CommunityTransport
import Foundation
import Network
import ScheduleDomain
import SchedulePorts
import Testing
import os

@testable import ScheduleInfrastructure
@testable import TransportCore

extension ScheduleInfrastructureTests {
    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "{}", "null", "<html>gateway response</html>",
            #"{"datas":{"dqxnxq":{"rows":[{"DM":42}]}}}"#,
        ])
    func malformedSchoolResponsesClassification(_ wire: String) async {
        let selected = service(transport: SequenceTransport([(200, Data(wire.utf8))]))
        do {
            let _: CurrentTermResponse = try await selected.sendJSONRequest(
                baseURL: AppURL.required("https://example.invalid"), path: "/term")
            Issue.record("A malformed school payload must expose a response error")
        } catch {
            let actual = error as NSError
            let expected = ScheduleServiceError.invalidResponse as NSError
            #expect(actual.domain == expected.domain && actual.code == expected.code)
            #expect(actual.userInfo[NSUnderlyingErrorKey] is DecodingError)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [401, 403])
    func schoolAuthStatusRetainsSessionSignal(_ status: Int) async {
        let selected = service(
            transport: SequenceTransport([(status, Data(#"{"message":"expired"}"#.utf8))]))
        do {
            let _: CurrentTermResponse = try await selected.sendJSONRequest(
                baseURL: AppURL.required("https://example.invalid"), path: "/term")
            Issue.record("An expired school session must expose its recovery signal")
        } catch let error as ScheduleServiceError {
            if case .teachingCenterSessionExpired = error {
            } else {
                Issue.record("Unexpected recovery signal: \(error)")
            }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            #"{"data":{"success":false,"msg":"学期查询失败"}}"#,
            #"{"data":{"success":false}}"#,
            #"{"success":false,"msg":""}"#,
            #"{"datas":{"cxxszhxqkb":{"rows":[],"extParams":{"code":3,"msg":""}}}}"#,
            #"{"datas":{"cxxszhxqkb":{"rows":[],"extParams":{"code":3}}}}"#,
        ])
    func schoolBusinessFailureRetainsServiceMessage(json: String) async {
        let selected = service(transport: SequenceTransport([(200, Data(json.utf8))]))
        do {
            let _: CurrentTermResponse = try await selected.sendJSONRequest(
                baseURL: AppURL.required("https://example.invalid"), path: "/term")
            Issue.record("A school business failure must reach its consumer")
        } catch let error as ScheduleServiceError {
            if case .schoolResponse(let message) = error {
                #expect(message == (json.contains("学期查询失败") ? "学期查询失败" : "学校接口返回失败状态。"))
            } else {
                Issue.record("Unexpected business classification: \(error)")
            }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(.timeLimit(.minutes(1))) func schoolHttpFailureKeepsStatusDiagnosis() async {
        let selected = service(
            transport: SequenceTransport([(503, Data(#"{"message":"maintenance"}"#.utf8))]))
        do {
            let _: CurrentTermResponse = try await selected.sendJSONRequest(
                baseURL: AppURL.required("https://example.invalid"), path: "/term")
            Issue.record("A maintenance response must expose its HTTP status")
        } catch {
            #expect((error as NSError).code == 503)
        }
    }

    @Test(.timeLimit(.minutes(1))) func schoolTermsDecodeBoundary() async throws {
        let transport = SequenceTransport([
            (
                200,
                Data(
                    #"{"datas":{"xnxqcx":{"rows":[{"DM":"2026-2027-1"},{"DM":"2025-2026-2"}]}}}"#
                        .utf8)
            )
        ])
        let result: TermsResponse = try await service(transport: transport).sendJSONRequest(
            baseURL: AppURL.required("http://example.invalid"), path: "/terms", method: "POST",
            body: [("学期", "A+B & C")])
        #expect(result.datas.xnxqcx.rows.map(\.code) == ["2026-2027-1", "2025-2026-2"])
        #expect(transport.requests.first?.url?.scheme == "https")
        #expect(
            String(decoding: try #require(transport.requests.first?.httpBody), as: UTF8.self)
                == "%E5%AD%A6%E6%9C%9F=A%2BB%20%26%20C")
    }

    @Test(.timeLimit(.minutes(1))) func availableTermsAuthenticate() async throws {
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let state = TeachingCenterSessionState(cookieStorage: cookies)
        let terms = Data(
            #"""
            {"datas":{"xnxqcx":{"rows":[{"DM":"2026-2027-1"},{"DM":"2025-2026-2"},{"DM":"2026-\#
            2027-1"},{"DM":""}]}}}
            """#
            .utf8)
        let transport = SequenceTransport([
            (200, Data(#"{"data":{"wengine_vpn_ticket":"ticket"}}"#.utf8)),
            (200, Data("{}".utf8)), (200, Data("{}".utf8)), (200, terms), (200, terms),
        ])
        let service = service(transport: transport, state: state)
        #expect(try await service.fetchAvailableTerms() == ["2026-2027-1", "2025-2026-2"])
        #expect(try await service.fetchAvailableTerms() == ["2026-2027-1", "2025-2026-2"])
        #expect(transport.requests.count == 5)
        #expect(state.isPrepared(for: "module-school"))
        #expect(
            cookies.cookies?.contains { $0.name == "wengine_vpn_ticket" && $0.isSecure } == true)
        let data = try #require(transport.requests.first?.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body == ["username": "module-school", "password": "module-password"])
    }

    @Test(.timeLimit(.minutes(1))) func transportObservationsCaptureRequestContext() async throws {
        let observer = RequestObserverFactory()
        let transport = SuspendedSchoolCookies()
        let client = HTTPClient(transport: transport, observer: observer)
        let task = Task {
            try await client.send(
                URLRequest(url: AppURL.required("https://example.invalid/context")))
        }
        try await waitForTestEvent { !(transport.pending == nil) }
        observer.generation = 1
        transport.pending?.resume()
        _ = try await task.value
        #expect(observer.completions == [0])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, 1, 2])
    func delayedSchoolCookiesCancel(change: Int) async throws {
        let credentials = MutableSchoolCredentials()
        let owner = credentials.schoolSessionIdentity
        let transport = SuspendedSchoolCookies()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let state = TeachingCenterSessionState(cookieStorage: cookies)
        let service = ScheduleService(
            credentials: credentials, crypto: Crypto(), schoolSessionRestorer: Restorer(),
            teachingCenterState: state, transport: transport)
        let task = Task { try await service.ensureTeachingAuth() }
        try await waitForTestEvent { !(transport.pending == nil) }
        if change == 0 { credentials.currentStudentID = "school-b" }
        if change == 1 { credentials.generation += 1 }
        if change == 2 { task.cancel() }
        transport.pending?.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cookies.cookies?.isEmpty == true)
        #expect(state.hasUsableSession(for: credentials.currentStudentID) == false)
        if change < 2 {
            let challenge = BITLoginAuthenticationChallenge(
                challengeID: "old", accessToken: "token",
                status: "waiting_sms", maskedPhone: nil, expiresIn: 300, ownerIdentity: owner)
            await #expect(throws: CancellationError.self) {
                try await service.submitTeachingCode("123456", for: challenge)
            }
            #expect(transport.requests == 1)
        }
    }

    @Test(.timeLimit(.minutes(1))) func repeatedTeachingCenterEndsWithFailure() async throws {
        let bytes = Data(
            #"""
            {"detail":{"challenge_id":"fixture","access_token":"token","status":"authenticated\#
            ","expires_in":120}}
            """#
            .utf8)
        let transport = SequenceTransport(Array(repeating: (202, bytes), count: 3))
        do {
            try await service(transport: transport).ensureTeachingAuth()
            Issue.record("Repeated authentication should end with a fresh-operation instruction")
        } catch ScheduleServiceError.challengeInvalid(let message) {
            #expect(message.contains("再次要求认证"))
        }
        #expect(transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func teachingCenterSmsPreservesIdentityIdentity() async throws {
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let transport = SequenceTransport([
            (
                202,
                Data(
                    #"""
                    {"detail":{"challenge_id":"sms","access_token":"token","status":"waiting_s\#
                    ms","masked_phone":"138****0000","expires_in":300}}
                    """#
                    .utf8)
            )
        ])
        let service = service(
            transport: transport, state: TeachingCenterSessionState(cookieStorage: cookies))
        do {
            try await service.ensureTeachingAuth()
            Issue.record("Expected SMS challenge")
        } catch let ScheduleServiceError.secondFactorRequired(challenge) {
            #expect(challenge.challengeID == "sms" && challenge.accessToken == "token")
            #expect(challenge.maskedPhone == "138****0000" && !challenge.isExpired)
        }
        let expired = BITLoginAuthenticationChallenge(
            challengeID: "expired", accessToken: "token",
            status: "waiting_sms", maskedPhone: nil, expiresIn: 0, receivedAt: .distantPast)
        do {
            try await service.submitTeachingCode("123456", for: expired)
            Issue.record("Expected expired SMS challenge")
        } catch let ScheduleServiceError.challengeInvalid(message) {
            #expect(message.contains("验证码已过期"))
        }
        #expect(transport.requests.count == 1 && cookies.cookies?.isEmpty == true)
    }

    @Test(
        .timeLimit(.minutes(1)), arguments: ["html", "phone", "send", "input", "verify", "login"])
    func nativeSecondFactorKeepsOneOwnerSuspension(stage: String) async throws {
        for change in 0...2 {
            let credentials = MutableSchoolCredentials()
            let owner = credentials.schoolSessionIdentity
            let transport = SuspendedSecondFactor(stage)
            let service = ScheduleService(
                credentials: credentials, crypto: Crypto(),
                schoolSessionRestorer: AuthenticatedRestorer(),
                teachingCenterState: TeachingCenterSessionState(
                    cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
                ),
                transport: transport)
            let context = try #require(
                SchoolLoginHTMLParser.parseSecondFactorPage(
                    html: SuspendedSecondFactor.html,
                    baseURL: AppURL.required("https://sso.bit.edu.cn")))
            var input: CheckedContinuation<String, Never>?
            let handler: SchoolSMSCodeHandler = { _ in
                if stage == "input" { return await withCheckedContinuation { input = $0 } }
                return "123456"
            }
            let task = Task<Void, any Error> {
                if stage == "html" {
                    _ = try await service.refreshLexueCalendarURL(schoolSMSCodeHandler: handler)
                } else {
                    try await service.finishSchoolVerification(
                        context, handler: handler, smsDeliveryMode: .send, owner: owner)
                }
            }
            try await waitForTestEvent {
                !(stage == "input" ? input == nil : transport.pending == nil)
            }
            let count = transport.requests.count
            if change == 0 { credentials.currentStudentID = "school-b" }
            if change == 1 { credentials.generation += 1 }
            if change == 2 { task.cancel() }
            if stage == "input" {
                input?.resume(returning: "123456")
            } else {
                transport.pending?.resume()
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(transport.requests.count == count)
        }
    }

    @Test(.timeLimit(.minutes(1))) func nativeSecondFactorSubmitsCapturedStudent() async throws {
        let credentials = MutableSchoolCredentials()
        let transport = SuspendedSecondFactor("none")
        let service = ScheduleService(
            credentials: credentials, crypto: Crypto(),
            schoolSessionRestorer: AuthenticatedRestorer(),
            teachingCenterState: TeachingCenterSessionState(
                cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)),
            transport: transport)
        let context = try #require(
            SchoolLoginHTMLParser.parseSecondFactorPage(
                html: SuspendedSecondFactor.html,
                baseURL: AppURL.required("https://sso.bit.edu.cn")))
        try await service.finishSchoolVerification(
            context, handler: { _ in "123456" }, smsDeliveryMode: .send,
            owner: credentials.schoolSessionIdentity)
        let request = try #require(transport.requests.last)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(transport.requests.count == 4 && request.url?.path == "/cas/login")
        #expect(
            body.contains("username=school-a") && body.contains("execution=flow")
                && body.contains("password=123456"))
    }

    @Test(.timeLimit(.minutes(1))) func lexueSubscriptionUpgradesKeepsIdentity() async throws {
        let calendar = """
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:homework
            SUMMARY:作业
            DESCRIPTION:提交报告
            DTSTART:20300910T010000Z
            END:VEVENT
            END:VCALENDAR
            """
        let transport = SequenceTransport([(200, Data(calendar.utf8))])
        let existing = DDLEventRecord(
            id: "homework", group: "lexue", title: "作业", text: "",
            dueAt: Date(timeIntervalSince1970: 0), done: true)
        let service = service(transport: transport, restorer: AuthenticatedRestorer())
        let result = try await service.syncDDLEventsForPreflight(
            existingEvents: [existing],
            storedURL: "http://lexue.bit.edu.cn/calendar/export_execute.php?userid=42&token=test")
        #expect(result.events.count == 1 && result.events.first?.done == true)
        #expect(result.events.first?.title == "作业" && result.events.first?.text == "提交报告")
        #expect(transport.requests.first?.url?.scheme == "https")
        #expect(transport.requests.first?.url?.query == "userid=42&token=test")
    }
}

extension ClientCoreTests {
    @Test(.timeLimit(.minutes(1))) func cancelledRequestsSkipAdmission() async {
        let transport = StubTransport(result: .failure(CancellationError()))
        let observer = RecordingObserver()
        let client = HTTPClient(transport: transport, observer: observer)
        let operation = Task { @MainActor in
            try await client.send(URLRequest(url: url))
        }
        operation.cancel()

        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(transport.requests.isEmpty)
        #expect(observer.events.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [200, 503]) func cancelAfter(status: Int) async throws
    {
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        let observer = RecordingObserver()
        let client = HTTPClient(
            transport: CancellingResponseTransport(response: response), observer: observer)
        let operation = Task { @MainActor in
            try await client.send(URLRequest(url: url))
        }

        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(observer.events == ["willSend", "didFinish"])
        #expect(observer.recordedError is CancellationError)
    }

    @Test(.timeLimit(.minutes(1))) func httpStatusValidationRetainsServerMessage() async throws {
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil))
        let transport = StubTransport(
            result: .success((Data(#"{"message":"maintenance"}"#.utf8), response)))
        do {
            _ = try await HTTPClient(transport: transport, observer: nil).send(URLRequest(url: url))
            Issue.record("The status policy should reject 503")
        } catch let HTTPClientError.unacceptableStatus(code, message) {
            #expect(code == 503)
            #expect(message == "maintenance")
        }
    }

    @Test func httpErrorMessagesHaveReadableBound() throws {
        let large = String(repeating: "错误", count: 1_000)
        let json = try JSONSerialization.data(withJSONObject: ["message": large])
        let message = try #require(HTTPClient.errorMessage(from: json))
        #expect(
            message.count == HTTPResponseResourceLimits.maximumErrorCharacters
                && message.hasSuffix("…"))
        #expect(HTTPClient.errorMessage(from: Data("<html>gateway details</html>".utf8)) == nil)
        #expect(HTTPClient.errorMessage(from: Data(#"{"unrelated":"private body"}"#.utf8)) == nil)
        #expect(
            HTTPClient.errorMessage(
                from: Data(repeating: 65, count: HTTPResponseResourceLimits.maximumErrorBytes + 1))
                == nil)
        #expect(HTTPClient.errorMessage(from: Data("  plain response  ".utf8)) == "plain response")
        for data in [
            Data("<html>school login gateway</html>".utf8),
            Data(#"{"detail":{"error":"<html>gateway</html>"}}"#.utf8),
            Data(repeating: 65, count: HTTPResponseResourceLimits.maximumErrorBytes + 1),
        ] {
            #expect(BITLoginChallengeSupport.errorMessage(from: data) == nil)
        }
        #expect(BITLoginChallengeSupport.errorMessage(from: json) == message)
        #expect(
            BITLoginChallengeSupport.errorMessage(from: Data(#""school-service""#.utf8))
                == "school-service")
        #expect(
            HTTPClient.errorMessage(from: Data(#"{"detail":{"error":"school-service"}}"#.utf8))
                == "school-service")
    }

    @Test func cancellationAndSecureRedirectRules() {
        #expect(TaskCancellation.matches(URLError(.cancelled)))
        #expect(TaskCancellation.matches(CancellationError()))
        #expect(
            HTTPSURLUpgrade.upgradedURL(from: AppURL.required("http://example.invalid/path")).scheme
                == "https")
        #expect(HTTPSURLUpgrade.resolvedURL(from: "/next", relativeTo: url)?.path == "/next")
    }

    @Test func formEncodingPreservesFieldUnicode() {
        let body = HTTPFormEncoding.body([("name", "a+b &c?="), ("name", "中文"), ("empty", "")])
        #expect(
            String(decoding: body, as: UTF8.self)
                == "name=a%2Bb%20%26c%3F%3D&name=%E4%B8%AD%E6%96%87&empty=")
        #expect(HTTPFormEncoding.body([]).isEmpty)
    }

    @Test func wrappedNetworkErrorsChains() {
        #expect(TaskCancellation.matches(HTTPRequestNotSent(underlying: URLError(.cancelled))))
        #expect(isHostResolutionError(HTTPRequestNotSent(underlying: URLError(.cannotFindHost))))
        #expect(!TaskCancellation.matches(HTTPRequestNotSent(underlying: URLError(.timedOut))))
        func wrapped(_ error: Error) -> Error {
            (0..<20).reduce(error) { underlying, _ in
                NSError(
                    domain: "transport-wrapper", code: 1,
                    userInfo: [NSUnderlyingErrorKey: underlying])
            }
        }
        #expect(TaskCancellation.matches(wrapped(CancellationError())))
        #expect(isHostResolutionError(wrapped(URLError(.cannotFindHost))))
        #expect(isCertificateError(wrapped(URLError(.serverCertificateUntrusted))))
        #expect(isScheduleNetworkError(wrapped(URLError(.timedOut))))
        #expect(isSchoolTransportFailure(wrapped(ScheduleServiceError.schoolTransportFailure)))
        #expect(!TaskCancellation.matches(wrapped(URLError(.timedOut))))
        #expect(!isHostResolutionError(wrapped(URLError(.notConnectedToInternet))))
    }

    @Test func networkRecoveryTracksSelectedPathInstance() {
        let selected = NetworkPathState(snapshot: NetworkPathSnapshot(status: .checking))
        let independent = NetworkPathState(snapshot: NetworkPathSnapshot(status: .disconnected))
        #expect(selected.isReachable)
        selected.update(snapshot: NetworkPathSnapshot(status: .disconnected))
        #expect(!selected.isReachable)
        selected.update(
            snapshot: NetworkPathSnapshot(status: .init(pathStatus: .requiresConnection)))
        #expect(selected.isReachable && selected.snapshot.status == .requiresConnection)
        selected.update(
            snapshot: NetworkPathSnapshot(
                status: .connected, interfaces: [.wifi, .other], virtualNetworkLikely: true))
        #expect(selected.isReachable)
        #expect(selected.snapshot.interfaces == [.wifi, .other])
        #expect(selected.snapshot.virtualNetworkLikely)
        #expect(!independent.isReachable)
        #expect(independent.snapshot.interfaces.isEmpty)
    }
}
