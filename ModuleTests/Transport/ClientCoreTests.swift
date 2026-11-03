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

nonisolated enum ModuleCommunityError: Error, Equatable, CommunityAPIServiceError {
    case signedOut
    case invalidResponse
    static var communityNotLoggedIn: Self { .signedOut }
    static var communityInvalidResponse: Self { .invalidResponse }
}

@MainActor
struct ScheduleInfrastructureTests {
    nonisolated struct SuspendedJSONResponse: Decodable, Sendable {
        static let state = OSAllocatedUnfairLock(
            initialState: (entered: false, gate: DispatchSemaphore(value: 0)))
        init(from decoder: any Decoder) throws {
            let gate = Self.state.withLock { state in
                state.entered = true
                return state.gate
            }
            guard gate.wait(timeout: .now() + 10) == .success else { throw URLError(.timedOut) }
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func decodedSchoolResponsesGeneration(sameAccount: Bool) async throws {
        SuspendedJSONResponse.state.withLock { $0 = (false, DispatchSemaphore(value: 0)) }
        let credentials = MutableSchoolCredentials()
        let url = AppURL.required("https://example.invalid/decoded-owner")
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let transport = StubTransport(result: .success((Data(#"{"ok":true}"#.utf8), response)))
        let service = ScheduleService(
            credentials: credentials, crypto: Crypto(), schoolSessionRestorer: Restorer(),
            teachingCenterState: TeachingCenterSessionState(
                cookieStorage: .sharedCookieStorage(
                    forGroupContainerIdentifier: "BIT101ModulesTests.decode-owner")),
            transport: transport)
        let task = Task { () throws -> SuspendedJSONResponse in
            try await service.sendJSONRequest(baseURL: url, path: "/decoded-owner")
        }
        defer {
            task.cancel()
            _ = SuspendedJSONResponse.state.withLock { $0.gate.signal() }
        }
        try await waitForTestEvent { SuspendedJSONResponse.state.withLock { $0.entered } }
        if sameAccount {
            credentials.generation += 1
        } else {
            credentials.currentStudentID = "school-b"
        }
        _ = SuspendedJSONResponse.state.withLock { $0.gate.signal() }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.timeLimit(.minutes(1))) func classroomOccupancyParsingPreservesResponse() async throws {
        for (value, expected) in [("1, 2", [1, 2]), ("", []), ("  ", [])] {
            let data = try JSONSerialization.data(withJSONObject: [
                "datas": ["cxkxjasqk": ["rows": [["JASMC": "A101", "ZYJC": value]]]]
            ])
            let response = try JSONDecoder().decode(ClassroomListResponse.self, from: data)
            #expect(try await response.classroomRecords().first?.busyTimeCodes == expected)
        }
        for value in ["bad", "1,bad", "1,,2", "0", "-1", String(Int.max)] {
            let data = try JSONSerialization.data(withJSONObject: [
                "datas": ["cxkxjasqk": ["rows": [["JASMC": "A101", "ZYJC": value]]]]
            ])
            let response = try JSONDecoder().decode(ClassroomListResponse.self, from: data)
            await #expect(throws: ScheduleServiceError.self) {
                try await response.classroomRecords()
            }
        }
    }

    @Test func redirectAuthHeadersStayBoundTheirOrigin() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = AppURL.required("https://auth.example/login")
        let response = try #require(
            HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil))
        let task = session.dataTask(with: origin)
        let delegate = HTTPSUpgradingRedirectDelegate()
        for sameOrigin in [true, false] {
            var request = URLRequest(
                url: AppURL.required(
                    sameOrigin ? "https://auth.example/next" : "https://other.example/next"))
            for header in [
                "Authorization", "Proxy-Authorization", "Cookie", "fake-cookie",
                "x-challenge-token",
            ] {
                request.setValue("fixture-token", forHTTPHeaderField: header)
            }
            var result: URLRequest?
            delegate.urlSession(
                session, task: task, willPerformHTTPRedirection: response,
                newRequest: request, completionHandler: { result = $0 })
            let redirected = try #require(result)
            for header in [
                "Authorization", "Proxy-Authorization", "Cookie", "fake-cookie",
                "X-Challenge-Token",
            ] {
                #expect(
                    redirected.value(forHTTPHeaderField: header)
                        == (sameOrigin ? "fixture-token" : nil))
            }
        }
    }

    struct Credentials: SchoolCredentialsProviding {
        var schoolSessionIdentity: SchoolSessionIdentity {
            .init(accountIdentifier: currentStudentID, generation: 0)
        }
        let currentStudentID = "module-school"
        let currentPassword = "module-password"
    }

    struct Crypto: SchoolServiceCryptoProviding {
        let schoolURLCryptoPublicKey = "module-key"
        let browserUserAgent = "module-agent"
        func schoolProtectedHeaders() -> [String: String] { [:] }
        func encryptSchoolBody(object: [String: String], publicKeyPEM: String) throws -> (
            body: String, encryptedKey: String, aesKey: Data
        ) {
            ("", "", Data())
        }
        func decryptSchoolResponse(_ data: Data, aesKey: Data) throws -> Data { data }
    }

    struct Restorer: SchoolSessionRestoring {
        func restoreSchoolSession() async throws -> String? { nil }
    }

    func service(
        transport: any HTTPTransport, observer: (any HTTPClientObserving & Sendable)? = nil,
        state: TeachingCenterSessionState? = nil, restorer: any SchoolSessionRestoring = Restorer()
    ) -> ScheduleService {
        ScheduleService(
            credentials: Credentials(), crypto: Crypto(), schoolSessionRestorer: restorer,
            teachingCenterState: state
                ?? TeachingCenterSessionState(
                    cookieStorage: .sharedCookieStorage(
                        forGroupContainerIdentifier: "BIT101ModulesTests.infrastructure")),
            transport: transport, observer: observer
        )
    }

    @Test func schoolFixtureParsingRunsInThePackageHost() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "BIT101-iOSTests/Fixtures/schedule-service-response.json")
        let data = try Data(contentsOf: fixture)
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)
        #expect(response.datas.cxxszhxqkb.extParams?.code == 1)
        #expect(response.datas.cxxszhxqkb.rows.count == 14)
        #expect(ScheduleService.schoolBusinessError(from: data) == nil)
        #expect(try response.parsedCoursesCancellable().map(\.course) == response.courseRecords)
        #expect(response.courseRecords.count == 14)
        #expect(
            ScheduleService.schoolBusinessError(
                from: Data(#"{"data":{"success":false,"msg":"school failure"}}"#.utf8))
                == "school failure")
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            (#"{"KCM":"待排课程"}"#, true),
            (#"{"KCM":"已排课程","SKXQ":1,"KSJC":1,"JSJC":2,"ZCMC":"1-2周"}"#, true),
            (#"{"KCM":"课程","SKXQ":8,"KSJC":1,"JSJC":2,"ZCMC":"1周"}"#, false),
            (#"{"KCM":"课程","SKXQ":1,"KSJC":2,"JSJC":1,"ZCMC":"1周"}"#, false),
            (#"{"KCM":"课程","SKXQ":1,"ZCMC":"1周"}"#, false),
            (#"{"KCM":"课程","SKXQ":1,"KSJC":1,"JSJC":2}"#, false),
            (#"{"KCM":"课程","ZCMC":"1周"}"#, false),
        ])
    func schoolCoursePlacementContractPreservesRows(fixture: (String, Bool)) async throws {
        let (row, valid) = fixture
        let data = Data((#"{"datas":{"cxxszhxqkb":{"rows":["# + row + #"]}}}"#).utf8)
        let transport = SequenceTransport([(200, data)])
        if valid {
            #expect(
                try await service(transport: transport).fetchParsedCourses(term: "2026-2027-1")
                    .count == 1)
        } else {
            await #expect(throws: ScheduleServiceError.self) {
                try await service(transport: transport).fetchParsedCourses(term: "2026-2027-1")
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func schoolTransportProjectsSecureUrLsForms() async throws {
        let transport = SequenceTransport([
            (200, Data(#"{"datas":{"dqxnxq":{"rows":[{"DM":"2026-2027-1"}]}}}"#.utf8))
        ])
        let response: CurrentTermResponse = try await service(transport: transport).sendJSONRequest(
            baseURL: AppURL.required("http://example.invalid"), path: "/term", method: "POST",
            body: [("value", "a+b &c")]
        )
        #expect(response.datas.dqxnxq.rows.first?.code == "2026-2027-1")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.invalid/term")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
        #expect(
            String(decoding: try #require(request.httpBody), as: UTF8.self) == "value=a%2Bb%20%26c")
    }

    @Test(.timeLimit(.minutes(1))) func schoolTransportPreservesCertificate() async throws {
        let request = URLRequest(url: AppURL.required("https://example.invalid/probe"))
        let certificate = service(
            transport: StubTransport(result: .failure(URLError(.serverCertificateUntrusted))))
        do {
            _ = try await certificate.sendRequest(request)
            Issue.record("Expected school certificate failure")
        } catch let error as ScheduleServiceError {
            if case .schoolTransportFailure = error {
            } else {
                Issue.record("Received school error: \(error)")
            }
        }
        let cancelled = service(transport: StubTransport(result: .failure(URLError(.cancelled))))
        do {
            _ = try await cancelled.sendRequest(request)
            Issue.record("Expected transport cancellation")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
    }

    @Test(.timeLimit(.minutes(1))) func schoolTransportRecordsResponses() async throws {
        let request = URLRequest(url: AppURL.required("http://example.invalid/diagnostic-probe"))
        let observer = RecordingObserver()
        let transport = SequenceTransport([(200, Data("school response".utf8))])
        _ = try await service(transport: transport, observer: observer).sendRequest(request)
        #expect(observer.events == ["willSend", "didFinish"])
        #expect(observer.sentData == Data("school response".utf8))
        #expect(observer.recordedRequest?.url?.scheme == "https")
        #expect(observer.recordedError == nil)

        for code in [URLError.Code.cannotFindHost, .serverCertificateUntrusted, .cancelled] {
            let failedObserver = RecordingObserver()
            let failedService = service(
                transport: StubTransport(result: .failure(URLError(code))), observer: failedObserver
            )
            do {
                _ = try await failedService.sendRequest(request)
                Issue.record("Expected a school transport failure")
            } catch {
                #expect(failedObserver.events == ["willSend", "didFinish"])
                #expect((failedObserver.recordedError as? URLError)?.code == code)
                #expect(failedObserver.recordedRequest?.url?.scheme == "https")
            }
        }
    }
}

@MainActor
final class SequenceTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, Data)]

    init(_ responses: [(Int, Data)]) { self.responses = responses }

    func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
        let result = try await data(for: request)
        if let maximumBytes, result.0.count > maximumBytes {
            throw HTTPClientError.responseTooLarge
        }
        return result
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let (status, data) = responses.removeFirst()
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (data, response)
    }
}

@MainActor
struct CommunityTransportTests {
    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "https://other.invalid/posters", "https://example.invalid/unrelated",
            "https://example.invalid/posters?page=999",
        ])
    func successfulResponsesKeepLocation(target: String) async throws {
        let response = try #require(
            HTTPURLResponse(
                url: AppURL.required(target), statusCode: 200, httpVersion: nil, headerFields: nil))
        let transport = StubTransport(result: .success((Data("[]".utf8), response)))
        let client = CommunityAPIClient<ModuleCommunityError>(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), errorDomain: "fixture",
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }
        )
        await #expect(throws: ModuleCommunityError.invalidResponse) {
            let _: [Int] = try await client.request(
                path: "posters", queryItems: [URLQueryItem(name: "page", value: "0")])
        }
    }
    @Test(.timeLimit(.minutes(1))) func authenticatedRetryUsesRefreshedCookie() async throws {
        let transport = SequenceTransport([(401, Data()), (200, Data("result".utf8))])
        var cookie = "original-cookie"
        var refreshedCookies: [String] = []
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                CommunityCredentials(
                    identity: CommunitySessionIdentity(accountIdentifier: "test-account"),
                    cookie: cookie)
            },
            refresh: { observed in
                refreshedCookies.append(observed.cookie)
                cookie = "refreshed-cookie"
            }
        )
        let client: CommunityAPIClient<ModuleCommunityError> = session.client(
            errorDomain: "ModuleTests")
        let data = try await client.requestData(path: "user/info/0")
        #expect(data == Data("result".utf8))
        #expect(refreshedCookies == ["original-cookie"])
        #expect(
            transport.requests.map { $0.value(forHTTPHeaderField: "fake-cookie") } == [
                "original-cookie", "refreshed-cookie",
            ])
    }

    @Test(.timeLimit(.minutes(1))) func secondUnauthorizedResponseEndsRetry() async throws {
        let transport = SequenceTransport([(401, Data()), (401, Data())])
        var refreshCount = 0
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                CommunityCredentials(
                    identity: CommunitySessionIdentity(accountIdentifier: "test-account"),
                    cookie: "cookie")
            },
            refresh: { _ in refreshCount += 1 }
        )
        let client: CommunityAPIClient<ModuleCommunityError> = session.client(
            errorDomain: "ModuleTests")
        await #expect(throws: ModuleCommunityError.signedOut) {
            try await client.requestData(path: "user/info/0")
        }
        #expect(refreshCount == 1)
        #expect(transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func signedOutSessionStopsBeforeTransport() async {
        let transport = SequenceTransport([])
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                CommunityCredentials(
                    identity: CommunitySessionIdentity(accountIdentifier: "test-account"),
                    cookie: "")
            },
            refresh: { _ in Issue.record("Unexpected session refresh") }
        )
        let client: CommunityAPIClient<ModuleCommunityError> = session.client(
            errorDomain: "ModuleTests")
        await #expect(throws: ModuleCommunityError.signedOut) {
            try await client.requestData(path: "user/info/0")
        }
        #expect(transport.requests.isEmpty)
    }
}

