import BIT101TestSupport
import ClientCore
import Foundation
import SchedulePorts
@testable import ScheduleInfrastructure
@testable import TransportCore
import Testing

@MainActor
struct TeachingCenterAvailabilityTests {
    private final class DirectRestorer: SchoolSessionRestoring {
        private(set) var requests = 0
        func restoreSchoolSessionIfNeeded() async throws -> String? {
            requests += 1
            return "teaching-owner"
        }
    }

    private final class RouteTransport: HTTPTransport {
        let rejectionStatus: Int
        var authenticationRequests = 0
        var vpnTermRequests = 0
        var directTermRequests = 0
        init(rejectionStatus: Int) { self.rejectionStatus = rejectionStatus }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            var status = 200
            let text: String
            if url.path.hasSuffix("/jxzxehall/cookies") {
                authenticationRequests += 1
                if rejectionStatus == -1 {
                    status = 202
                    text = #"{"detail":{"challenge_id":"fixture","access_token":"fixture","status":"failed","error":"认证信息无效。 [status=401, risk=ustc-token, flow=replaced]"}}"#
                } else { text = #"{"data":{"wengine_vpn_ticket":"ticket"}}"# }
            } else if url.path.contains("getAppConfig") || url.path.hasSuffix("/i18n.do") {
                text = "{}"
            } else if url.host == "webvpn.bit.edu.cn" {
                vpnTermRequests += 1
                status = rejectionStatus
                text = #"{"msg":"您的会话已经过期，请重新登录"}"#
            } else {
                directTermRequests += 1
                text = #"{"datas":{"xnxqcx":{"rows":[{"DM":"term"}]}}}"#
            }
            return (Data(text.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let response = try await data(for: request)
            if let maximumBytes, response.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return response
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [200, 401, 403, -1])
    func exhaustedWebVPNSessionRecoveryUsesAuthenticatedDirectRoute(status: Int) async throws {
        let credentials = Credentials(), restorer = DirectRestorer(), transport = RouteTransport(rejectionStatus: status)
        let state = TeachingCenterSessionState(cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage))
        defer { state.invalidate() }
        let service = ScheduleService(credentials: credentials, crypto: Crypto(), schoolSessionRestorer: restorer,
            teachingCenterState: state, transport: transport)
        #expect(try await service.fetchAvailableTerms() == ["term"])
        let authenticationRequests = status == -1 ? 1 : 3
        #expect(transport.authenticationRequests == authenticationRequests && transport.vpnTermRequests == (status == -1 ? 0 : 3))
        #expect(transport.directTermRequests == 1 && restorer.requests == 1)
        #expect(state.shouldPreferDirect(for: credentials.currentStudentID))
        #expect(try await service.fetchAvailableTerms() == ["term"])
        #expect(transport.authenticationRequests == authenticationRequests && transport.directTermRequests == 2)
        #expect(restorer.requests == 1)
        #expect(credentials.currentPassword == "password")
    }

    private final class UnavailableNativeAuthenticator: SchoolServiceAuthenticating {
        func authenticate(_ target: SchoolServiceTarget) async throws -> SchoolAuthenticatedSession {
            throw NativeSchoolAuthenticationError.invalidResponse
        }
    }

    @Test(.timeLimit(.minutes(1))) func nativeSessionRecoveryRetainsTheWorkingDirectRoute() async throws {
        let credentials = Credentials(), restorer = DirectRestorer(), transport = RouteTransport(rejectionStatus: 200)
        let state = TeachingCenterSessionState(cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage))
        defer { state.invalidate() }
        let service = ScheduleService(credentials: credentials, crypto: Crypto(), schoolSessionRestorer: restorer,
            teachingCenterState: state, transport: transport, nativeAuthenticator: UnavailableNativeAuthenticator())
        #expect(try await service.fetchAvailableTerms() == ["term"])
        #expect(transport.authenticationRequests == 3 && transport.vpnTermRequests == 3)
        #expect(transport.directTermRequests == 1 && restorer.requests == 1)
        #expect(state.shouldPreferDirect(for: credentials.currentStudentID))
    }

