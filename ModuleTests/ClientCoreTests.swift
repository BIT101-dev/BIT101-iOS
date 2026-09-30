import TransportCore
import ClientCore
import CommunityTransport
import Foundation
import Testing
import ScheduleDomain
@testable import ScheduleInfrastructure

private nonisolated enum ModuleCommunityError: Error, Equatable, CommunityAPIServiceError {
    case signedOut
    case invalidResponse
    static var communityNotLoggedIn: Self { .signedOut }
    static var communityInvalidResponse: Self { .invalidResponse }
}

@MainActor
struct ScheduleInfrastructureTests {
    private struct Credentials: SchoolCredentialsProviding {
        let currentStudentID = "module-school"
        let currentPassword = "module-password"
    }

    private struct Crypto: SchoolServiceCryptoProviding {
        let schoolURLCryptoPublicKey = "module-key"
        let browserUserAgent = "module-agent"
        func schoolProtectedHeaders() -> [String: String] { [:] }
        func encryptSchoolURLCryptoBody(object: [String: String], publicKeyPEM: String) throws -> (body: String, encryptedKey: String, aesKey: Data) {
            ("", "", Data())
        }
        func decryptSchoolURLCryptoResponse(_ data: Data, aesKey: Data) throws -> Data { data }
    }

    private struct Restorer: SchoolSessionRestoring {
        func restoreSchoolSessionIfNeeded() async throws -> String? { nil }
    }

    private func service(transport: any HTTPTransport) -> ScheduleService {
        ScheduleService(
            credentials: Credentials(), crypto: Crypto(), schoolSessionRestorer: Restorer(),
            teachingCenterState: TeachingCenterSessionState(cookieStorage: .sharedCookieStorage(forGroupContainerIdentifier: "BIT101ModulesTests.infrastructure")),
            transport: transport
        )
    }

    @Test func schoolFixtureParsingRunsInThePackageHost() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "BIT101-iOSTests/Fixtures/schedule-service-response.json")
        let data = try Data(contentsOf: fixture)
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)
        #expect(response.datas.cxxszhxqkb.extParams?.code == 1)
        #expect(response.datas.cxxszhxqkb.rows.count == 14)
        #expect(ScheduleService.schoolBusinessErrorMessage(from: data) == nil)
        #expect(try response.parsedCoursesCancellable().map(\.course) == response.courseRecords)
        #expect(response.courseRecords.count == 14)
        #expect(ScheduleService.schoolBusinessErrorMessage(from: Data(#"{"data":{"success":false,"msg":"school failure"}}"#.utf8)) == "school failure")
    }

    @Test func schoolTransportProjectsSecureURLsFormsAndDTOs() async throws {
        let transport = SequenceTransport([(200, Data(#"{"datas":{"dqxnxq":{"rows":[{"DM":"2026-2027-1"}]}}}"#.utf8))])
        let response: CurrentTermResponse = try await service(transport: transport).sendJSONRequest(
            baseURL: AppURL.required("http://example.invalid"), path: "/term", method: "POST", body: [("value", "a+b &c")]
        )
        #expect(response.datas.dqxnxq.rows.first?.code == "2026-2027-1")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.invalid/term")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
        #expect(String(decoding: try #require(request.httpBody), as: UTF8.self) == "value=a%2Bb%20%26c")
    }

    @Test func schoolTransportPreservesCertificateAndCancellationSemantics() async throws {
        let request = URLRequest(url: AppURL.required("https://example.invalid/probe"))
        let certificate = service(transport: StubTransport(result: .failure(URLError(.serverCertificateUntrusted))))
        do {
            _ = try await certificate.sendRequest(request)
            Issue.record("Expected school certificate failure")
        } catch let error as ScheduleServiceError {
            if case .schoolTransportFailure = error {} else { Issue.record("Received school error: \(error)") }
        }
        let cancelled = service(transport: StubTransport(result: .failure(URLError(.cancelled))))
        do {
            _ = try await cancelled.sendRequest(request)
            Issue.record("Expected transport cancellation")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
    }
}

@MainActor
private final class SequenceTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, Data)]

    init(_ responses: [(Int, Data)]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let (status, data) = responses.removeFirst()
        let response = try #require(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil))
        return (data, response)
    }
}

@MainActor
struct CommunityTransportTests {
    @Test func authenticatedRetryUsesRefreshedCookie() async throws {
        let transport = SequenceTransport([(401, Data()), (200, Data("result".utf8))])
        var cookie = "original-cookie"
        var refreshedCookies: [String] = []
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            cookie: { cookie },
            refresh: { observed in
                refreshedCookies.append(observed)
                cookie = "refreshed-cookie"
            }
        )
        let client: CommunityAPIClient<ModuleCommunityError> = session.client(errorDomain: "ModuleTests")
        let data = try await client.requestData(path: "user/info/0")
        #expect(data == Data("result".utf8))
        #expect(refreshedCookies == ["original-cookie"])
        #expect(transport.requests.map { $0.value(forHTTPHeaderField: "fake-cookie") } == ["original-cookie", "refreshed-cookie"])
    }

    @Test func secondUnauthorizedResponseEndsRetry() async throws {
        let transport = SequenceTransport([(401, Data()), (401, Data())])
        var refreshCount = 0
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            cookie: { "cookie" },
            refresh: { _ in refreshCount += 1 }
        )
        let client: CommunityAPIClient<ModuleCommunityError> = session.client(errorDomain: "ModuleTests")
        await #expect(throws: ModuleCommunityError.signedOut) {
            try await client.requestData(path: "user/info/0")
        }
        #expect(refreshCount == 1)
        #expect(transport.requests.count == 2)
    }

    @Test func signedOutSessionStopsBeforeTransport() async {
        let transport = SequenceTransport([])
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            cookie: { "" },
            refresh: { _ in Issue.record("Unexpected session refresh") }
        )
        let client: CommunityAPIClient<ModuleCommunityError> = session.client(errorDomain: "ModuleTests")
        await #expect(throws: ModuleCommunityError.signedOut) {
            try await client.requestData(path: "user/info/0")
        }
        #expect(transport.requests.isEmpty)
    }
}