@MainActor
final class StubTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let result: Result<(Data, URLResponse), Error>

    init(result: Result<(Data, URLResponse), Error>) {
        self.result = result
    }

    func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
        let result = try await data(for: request)
        if let maximumBytes, result.0.count > maximumBytes {
            throw HTTPClientError.responseTooLarge
        }
        return result
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try result.get()
    }
}

nonisolated final class BoundedResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: url.path == "/declared" ? ["Content-Length": "16"] : [:])
        else {
            client?.urlProtocol(self, didFailWithError: HTTPClientError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let count = url.path == "/chunks" ? 64 * 1_024 + 8 : 8
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: count))
        client?.urlProtocol(self, didLoad: Data(repeating: 2, count: count))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class RecordingObserver: HTTPClientObserving {
    var events: [String] = []
    var failure: Error?
    var sentData: Data?
    var recordedError: Error?
    var recordedRequest: URLRequest?

    func willSend(_ request: URLRequest) async throws {
        events.append("willSend")
        if let failure { throw failure }
    }

    func didFinish(
        request: URLRequest,
        finalRequest: URLRequest?,
        data: Data?,
        response: URLResponse?,
        error: Error?,
        elapsed: TimeInterval
    ) async {
        events.append("didFinish")
        sentData = data
        recordedError = error
        recordedRequest = request
    }
}