    private final class Credentials: SchoolCredentialsProviding {
        var generation = 0
        let currentStudentID = "teaching-owner"
        let currentPassword = "password"
        var schoolSessionIdentity: SchoolSessionIdentity { .init(accountIdentifier: currentStudentID, generation: generation) }
    }
    private struct Crypto: SchoolServiceCryptoProviding {
        let schoolURLCryptoPublicKey = "key"
        let browserUserAgent = "fixture"
        func schoolProtectedHeaders() -> [String: String] { [:] }
        func encryptSchoolURLCryptoBody(object: [String: String], publicKeyPEM: String) throws -> (body: String, encryptedKey: String, aesKey: Data) { ("", "", Data()) }
        func decryptSchoolURLCryptoResponse(_ data: Data, aesKey: Data) throws -> Data { data }
    }
    private struct Restorer: SchoolSessionRestoring {
        func restoreSchoolSessionIfNeeded() async throws -> String? { nil }
    }
    private final class FailureTransport: HTTPTransport {
        let mode: String
        var authenticationRequests = 0
        var termRequests = 0
        init(mode: String) { self.mode = mode }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let text: String
            if url.path.hasSuffix("/jxzxehall/cookies") {
                authenticationRequests += 1
                text = #"{"data":{"wengine_vpn_ticket":"ticket"}}"#
            } else if url.path.contains("getAppConfig") || url.path.hasSuffix("/i18n.do") {
                text = mode == "denied" ? "<!doctype html><html>对不起，无权访问该资源</html>" : "{}"
            } else {
                termRequests += 1
                if mode == "business" { text = #"{"success":false,"msg":"学期查询失败"}"# }
                else if mode == "unavailable" || termRequests == 1 { text = #"{"msg":"您的会话已经过期，请重新登录"}"# }
                else { text = #"{"datas":{"xnxqcx":{"rows":[{"DM":"term"}]}}}"# }
            }
            return (Data(text.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
    }
    private final class Observer: HTTPClientObserving {
        var failures: [String] = []
        func willSend(_ request: URLRequest) async throws {}
        func didFinish(request: URLRequest, finalRequest: URLRequest?, data: Data?, response: URLResponse?, error: Error?, elapsed: TimeInterval) async {
            if let error { failures.append(error.localizedDescription) }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["recovered", "unavailable", "business", "denied"])
    func schoolBusinessFailuresRecoverWithinTheirSessionAndPreserveCredentials(mode: String) async throws {
        let credentials = Credentials(), transport = FailureTransport(mode: mode), observer = Observer()
        let owner = credentials.schoolSessionIdentity
        let state = TeachingCenterSessionState(cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage))
        defer { state.invalidate() }
        let service = ScheduleService(credentials: credentials, crypto: Crypto(), schoolSessionRestorer: Restorer(),
            teachingCenterState: state, transport: transport, observer: observer)
        do {
            #expect(try await service.fetchAvailableTerms() == ["term"])
            #expect(mode == "recovered")
        } catch let error as ScheduleServiceError {
            switch mode {
            case "unavailable":
                guard case .authenticationFailed(let message) = error else { Issue.record("持续失效应保留双路线恢复结果"); return }
                #expect(message.contains("WebVPN 教学中心恢复失败") && message.contains("学校 SSO 直连恢复失败"))
            case "denied":
                guard case .schoolResponse(let message) = error else { Issue.record("学校资源限制应保留业务来源"); return }
                #expect(message.contains("无权访问该资源"))
            case "business":
                guard case .schoolResponse("学期查询失败") = error else { Issue.record("业务失败应保留原始原因"); return }
            default: Issue.record(error)
            }
        }
        #expect(transport.authenticationRequests == (mode == "recovered" ? 2 : mode == "unavailable" ? 3 : 1))
        #expect(transport.termRequests == (mode == "recovered" ? 2 : mode == "unavailable" ? 3 : mode == "denied" ? 0 : 1))
        #expect(observer.failures.count == (mode == "unavailable" ? 3 : 1))
        #expect(credentials.schoolSessionIdentity == owner && credentials.currentPassword == "password")
    }

    private final class Transport: HTTPTransport {
        var authenticationRequests = 0
        var configurationRequests = 0
        var languageRequests = 0
        var authentication: CheckedContinuation<Void, Never>?
        var preparation: CheckedContinuation<Void, Never>?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let text: String
            if url.path.hasSuffix("/jxzxehall/cookies") {
                authenticationRequests += 1
                await withCheckedContinuation { authentication = $0 }
                text = #"{"data":{"wengine_vpn_ticket":"ticket"}}"#
            } else if url.path.contains("getAppConfig") {
                configurationRequests += 1
                await withCheckedContinuation { preparation = $0 }
                text = "{}"
            } else if url.path.hasSuffix("/i18n.do") {
                languageRequests += 1; text = "{}"
            } else { text = #"{"datas":{"xnxqcx":{"rows":[{"DM":"term"}]}}}"# }
            return (Data(text.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let response = try await data(for: request)
            if let maximumBytes, response.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return response
        }
        func releaseAuthentication() { authentication?.resume(); authentication = nil }
        func releasePreparation() { preparation?.resume(); preparation = nil }
    }

    private struct CourseTransport: HTTPTransport {
        let examAvailable: Bool
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let body: String
            switch url.lastPathComponent {
            case "cxxsksap.do":
                if !examAvailable { throw URLError(.networkConnectionLost) }
                body = #"{"datas":{"cxxsksap":{"rows":[]}}}"#
            case "cxxszhxqkb.do":
                body = #"{"datas":{"cxxszhxqkb":{"rows":[{"KCM":"已排课程","SKXQ":1,"KSJC":1,"JSJC":2,"ZCMC":"1-2周"}]}}}"#
            case "cxzkbrq.do": body = #"{"data":[{"XQ":1,"RQ":"2026-09-07"}]}"#
            default: throw URLError(.unsupportedURL)
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func courseSyncKeepsAvailableCoursesWhenTheExamSourceFails(examAvailable: Bool) async throws {
        let credentials = Credentials()
        let state = TeachingCenterSessionState(cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage))
        state.markDirectPreferred(for: credentials.currentStudentID)
        state.markPrepared(for: credentials.currentStudentID)
        let service = ScheduleService(credentials: credentials, crypto: Crypto(), schoolSessionRestorer: Restorer(),
            teachingCenterState: state, transport: CourseTransport(examAvailable: examAvailable))
        let payload = try await service.syncCourses(term: "2026-2027-1")
        #expect(payload.courses.count == 1 && payload.firstDayString == "2026-09-07")
        #expect((payload.exams == []) == examAvailable)
        #expect(payload.warnings.isEmpty == examAvailable)
    }

    private final class LexueTransport: HTTPTransport {
        let requiresSMS: Bool
        var expiredSubscription = false
        var requests: [URLRequest] = []
        init(requiresSMS: Bool) { self.requiresSMS = requiresSMS }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let url = try #require(request.url)
            if requiresSMS, url.host == "lexue.bit.edu.cn" { throw URLError(.cannotConnectToHost) }
            if expiredSubscription, url.host == "webvpn.bit.edu.cn" { throw URLError(.cannotConnectToHost) }
            let text: String
            let responseURL: URL
            if expiredSubscription, url.path == "/expired.ics" {
                responseURL = url; text = "<html>订阅令牌已失效</html>"
            } else if expiredSubscription, url.path == "/" {
                responseURL = url; text = #"<script>config={"sesskey":"session"}</script>"#
            } else if expiredSubscription, url.path == "/calendar/export.php" {
                responseURL = url; text = #"<input value="https://lexue.bit.edu.cn/fresh.ics">"#
            } else if requiresSMS {
                responseURL = AppURL.required("https://sso.bit.edu.cn/cas/login")
                text = #"<form id="secondSmsLoginForm" action="/cas/login"><p id="login-page-flowkey">sms-flow</p><p id="user-object-id">owner</p></form>"#
            } else {
                responseURL = url
                text = url.host == "lexue.bit.edu.cn"
                    ? "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:homework\nSUMMARY:作业\nDTSTART:20300910T010000Z\nEND:VEVENT\nEND:VCALENDAR"
                    : #"{"datas":{"xnxqcx":{"rows":[{"DM":"term"}]}}}"#
            }
            return (Data(text.utf8), try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let response = try await data(for: request)
            if let maximumBytes, response.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return response
        }
    }

    @Test(.timeLimit(.minutes(1))) func expiredLexueSubscriptionRefreshesOnTheWorkingDirectRoute() async throws {
        let credentials = Credentials(), transport = LexueTransport(requiresSMS: false), native = InteractionAuthenticator()
        transport.expiredSubscription = true
        let state = TeachingCenterSessionState(cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage))
        let service = ScheduleService(credentials: credentials, crypto: Crypto(), schoolSessionRestorer: DirectRestorer(),
            teachingCenterState: state, transport: transport, nativeAuthenticator: native)
        let result = try await service.syncDDLEvents(existingEvents: [], storedURL: "https://lexue.bit.edu.cn/expired.ics",
            schoolSMSCodeHandler: nil, smsDeliveryMode: .send)
        #expect(result.url == "https://lexue.bit.edu.cn/fresh.ics" && result.events.count == 1)
        #expect(transport.requests.compactMap { $0.url?.path } == ["/expired.ics", "/", "/calendar/export.php", "/fresh.ics"])
        #expect(transport.requests.allSatisfy { $0.url?.host == "lexue.bit.edu.cn" } && native.calls == 0)
    }
    private final class InteractionAuthenticator: SchoolServiceAuthenticating {
        var calls = 0
        func authenticate(_ target: SchoolServiceTarget) async throws -> SchoolAuthenticatedSession {
            calls += 1
            throw NativeSchoolAuthenticationError.additionalVerification
        }
    }

    @Test(.timeLimit(.minutes(1))) func lexueDirectSyncPreservesThePreparedTeachingCenterRoute() async throws {
        let credentials = Credentials(), transport = LexueTransport(requiresSMS: false), native = InteractionAuthenticator()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        cookies.setCookie(try #require(HTTPCookie(properties: [.domain: "webvpn.bit.edu.cn", .path: "/",
            .name: "wengine_vpn_ticket", .value: "ticket", .secure: "TRUE"])))
        let state = TeachingCenterSessionState(cookieStorage: cookies)
        state.selectOwner(credentials.schoolSessionIdentity)
        state.markAuthenticated(for: credentials.currentStudentID)
        state.markPrepared(for: credentials.currentStudentID)
        let revision = state.sessionRevision
        let service = ScheduleService(credentials: credentials, crypto: Crypto(), schoolSessionRestorer: DirectRestorer(),
            teachingCenterState: state, transport: transport, nativeAuthenticator: native)
        let result = try await service.syncDDLEvents(existingEvents: [],
            storedURL: "https://lexue.bit.edu.cn/calendar/export_execute.php?userid=42", schoolSMSCodeHandler: nil, smsDeliveryMode: .send)
        #expect(result.events.count == 1)
        #expect(state.hasUsableSession(for: credentials.currentStudentID) && state.isPrepared(for: credentials.currentStudentID))
        #expect(state.sessionRevision == revision && !state.shouldPreferDirect(for: credentials.currentStudentID))
        #expect(try await service.fetchAvailableTerms() == ["term"])
        #expect(native.calls == 0 && transport.requests.count == 2)
        #expect(transport.requests.last?.url?.host == "webvpn.bit.edu.cn")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func lexuePreflightUsesAvailableCookiesAndStopsBeforeInteractiveSMS(sync: Bool) async throws {
        let credentials = Credentials(), transport = LexueTransport(requiresSMS: true), native = InteractionAuthenticator()
        let state = TeachingCenterSessionState(cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage))
        let service = ScheduleService(credentials: credentials, crypto: Crypto(), schoolSessionRestorer: DirectRestorer(),
            teachingCenterState: state, transport: transport, nativeAuthenticator: native)
        do {
            if sync { _ = try await service.syncDDLEventsForPreflight(existingEvents: [], storedURL: "") }
            else { _ = try await service.refreshLexueCalendarURLForPreflight() }
            Issue.record("短信探测应返回待验证状态。")
        } catch ScheduleServiceError.schoolSecondFactorRequired {
            #expect(native.calls == 0)
        }
        #expect(transport.requests.count == 2 && transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func concurrentServicesShareAuthenticationAndPreparation(cancelFirst: Bool) async throws {
        let credentials = Credentials(), transport = Transport()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let state = TeachingCenterSessionState(cookieStorage: cookies)
        defer { transport.releaseAuthentication(); transport.releasePreparation(); state.invalidate() }
        func service() -> ScheduleService {
            .init(credentials: credentials, crypto: Crypto(), schoolSessionRestorer: Restorer(), teachingCenterState: state, transport: transport)
        }
        let firstService = service(), secondService = service()
        let first = Task { try await firstService.fetchAvailableTerms() }
        defer { first.cancel() }
        try await waitForTestEvent { transport.authentication != nil }
        let second = Task { try await secondService.prepareTeachingCenterAccess() }
        defer { second.cancel() }
        try await waitForTestEvent { state.authenticationRecovery.waitingConsumerCount == 2 }
        if cancelFirst {
            first.cancel()
            await #expect(throws: CancellationError.self) { try await first.value }
            try await waitForTestEvent { state.authenticationRecovery.waitingConsumerCount == 1 }
        }
        #expect(transport.authenticationRequests == 1)
        transport.releaseAuthentication()
        try await waitForTestEvent { transport.preparation != nil && state.preparationRecovery.waitingConsumerCount == (cancelFirst ? 1 : 2) }
        #expect(transport.configurationRequests == 1)
        transport.releasePreparation()
        try await second.value
        if !cancelFirst { #expect(try await first.value == ["term"]) }
        #expect(transport.authenticationRequests == 1 && transport.languageRequests == 1)
        #expect(try await service().fetchAvailableTerms() == ["term"])
        #expect(transport.authenticationRequests == 1 && transport.configurationRequests == 1)
    }
}