@MainActor
private final class StubTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let result: Result<(Data, URLResponse), Error>

    init(result: Result<(Data, URLResponse), Error>) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try result.get()
    }
}

@MainActor
private final class RecordingObserver: HTTPClientObserving {
    var events: [String] = []
    var failure: Error?
    var sentData: Data?
    var recordedError: Error?

    func willSend(_ request: URLRequest) async throws {
        events.append("willSend")
        if let failure { throw failure }
    }

    func didFinish(
        request: URLRequest,
        data: Data?,
        response: URLResponse?,
        error: Error?,
        elapsed: TimeInterval
    ) async {
        events.append("didFinish")
        sentData = data
        recordedError = error
    }
}

@MainActor
struct ClientCoreTests {
    private let url = AppURL.required("https://example.invalid/module-test")

    @Test func schoolAuthenticationContractsDecodeAndProjectChallenge() async throws {
        let data = Data(#"{"challenge_id":"school-challenge","access_token":"token","status":"waiting_sms","masked_phone":"138****0000","expires_in":120}"#.utf8)
        let payload = try BITLoginChallengeSupport.decodePayload(from: data)
        let polled = try await BITLoginChallengeSupport.pollUntilActionable(payload, timeout: 1, interval: .milliseconds(1)) { _ in
            Issue.record("Actionable challenge should finish immediately")
            return payload
        }
        let challenge = BITLoginChallengeSupport.challenge(from: polled, accessToken: "token")
        #expect(challenge.challengeID == "school-challenge")
        #expect(challenge.status == "waiting_sms")
        #expect(challenge.maskedPhone == "138****0000")
        #expect(challenge.expiresIn == 120)
        #expect(BITLoginChallengeSupport.errorMessage(from: Data(#"{"detail":{"error":"school-service"}}"#.utf8)) == "school-service")
    }

    @Test func transportReportsSuccessfulResponse() async throws {
        let data = Data("response".utf8)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let transport = StubTransport(result: .success((data, response)))
        let observer = RecordingObserver()
        let result = try await HTTPClient(transport: transport, observer: observer).send(URLRequest(url: url))

        #expect(result.data == data)
        #expect(result.statusCode == 200)
        #expect(transport.requests.count == 1)
        #expect(observer.events == ["willSend", "didFinish"])
        #expect(observer.sentData == data)
        #expect(observer.recordedError == nil)
    }

    @Test func observerControlsRequestAdmission() async {
        let transport = StubTransport(result: .failure(URLError(.timedOut)))
        let observer = RecordingObserver()
        observer.failure = URLError(.notConnectedToInternet)
        do {
            _ = try await HTTPClient(transport: transport, observer: observer).send(URLRequest(url: url))
            Issue.record("Admission policy should throw its configured error")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(transport.requests.isEmpty)
        #expect(observer.events == ["willSend"])
    }

    @Test func transportReportsFailures() async {
        let transport = StubTransport(result: .failure(URLError(.timedOut)))
        let observer = RecordingObserver()
        do {
            _ = try await HTTPClient(transport: transport, observer: observer).send(URLRequest(url: url))
            Issue.record("The configured transport error should propagate")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(observer.events == ["willSend", "didFinish"])
        #expect((observer.recordedError as? URLError)?.code == .timedOut)
    }

    @Test func httpStatusValidationRetainsServerMessage() async throws {
        let response = try #require(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil))
        let transport = StubTransport(result: .success((Data(#"{"message":"maintenance"}"#.utf8), response)))
        do {
            _ = try await HTTPClient(transport: transport, observer: nil).send(URLRequest(url: url))
            Issue.record("The status policy should reject 503")
        } catch let HTTPClientError.unacceptableStatus(code, message) {
            #expect(code == 503)
            #expect(message == "maintenance")
        }
    }

    @Test func cancellationAndSecureRedirectRules() {
        #expect(TaskCancellation.matches(URLError(.cancelled)))
        #expect(TaskCancellation.matches(CancellationError()))
        #expect(HTTPSURLUpgrade.upgradedURL(from: AppURL.required("http://example.invalid/path")).scheme == "https")
        #expect(HTTPSURLUpgrade.resolvedURL(from: "/next", relativeTo: url)?.path == "/next")
    }
}