@MainActor
struct ClientCoreTests {
    @Test(arguments: [
        "native", "stream", "changed-body", "changed-url", "changed-method",
        "redirect-body-removal", "missing",
    ])
    func nativeFinalRequestPreservesAcceptedBodies(stage: String) throws {
        let url = AppURL.required("https://example.invalid/submit")
        var sent = URLRequest(url: url)
        sent.httpMethod = "POST"
        sent.httpBody = Data("page=1".utf8)
        let metrics = HTTPTransmissionMetrics(request: sent, redirects: nil)
        var current = sent
        current.httpBody = nil
        if stage == "missing" {
            #expect(metrics.finalRequest(from: nil) == nil)
            return
        }
        if stage == "stream" {
            current.httpBodyStream = InputStream(data: try #require(sent.httpBody))
        }
        if stage == "changed-body" { current.httpBody = Data("page=2".utf8) }
        if stage == "changed-url" { current.url = AppURL.required("https://example.invalid/other") }
        if stage == "changed-method" { current.httpMethod = "GET" }
        if stage == "redirect-body-removal" {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let task = session.dataTask(with: sent)
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
            metrics.urlSession(
                session, task: task, willPerformHTTPRedirection: response, newRequest: current
            ) { _ in }
        }
        let captured = try #require(metrics.finalRequest(from: current))
        let expected =
            stage == "changed-body"
            ? current.httpBody
            : ["native", "stream"].contains(stage) ? sent.httpBody : nil
        #expect(captured.httpBody == expected)
        #expect(captured.url == current.url && captured.httpMethod == current.httpMethod)
    }

    @Test(.timeLimit(.minutes(1))) func finalRequestEvidenceSurvivesWrappers() async throws {
        let origin = AppURL.required("https://example.invalid/submit?obj=paper1&token=secret")
        let target = AppURL.required("https://other.invalid/final?obj=paper2&token=private")
        var request = URLRequest(url: origin)
        request.httpMethod = "POST"
        let response = try #require(
            HTTPURLResponse(url: target, statusCode: 200, httpVersion: nil, headerFields: nil))
        let base = FinalRequestTransport(
            base: StubTransport(result: .success((Data(), response))),
            finalRequest: URLRequest(url: target))
        let client = HTTPClient(transport: ForwardingTransport(base: base), observer: nil)
        var evidence: HTTPRequestEvidence?
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ request, response in
            evidence = HTTPRequestEvidence(
                request: request, response: response.response, finalRequest: response.finalRequest)
        }) { _ = try await client.send(request) }
        let captured = try #require(evidence)
        #expect(captured.method == "POST" && captured.finalMethod == "GET")
        #expect(
            captured.endpoint == "https://example.invalid/submit"
                && captured.finalEndpoint == "https://other.invalid/final")
        #expect(HTTPRequestEvidence(request: request, response: response).finalMethod == "")
    }

    struct FinalRequestTransport: HTTPTransport {
        let base: any HTTPTransport
        let finalRequest: URLRequest
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes {
                throw HTTPClientError.responseTooLarge
            }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            HTTPRequestEvidenceContext.didReceiveFinalRequest?(finalRequest)
            return try await base.data(for: request)
        }
    }

    @Test(.timeLimit(.minutes(1))) func admissionFailuresPreserveUnsentState() async throws {
        let transport = StubTransport(result: .failure(URLError(.timedOut)))
        let observer = RecordingObserver()
        observer.failure = URLError(.notConnectedToInternet)
        let client = HTTPClient(transport: transport, observer: observer)
        var started = false
        await #expect(throws: URLError.self) {
            try await HTTPRequestEvidenceContext.$willStart.withValue({ started = true }) {
                _ = try await client.send(URLRequest(url: url))
            }
        }
        #expect(!started && transport.requests.isEmpty)
        observer.failure = nil
        await #expect(throws: URLError.self) {
            try await HTTPRequestEvidenceContext.$willStart.withValue({ started = true }) {
                _ = try await client.send(URLRequest(url: url))
            }
        }
        #expect(started && transport.requests.count == 1)
    }
    let url = AppURL.required("https://example.invalid/module-test")

    struct ForwardingTransport: HTTPTransport {
        let base: any HTTPTransport
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await data(for: request, maximumBytes: nil)
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let response = try await HTTPClient(transport: base, observer: nil).send(
                request, accepting: 100..<600, maximumBytes: maximumBytes)
            return (response.data, response.response)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [200, 401], [0, 1, 2])
    func requestEvidenceFollowsRestoresScopeScope(status: Int, layers: Int) async throws {
        let endpoint = AppURL.required(
            "https://student:password@example.invalid/probe?token=secret#private")
        let response = try #require(
            HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil))
        var transport: any HTTPTransport = StubTransport(result: .success((Data(), response)))
        for _ in 0..<layers { transport = ForwardingTransport(base: transport) }
        let client = HTTPClient(transport: transport, observer: nil)
        var evidence: [HTTPRequestEvidence] = []
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ request, response in
            evidence.append(
                HTTPRequestEvidence(
                    request: request, response: response.response,
                    finalRequest: response.finalRequest))
        }) {
            let child = Task { try await client.send(request) }
            if status == 200 {
                let value = try await child.value
                #expect(value.statusCode == status)
            } else {
                await #expect(throws: HTTPClientError.self) { try await child.value }
            }
        }
        let recorded = try #require(evidence.first)
        #expect(evidence.count == 1)
        #expect(recorded.endpoint == "https://example.invalid/probe")
        #expect(
            recorded.endpointDigest
                == "47bf43ee094b876be76639e73537bd54006ded21813ba5265ff3950a96f68d95")
        #expect(recorded.method == "POST" && recorded.statusCode == status)
        #expect(HTTPRequestEvidenceContext.didReceive == nil)
        let decoded = try JSONDecoder().decode(
            HTTPRequestEvidence.self, from: JSONEncoder().encode(recorded))
        #expect(decoded.endpoint == recorded.endpoint && decoded.statusCode == status)
        #expect(decoded.endpointDigest == recorded.endpointDigest)
        request.url = nil
        request.httpMethod = nil
        #expect(HTTPRequestEvidence(request: request, response: response).method == "GET")
        #expect(
            HTTPRequestEvidence(request: request, response: response).endpoint == recorded.endpoint)
    }

    @Test(.timeLimit(.minutes(1))) func ordinaryResponsesUseDefaultBudgetNil() async throws {
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let base = StubTransport(
            result: .success(
                (Data(count: HTTPResponseResourceLimits.maximumStructuredBytes + 1), response)))
        let client = HTTPClient(transport: base, observer: nil)
        await #expect(throws: HTTPClientError.self) { try await client.send(URLRequest(url: url)) }
        await #expect(throws: HTTPClientError.self) {
            try await client.send(URLRequest(url: url), maximumBytes: nil)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [15, 16])
    func customTransport(maximumBytes: Int) async throws {
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let base = StubTransport(result: .success((Data(count: 16), response)))
        let observer = RecordingObserver()
        let client = HTTPClient(transport: UncachedHTTPTransport(base: base), observer: observer)
        if maximumBytes == 16 {
            let result = try await client.send(URLRequest(url: url), maximumBytes: maximumBytes)
            #expect(result.data.count == 16)
        } else {
            await #expect(throws: HTTPClientError.self) {
                try await client.send(URLRequest(url: url), maximumBytes: maximumBytes)
            }
            #expect(observer.sentData == nil && observer.recordedError is HTTPClientError)
        }
        #expect(
            base.requests.count == 1
                && base.requests.first?.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(observer.events == ["willSend", "didFinish"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["declared", "streamed", "chunks"])
    func productionSessionBoundsDeclared(path: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedResponseProtocol.self]
        let session = URLSessionTransport.make(configuration: configuration)
        let client = HTTPClient(transport: UncachedHTTPTransport(base: session), observer: nil)
        let request = URLRequest(url: AppURL.required("https://example.invalid/\(path)"))
        let count = path == "chunks" ? 64 * 1_024 + 8 : 8
        let result = try await client.send(request, maximumBytes: count * 2)
        #expect(result.data == Data(repeating: 1, count: count) + Data(repeating: 2, count: count))
        await #expect(throws: HTTPClientError.self) {
            try await client.send(request, maximumBytes: count * 2 - 1)
        }
    }

    @Test(.timeLimit(.minutes(1))) func remoteReadPolicyPreservesFailures() async throws {
        let base = StubTransport(result: .failure(URLError(.networkConnectionLost)))
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataDontLoad)
        do {
            _ = try await UncachedHTTPTransport(base: base).data(for: request)
            Issue.record("Expected the remote transport failure")
        } catch let error as URLError {
            #expect(error.code == .networkConnectionLost)
        }
        #expect(base.requests.count == 1)
        #expect(base.requests.first?.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.cachePolicy == .returnCacheDataDontLoad)
    }

    struct CancellingResponseTransport: HTTPTransport {
        let response: HTTPURLResponse

        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes {
                throw HTTPClientError.responseTooLarge
            }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            withUnsafeCurrentTask { $0?.cancel() }
            return (Data(#"{"message":"maintenance"}"#.utf8), response)
        }
    }

    @Test(.timeLimit(.minutes(1))) func schoolAuthContractsDecode() async throws {
        let data = Data(
            #"""
            {"challenge_id":"school-challenge","access_token":"token","status":"waiting_sms","\#
            masked_phone":"138****0000","expires_in":120}
            """#
            .utf8)
        let payload = try BITLoginChallengeSupport.decodePayload(from: data)
        let polled = try await BITLoginChallengeSupport.pollUntilActionable(
            payload, timeout: 1, interval: .milliseconds(1)
        ) { _ in
            Issue.record("Actionable challenge should finish immediately")
            return payload
        }
        let challenge = BITLoginChallengeSupport.challenge(from: polled, accessToken: "token")
        #expect(challenge.challengeID == "school-challenge")
        #expect(challenge.status == "waiting_sms")
        #expect(challenge.maskedPhone == "138****0000")
        #expect(challenge.expiresIn == 120)
        #expect(
            BITLoginChallengeSupport.errorMessage(
                from: Data(#"{"detail":{"error":"school-service"}}"#.utf8)) == "school-service")
    }

    @Test(.timeLimit(.minutes(1))) func transportReportsSuccessfulResponse() async throws {
        let data = Data("response".utf8)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let transport = StubTransport(result: .success((data, response)))
        let observer = RecordingObserver()
        let result = try await HTTPClient(transport: transport, observer: observer).send(
            URLRequest(url: url))

        #expect(result.data == data)
        #expect(result.statusCode == 200)
        #expect(transport.requests.count == 1)
        #expect(observer.events == ["willSend", "didFinish"])
        #expect(observer.sentData == data)
        #expect(observer.recordedError == nil)
    }

    @Test(.timeLimit(.minutes(1))) func observerControlsRequestAdmission() async {
        let transport = StubTransport(result: .failure(URLError(.timedOut)))
        let observer = RecordingObserver()
        observer.failure = URLError(.notConnectedToInternet)
        do {
            _ = try await HTTPClient(transport: transport, observer: observer).send(
                URLRequest(url: url))
            Issue.record("Admission policy should throw its configured error")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(transport.requests.isEmpty)
        #expect(observer.events == ["willSend"])
    }

    @Test(.timeLimit(.minutes(1))) func transportReportsFailures() async {
        let transport = StubTransport(result: .failure(URLError(.timedOut)))
        let observer = RecordingObserver()
        do {
            _ = try await HTTPClient(transport: transport, observer: observer).send(
                URLRequest(url: url))
            Issue.record("The configured transport error should propagate")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(observer.events == ["willSend", "didFinish"])
        #expect((observer.recordedError as? URLError)?.code == .timedOut)
    }

}

extension ScheduleInfrastructureTests {

    final class MutableSchoolCredentials: SchoolCredentialsProviding {
        var currentStudentID = "school-a"
        let currentPassword = "fixture-password"
        var generation = 0
        var schoolSessionIdentity: SchoolSessionIdentity {
            .init(accountIdentifier: currentStudentID, generation: generation)
        }
    }
    final class SuspendedSchoolCookies: HTTPTransport {
        var pending: CheckedContinuation<Void, Never>?
        var requests = 0
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes {
                throw HTTPClientError.responseTooLarge
            }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests += 1
            await withCheckedContinuation { pending = $0 }
            let url = try #require(request.url)
            return (
                Data(#"{"data":{"wengine_vpn_ticket":"account-a-ticket"}}"#.utf8),
                try #require(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
    }

    final class RequestObserverFactory: HTTPClientObserving {
        var generation = 0
        var completions: [Int] = []
        func forRequest() -> any HTTPClientObserving {
            RequestObserver(factory: self, generation: generation)
        }
        func willSend(_ request: URLRequest) async throws {}
        func didFinish(
            request: URLRequest, finalRequest: URLRequest?, data: Data?, response: URLResponse?,
            error: Error?, elapsed: TimeInterval
        ) async {
            completions.append(-1)
        }
        private struct RequestObserver: HTTPClientObserving {
            let factory: RequestObserverFactory
            let generation: Int
            func willSend(_ request: URLRequest) async throws {}
            func didFinish(
                request: URLRequest, finalRequest: URLRequest?, data: Data?, response: URLResponse?,
                error: Error?, elapsed: TimeInterval
            ) async {
                factory.completions.append(generation)
            }
        }
    }

    struct AuthenticatedRestorer: SchoolSessionRestoring {
        func restoreSchoolSession() async throws -> String? { "school-session" }
    }

    final class SuspendedSecondFactor: HTTPTransport {
        static let html =
            #"""
            <form action="/cas/login"><input id="login-page-flowkey" value="flow"><input id="u\#
            ser-object-id" value="user"><div id="secondSmsLoginForm"></div></form>
            """#
        let suspendedStage: String
        var pending: CheckedContinuation<Void, Never>?
        var requests: [URLRequest] = []
        init(_ stage: String) { suspendedStage = stage }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes {
                throw HTTPClientError.responseTooLarge
            }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let url = try #require(request.url)
            let stage =
                url.path.contains("getPhoneNumber")
                ? "phone"
                : url.path.contains("sendSmsCode")
                    ? "send"
                    : url.path.contains("checkToken")
                        ? "verify" : request.httpMethod == "POST" ? "login" : "html"
            if stage == suspendedStage { await withCheckedContinuation { pending = $0 } }
            let text =
                stage == "phone"
                ? #"{"code":200,"data":{"phone":"13800000000","maskTel":"138****0000"}}"#
                : stage == "html" ? Self.html : #"{"code":200}"#
            return (
                Data(text.utf8),
                try #require(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
    }

}
