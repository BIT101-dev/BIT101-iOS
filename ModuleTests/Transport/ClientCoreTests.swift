import BIT101TestSupport
import SchedulePorts
@testable import TransportCore
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
    @Test func classroomOccupancyParsingPreservesEverySectionOrRejectsTheResponse() async throws {
        for (value, expected) in [("1, 2", [1, 2]), ("", []), ("  ", [])] {
            let data = try JSONSerialization.data(withJSONObject: ["datas": ["cxkxjasqk": ["rows": [["JASMC": "A101", "ZYJC": value]]]]])
            let response = try JSONDecoder().decode(ClassroomListResponse.self, from: data)
            #expect(try await response.classroomRecords().first?.busyTimeCodes == expected)
        }
        for value in ["bad", "1,bad", "1,,2", "0", "-1", String(Int.max)] {
            let data = try JSONSerialization.data(withJSONObject: ["datas": ["cxkxjasqk": ["rows": [["JASMC": "A101", "ZYJC": value]]]]])
            let response = try JSONDecoder().decode(ClassroomListResponse.self, from: data)
            await #expect(throws: ScheduleServiceError.self) { try await response.classroomRecords() }
        }
    }

    @Test func redirectAuthenticationHeadersStayBoundToTheirOrigin() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = AppURL.required("https://auth.example/login")
        let response = try #require(HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil))
        let task = session.dataTask(with: origin)
        let delegate = HTTPSUpgradingRedirectDelegate()
        for sameOrigin in [true, false] {
            var request = URLRequest(url: AppURL.required(sameOrigin ? "https://auth.example/next" : "https://other.example/next"))
            for header in ["Authorization", "Proxy-Authorization", "Cookie", "fake-cookie", "x-challenge-token"] {
                request.setValue("fixture-token", forHTTPHeaderField: header)
            }
            var result: URLRequest?
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: request, completionHandler: { result = $0 })
            let redirected = try #require(result)
            for header in ["Authorization", "Proxy-Authorization", "Cookie", "fake-cookie", "X-Challenge-Token"] {
                #expect(redirected.value(forHTTPHeaderField: header) == (sameOrigin ? "fixture-token" : nil))
            }
        }
    }

    private struct Credentials: SchoolCredentialsProviding {
        var schoolSessionIdentity: SchoolSessionIdentity { .init(accountIdentifier: currentStudentID, generation: 0) }
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

    private func service(transport: any HTTPTransport, observer: (any HTTPClientObserving & Sendable)? = nil,
        state: TeachingCenterSessionState? = nil, restorer: any SchoolSessionRestoring = Restorer()) -> ScheduleService {
        ScheduleService(
            credentials: Credentials(), crypto: Crypto(), schoolSessionRestorer: restorer,
            teachingCenterState: state ?? TeachingCenterSessionState(cookieStorage: .sharedCookieStorage(forGroupContainerIdentifier: "BIT101ModulesTests.infrastructure")),
            transport: transport, observer: observer
        )
    }

    @Test func schoolFixtureParsingRunsInThePackageHost() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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

    @Test(arguments: [(#"{"KCM":"待排课程"}"#, true),
        (#"{"KCM":"已排课程","SKXQ":1,"KSJC":1,"JSJC":2,"ZCMC":"1-2周"}"#, true),
        (#"{"KCM":"课程","SKXQ":8,"KSJC":1,"JSJC":2,"ZCMC":"1周"}"#, false),
        (#"{"KCM":"课程","SKXQ":1,"KSJC":2,"JSJC":1,"ZCMC":"1周"}"#, false),
        (#"{"KCM":"课程","SKXQ":1,"ZCMC":"1周"}"#, false),
        (#"{"KCM":"课程","SKXQ":1,"KSJC":1,"JSJC":2}"#, false),
        (#"{"KCM":"课程","ZCMC":"1周"}"#, false)])
    func schoolCoursePlacementContractPreservesPendingRowsAndRejectsIncompleteSchedules(fixture: (String, Bool)) async throws {
        let (row, valid) = fixture
        let data = Data((#"{"datas":{"cxxszhxqkb":{"rows":["# + row + #"]}}}"#).utf8)
        let transport = SequenceTransport([(200, data)])
        if valid { #expect(try await service(transport: transport).fetchParsedCourses(term: "2026-2027-1").count == 1) }
        else { await #expect(throws: ScheduleServiceError.self) { try await service(transport: transport).fetchParsedCourses(term: "2026-2027-1") } }
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

    @Test func schoolTransportRecordsResponsesAndOriginalNetworkFailures() async throws {
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
private final class SequenceTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, Data)]

    init(_ responses: [(Int, Data)]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let (status, data) = responses.removeFirst()
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (data, response)
    }
}

@MainActor
struct CommunityTransportTests {
    @Test(arguments: ["https://other.invalid/posters", "https://example.invalid/unrelated", "https://example.invalid/posters?page=999"])
    func successfulResponsesKeepTheirBusinessRequestLocation(target: String) async throws {
        let response = try #require(HTTPURLResponse(url: AppURL.required(target), statusCode: 200, httpVersion: nil, headerFields: nil))
        let transport = StubTransport(result: .success((Data("[]".utf8), response)))
        let client = CommunityAPIClient<ModuleCommunityError>(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), errorDomain: "fixture",
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") })
        await #expect(throws: ModuleCommunityError.invalidResponse) {
            let _: [Int] = try await client.request(path: "posters", queryItems: [URLQueryItem(name: "page", value: "0")])
        }
    }
    @Test func authenticatedRetryUsesRefreshedCookie() async throws {
        let transport = SequenceTransport([(401, Data()), (200, Data("result".utf8))])
        var cookie = "original-cookie"
        var refreshedCookies: [String] = []
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { CommunityCredentials(identity: CommunitySessionIdentity(accountIdentifier: "test-account"), cookie: cookie) },
            refresh: { observed in
                refreshedCookies.append(observed.cookie)
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
            credentials: { CommunityCredentials(identity: CommunitySessionIdentity(accountIdentifier: "test-account"), cookie: "cookie") },
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
            credentials: { CommunityCredentials(identity: CommunitySessionIdentity(accountIdentifier: "test-account"), cookie: "") },
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

private nonisolated final class BoundedResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: url.path == "/declared" ? ["Content-Length": "16"] : [:]) else {
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
private final class RecordingObserver: HTTPClientObserving {
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
    @Test(arguments: ["form", "json", "query"])
    func finalPostParametersComeFromTheFinalRequest(format: String) async throws {
        let url = AppURL.required("https://example.invalid/submit" + (format == "query" ? "?obj=paper1" : ""))
        var request = URLRequest(url: url); request.httpMethod = "POST"
        var finalRequest = request
        let contentType = format == "form" ? "application/x-www-form-urlencoded" : "application/json"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        finalRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((format == "form" ? "XNXQDM=initial&password=secret" : #"{"obj":"paper1","password":"secret"}"#).utf8)
        finalRequest.httpBody = Data((format == "form" ? "XNXQDM=final&password=private" : #"{"obj":"paper2","password":"private"}"#).utf8)
        if format == "query" {
            request.httpBody = nil; finalRequest.httpBody = nil
            finalRequest.url = AppURL.required("https://example.invalid/submit?obj=paper2")
        }
        let finalURL = try #require(finalRequest.url)
        let response = try #require(HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: nil))
        let transport = FinalRequestTransport(base: StubTransport(result: .success((Data(), response))), finalRequest: finalRequest)
        var captured: HTTPRequestEvidence?
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ captured = $0 }) {
            _ = try await HTTPClient(transport: ForwardingTransport(base: transport), observer: nil).send(request)
        }
        let evidence = try #require(captured)
        #expect(evidence.finalMethod == "POST")
        let key = format == "form" ? "XNXQDM" : "obj"
        #expect(evidence.query[key] == (format == "form" ? "initial" : "paper1"))
        #expect(evidence.finalQuery[key] == (format == "form" ? "final" : "paper2"))
        let encoded = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        #expect(!encoded.contains("secret") && !encoded.contains("private"))
    }
    @Test func finalRequestEvidenceSurvivesTransportWrappers() async throws {
        let origin = AppURL.required("https://example.invalid/submit?obj=paper1&token=secret")
        let target = AppURL.required("https://other.invalid/final?obj=paper2&token=private")
        var request = URLRequest(url: origin); request.httpMethod = "POST"
        let response = try #require(HTTPURLResponse(url: target, statusCode: 200, httpVersion: nil, headerFields: nil))
        let base = FinalRequestTransport(base: StubTransport(result: .success((Data(), response))), finalRequest: URLRequest(url: target))
        let client = HTTPClient(transport: ForwardingTransport(base: base), observer: nil)
        var evidence: HTTPRequestEvidence?
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ evidence = $0 }) { _ = try await client.send(request) }
        let captured = try #require(evidence)
        #expect(captured.method == "POST" && captured.finalMethod == "GET")
        #expect(captured.endpoint == "https://example.invalid/submit" && captured.finalEndpoint == "https://other.invalid/final")
        #expect(captured.query["obj"] == "paper1" && captured.finalQuery == ["obj": "paper2"])
        #expect(HTTPRequestEvidence(request: request, response: response).finalMethod == "")
    }

    private struct FinalRequestTransport: HTTPTransport {
        let base: any HTTPTransport
        let finalRequest: URLRequest
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            HTTPRequestEvidenceContext.didReceiveFinalRequest?(finalRequest)
            return try await base.data(for: request)
        }
    }

    @Test func admissionFailuresPreserveUnsentRequestState() async throws {
        let transport = StubTransport(result: .failure(URLError(.timedOut)))
        let observer = RecordingObserver(); observer.failure = URLError(.notConnectedToInternet)
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
    private let url = AppURL.required("https://example.invalid/module-test")

    private struct ForwardingTransport: HTTPTransport {
        let base: any HTTPTransport
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await data(for: request, maximumBytes: nil)
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let response = try await HTTPClient(transport: base, observer: nil).send(request, accepting: 100 ..< 600, maximumBytes: maximumBytes)
            return (response.data, response.response)
        }
    }

    @Test(arguments: [200, 401], [0, 1, 2])
    func requestEvidenceFollowsChildTasksAndRestoresItsScope(status: Int, layers: Int) async throws {
        let endpoint = AppURL.required("https://student:password@example.invalid/probe?token=secret#private")
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil))
        var transport: any HTTPTransport = StubTransport(result: .success((Data(), response)))
        for _ in 0 ..< layers { transport = ForwardingTransport(base: transport) }
        let client = HTTPClient(transport: transport, observer: nil)
        var evidence: [HTTPRequestEvidence] = []
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ evidence.append($0) }) {
            let child = Task { try await client.send(request) }
            if status == 200 {
                let value = try await child.value
                #expect(value.statusCode == status)
            }
            else { await #expect(throws: HTTPClientError.self) { try await child.value } }
        }
        let recorded = try #require(evidence.first)
        #expect(evidence.count == 1)
        #expect(recorded.endpoint == "https://example.invalid/probe")
        #expect(recorded.endpointDigest == "47bf43ee094b876be76639e73537bd54006ded21813ba5265ff3950a96f68d95")
        #expect(recorded.method == "POST" && recorded.statusCode == status)
        #expect(HTTPRequestEvidenceContext.didReceive == nil)
        let decoded = try JSONDecoder().decode(HTTPRequestEvidence.self, from: JSONEncoder().encode(recorded))
        #expect(decoded.endpoint == recorded.endpoint && decoded.statusCode == status)
        #expect(decoded.endpointDigest == recorded.endpointDigest)
        request.url = nil
        request.httpMethod = nil
        #expect(HTTPRequestEvidence(request: request, response: response).method == "GET")
        #expect(HTTPRequestEvidence(request: request, response: response).endpoint == recorded.endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"detail":true,"password":"secret"}"#.utf8)
        #expect(HTTPRequestEvidence(request: request, response: response).query == ["detail": "true"])
    }

    @Test(arguments: [("[]", String?.some("0")), (#"[{"id":3,"text":"secret"},{"id":9,"text":"private"}]"#, .some("3")),
        ("{}", nil), ("invalid", nil)], ["poster1", "comment2", "private"])
    func requestEvidenceRecordsObjectsAndResponseCursorsWithRedactedContent(fixture: (String, String?), object: String) async throws {
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let client = HTTPClient(transport: StubTransport(result: .success((Data(fixture.0.utf8), response))), observer: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["obj": object, "text": "secret", "password": "private"])
        var captured: HTTPRequestEvidence?
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ captured = $0 }) { _ = try await client.send(request) }
        let evidence = try #require(captured)
        #expect(evidence.responseMinimumID == fixture.1)
        #expect(evidence.query == (object == "private" ? [:] : ["obj": object]))
        let encoded = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        #expect(!encoded.contains("secret") && !encoded.contains("private"))
    }

    @Test(arguments: ["0", "99"], ["query", "form", "redirect"])
    func requestEvidencePreservesParameterAmbiguity(value: String, location: String) throws {
        let url = AppURL.required("https://example.invalid/probe?page=0&token=secret")
        var request = URLRequest(url: url)
        if location == "query" { request.url = AppURL.required(url.absoluteString + "&page=\(value)&token=secret") }
        if location == "form" {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("XNXQDM=0&XNXQDM=\(value)&password=secret".utf8)
        }
        var finalRequest = request
        if location == "redirect" { finalRequest.url = AppURL.required(url.absoluteString + "&page=\(value)") }
        let finalURL = try #require(finalRequest.url)
        let response = try #require(HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: nil))
        let evidence = HTTPRequestEvidence(request: request, response: response, finalRequest: finalRequest)
        let key = location == "form" ? "XNXQDM" : "page"
        #expect(evidence.ambiguousParameters == (location == "redirect" ? nil : [key]))
        #expect(evidence.finalAmbiguousParameters == [key] && evidence.finalQuery[key] == nil)
        let encoded = try JSONEncoder().encode(evidence)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("secret"))
        #expect(try JSONDecoder().decode(HTTPRequestEvidence.self, from: encoded).finalAmbiguousParameters == [key])
    }

    @Test func requestEvidencePreservesBusinessSelectorsAndRedactsFormCredentials() throws {
        let url = AppURL.required("https://example.invalid/probe?search=BIT101&hide_bot=true&XXXQDM=campus&token=secret")
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("XNXQDM=2025-2026-1&JXLDM=B%2B%26+Room&password=secret".utf8)
        let evidence = HTTPRequestEvidence(request: request, response: response)
        #expect(evidence.query == ["search": "BIT101", "hide_bot": "true", "XXXQDM": "campus", "XNXQDM": "2025-2026-1", "JXLDM": "B+& Room"])
        request.httpBody = Data("requestParamStr=%7B%22XNXQDM%22%3A%222025-2026-1%22%2C%22ZC%22%3A%221%22%7D&password=secret".utf8)
        #expect(HTTPRequestEvidence(request: request, response: response).query == ["search": "BIT101", "hide_bot": "true", "XXXQDM": "campus", "XNXQDM": "2025-2026-1"])
        #expect(!String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("secret"))
    }

    @Test(arguments: [(#"{"courses":[]}"#, [String]?.some([])), (#"{"courses":[{"id":41,"name":"secret"},{"id":43}]}"#, .some(["41", "43"])),
        (#"{"courses":[{"id":true}]}"#, nil), (#"{"courses":[{"id":0}]}"#, nil), ("{}", nil)])
    func requestEvidenceBindsEclassCourseResponsesWithoutTheirContent(fixture: (String, [String]?)) async throws {
        let url = AppURL.required("https://zy-eclass.bit.edu.cn/api/my-courses")
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let evidence = await HTTPRequestEvidence.capture(request: URLRequest(url: url), response: response, body: Data(fixture.0.utf8))
        #expect(evidence.responseCourseIDs == fixture.1)
        #expect(!String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("secret"))
    }

    @Test func ordinaryResponsesUseTheDefaultBudgetIncludingExplicitNil() async throws {
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let base = StubTransport(result: .success((Data(count: HTTPResponseResourceLimits.maximumStructuredBytes + 1), response)))
        let client = HTTPClient(transport: base, observer: nil)
        await #expect(throws: HTTPClientError.self) { try await client.send(URLRequest(url: url)) }
        await #expect(throws: HTTPClientError.self) { try await client.send(URLRequest(url: url), maximumBytes: nil) }
    }

    @Test(arguments: [15, 16])
    func customTransportAndRemoteReadWrapperEnforceResponseBudgets(maximumBytes: Int) async throws {
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
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
        #expect(base.requests.count == 1 && base.requests.first?.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(observer.events == ["willSend", "didFinish"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["declared", "streamed", "chunks"])
    func productionSessionBoundsDeclaredAndStreamedBodies(path: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedResponseProtocol.self]
        let session = try #require(URLSessionTransport.make(configuration: configuration) as? URLSession)
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(transport: UncachedHTTPTransport(base: session), observer: nil)
        let request = URLRequest(url: AppURL.required("https://example.invalid/\(path)"))
        let count = path == "chunks" ? 64 * 1_024 + 8 : 8
        let result = try await client.send(request, maximumBytes: count * 2)
        #expect(result.data == Data(repeating: 1, count: count) + Data(repeating: 2, count: count))
        await #expect(throws: HTTPClientError.self) { try await client.send(request, maximumBytes: count * 2 - 1) }
    }

    @Test func remoteReadPolicyPreservesFailuresAndLeavesTheCallerRequestIntact() async throws {
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

    private struct CancellingResponseTransport: HTTPTransport {
        let response: HTTPURLResponse

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            withUnsafeCurrentTask { $0?.cancel() }
            return (Data(#"{"message":"maintenance"}"#.utf8), response)
        }
    }

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

    @Test func alreadyCancelledRequestsSkipAdmissionAndTransport() async {
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

    @Test(arguments: [200, 503]) func cancellationAfterResponsePreservesCancellation(status: Int) async throws {
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        let observer = RecordingObserver()
        let client = HTTPClient(transport: CancellingResponseTransport(response: response), observer: observer)
        let operation = Task { @MainActor in
            try await client.send(URLRequest(url: url))
        }

        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(observer.events == ["willSend", "didFinish"])
        #expect(observer.recordedError is CancellationError)
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

    @Test func HTTPErrorMessagesHaveAReadableBoundAndStructuredFallback() throws {
        let large = String(repeating: "错误", count: 1_000)
        let json = try JSONSerialization.data(withJSONObject: ["message": large])
        let message = try #require(HTTPClient.errorMessage(from: json))
        #expect(message.count == HTTPResponseResourceLimits.maximumErrorCharacters && message.hasSuffix("…"))
        #expect(HTTPClient.errorMessage(from: Data("<html>gateway details</html>".utf8)) == nil)
        #expect(HTTPClient.errorMessage(from: Data(#"{"unrelated":"private body"}"#.utf8)) == nil)
        #expect(HTTPClient.errorMessage(from: Data(repeating: 65, count: HTTPResponseResourceLimits.maximumErrorBytes + 1)) == nil)
        #expect(HTTPClient.errorMessage(from: Data("  plain response  ".utf8)) == "plain response")
        for data in [Data("<html>school login gateway</html>".utf8),
                     Data(#"{"detail":{"error":"<html>gateway</html>"}}"#.utf8),
                     Data(repeating: 65, count: HTTPResponseResourceLimits.maximumErrorBytes + 1)] {
            #expect(BITLoginChallengeSupport.errorMessage(from: data) == nil)
        }
        #expect(BITLoginChallengeSupport.errorMessage(from: json) == message)
        #expect(BITLoginChallengeSupport.errorMessage(from: Data(#""school-service""#.utf8)) == "school-service")
        #expect(HTTPClient.errorMessage(from: Data(#"{"detail":{"error":"school-service"}}"#.utf8)) == "school-service")
    }

    @Test func cancellationAndSecureRedirectRules() {
        #expect(TaskCancellation.matches(URLError(.cancelled)))
        #expect(TaskCancellation.matches(CancellationError()))
        #expect(HTTPSURLUpgrade.upgradedURL(from: AppURL.required("http://example.invalid/path")).scheme == "https")
        #expect(HTTPSURLUpgrade.resolvedURL(from: "/next", relativeTo: url)?.path == "/next")
    }

    @Test func formEncodingPreservesFieldBoundariesUnicodeAndRepeatedNames() {
        let body = HTTPFormEncoding.body([("name", "a+b &c?="), ("name", "中文"), ("empty", "")])
        #expect(String(decoding: body, as: UTF8.self) == "name=a%2Bb%20%26c%3F%3D&name=%E4%B8%AD%E6%96%87&empty=")
        #expect(HTTPFormEncoding.body([]).isEmpty)
    }

    @Test func wrappedNetworkErrorsKeepTheirClassificationAcrossDeepChains() {
        #expect(TaskCancellation.matches(HTTPRequestNotSent(underlying: URLError(.cancelled))))
        #expect(isHostResolutionError(HTTPRequestNotSent(underlying: URLError(.cannotFindHost))))
        #expect(!TaskCancellation.matches(HTTPRequestNotSent(underlying: URLError(.timedOut))))
        func wrapped(_ error: Error) -> Error {
            (0 ..< 20).reduce(error) { underlying, _ in
                NSError(domain: "transport-wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: underlying])
            }
        }
        #expect(TaskCancellation.matches(wrapped(CancellationError())))
        #expect(isHostResolutionError(wrapped(URLError(.cannotFindHost))))
        #expect(isCertificateValidationError(wrapped(URLError(.serverCertificateUntrusted))))
        #expect(isScheduleTransientNetworkError(wrapped(URLError(.timedOut))))
        #expect(isSchoolTransportFailure(wrapped(ScheduleServiceError.schoolTransportFailure)))
        #expect(!TaskCancellation.matches(wrapped(URLError(.timedOut))))
        #expect(!isHostResolutionError(wrapped(URLError(.notConnectedToInternet))))
    }

    @Test func networkRecoveryTracksTheSelectedPathInstance() {
        let selected = NetworkPathState(snapshot: NetworkPathSnapshot(status: .checking))
        let independent = NetworkPathState(snapshot: NetworkPathSnapshot(status: .disconnected))
        #expect(selected.isReachable)
        selected.update(snapshot: NetworkPathSnapshot(status: .disconnected))
        #expect(!selected.isReachable)
        selected.update(snapshot: NetworkPathSnapshot(status: .connected, interfaces: [.wifi, .other], virtualNetworkLikely: true))
        #expect(selected.isReachable)
        #expect(selected.snapshot.interfaces == [.wifi, .other])
        #expect(selected.snapshot.virtualNetworkLikely)
        #expect(!independent.isReachable)
        #expect(independent.snapshot.interfaces.isEmpty)
    }
}

extension ScheduleInfrastructureTests {
    @Test(arguments: ["{}", "null", "<html>gateway response</html>", #"{"datas":{"dqxnxq":{"rows":[{"DM":42}]}}}"#])
    func malformedSchoolResponsesKeepTheirResponseClassification(_ wire: String) async {
        let selected = service(transport: SequenceTransport([(200, Data(wire.utf8))]))
        do {
            let _: CurrentTermResponse = try await selected.sendJSONRequest(baseURL: AppURL.required("https://example.invalid"), path: "/term")
            Issue.record("A malformed school payload must expose a response error")
        } catch let error as ScheduleServiceError {
            if case .invalidResponse = error {} else { Issue.record("Unexpected school response classification: \(error)") }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [401, 403])
    func schoolAuthenticationStatusRetainsItsSessionRecoverySignal(_ status: Int) async {
        let selected = service(transport: SequenceTransport([(status, Data(#"{"message":"expired"}"#.utf8))]))
        do {
            let _: CurrentTermResponse = try await selected.sendJSONRequest(baseURL: AppURL.required("https://example.invalid"), path: "/term")
            Issue.record("An expired school session must expose its recovery signal")
        } catch let error as ScheduleServiceError {
            if case .teachingCenterSessionExpired = error {} else { Issue.record("Unexpected recovery signal: \(error)") }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [
        #"{"data":{"success":false,"msg":"学期查询失败"}}"#,
        #"{"data":{"success":false}}"#,
        #"{"success":false,"msg":""}"#,
        #"{"datas":{"cxxszhxqkb":{"rows":[],"extParams":{"code":3,"msg":""}}}}"#,
        #"{"datas":{"cxxszhxqkb":{"rows":[],"extParams":{"code":3}}}}"#
    ])
    func schoolBusinessFailureRetainsTheServiceMessage(json: String) async {
        let selected = service(transport: SequenceTransport([(200, Data(json.utf8))]))
        do {
            let _: CurrentTermResponse = try await selected.sendJSONRequest(baseURL: AppURL.required("https://example.invalid"), path: "/term")
            Issue.record("A school business failure must reach its consumer")
        } catch let error as ScheduleServiceError {
            if case .schoolResponse(let message) = error {
                #expect(message == (json.contains("学期查询失败") ? "学期查询失败" : "学校接口返回失败状态。"))
            }
            else { Issue.record("Unexpected business classification: \(error)") }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func schoolHTTPFailureKeepsTheStatusForDiagnosis() async {
        let selected = service(transport: SequenceTransport([(503, Data(#"{"message":"maintenance"}"#.utf8))]))
        do {
            let _: CurrentTermResponse = try await selected.sendJSONRequest(baseURL: AppURL.required("https://example.invalid"), path: "/term")
            Issue.record("A maintenance response must expose its HTTP status")
        } catch {
            #expect((error as NSError).code == 503)
        }
    }

    @Test func schoolTermsDecodeThroughTheProductionTransportBoundary() async throws {
        let transport = SequenceTransport([(200, Data(#"{"datas":{"xnxqcx":{"rows":[{"DM":"2026-2027-1"},{"DM":"2025-2026-2"}]}}}"#.utf8))])
        let result: TermsResponse = try await service(transport: transport).sendJSONRequest(
            baseURL: AppURL.required("http://example.invalid"), path: "/terms", method: "POST", body: [("学期", "A+B & C")])
        #expect(result.datas.xnxqcx.rows.map(\.code) == ["2026-2027-1", "2025-2026-2"])
        #expect(transport.requests.first?.url?.scheme == "https")
        #expect(String(decoding: try #require(transport.requests.first?.httpBody), as: UTF8.self) == "%E5%AD%A6%E6%9C%9F=A%2BB%20%26%20C")
    }

    @Test func availableTermsAuthenticateAndPrepareTheSelectedCookieContainerOnce() async throws {
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let state = TeachingCenterSessionState(cookieStorage: cookies)
        let terms = Data(#"{"datas":{"xnxqcx":{"rows":[{"DM":"2026-2027-1"},{"DM":"2025-2026-2"},{"DM":"2026-2027-1"},{"DM":""}]}}}"#.utf8)
        let transport = SequenceTransport([(200, Data(#"{"data":{"wengine_vpn_ticket":"ticket"}}"#.utf8)),
            (200, Data("{}".utf8)), (200, Data("{}".utf8)), (200, terms), (200, terms)])
        let service = service(transport: transport, state: state)
        #expect(try await service.fetchAvailableTerms() == ["2026-2027-1", "2025-2026-2"])
        #expect(try await service.fetchAvailableTerms() == ["2026-2027-1", "2025-2026-2"])
        #expect(transport.requests.count == 5)
        #expect(state.isPrepared(for: "module-school"))
        #expect(cookies.cookies?.contains { $0.name == "wengine_vpn_ticket" && $0.isSecure } == true)
        let data = try #require(transport.requests.first?.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body == ["username": "module-school", "password": "module-password"])
    }

    private final class MutableSchoolCredentials: SchoolCredentialsProviding {
        var currentStudentID = "school-a"
        let currentPassword = "fixture-password"
        var generation = 0
        var schoolSessionIdentity: SchoolSessionIdentity { .init(accountIdentifier: currentStudentID, generation: generation) }
    }
    private final class SuspendedSchoolCookies: HTTPTransport {
        var pending: CheckedContinuation<Void, Never>?
        var requests = 0
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests += 1
            await withCheckedContinuation { pending = $0 }
            let url = try #require(request.url)
            return (Data(#"{"data":{"wengine_vpn_ticket":"account-a-ticket"}}"#.utf8),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    private final class RequestObserverFactory: HTTPClientObserving {
        var generation = 0
        var completions: [Int] = []
        func forRequest() -> any HTTPClientObserving { RequestObserver(factory: self, generation: generation) }
        func willSend(_ request: URLRequest) async throws {}
        func didFinish(request: URLRequest, data: Data?, response: URLResponse?, error: Error?, elapsed: TimeInterval) async {
            completions.append(-1)
        }
        private struct RequestObserver: HTTPClientObserving {
            let factory: RequestObserverFactory
            let generation: Int
            func willSend(_ request: URLRequest) async throws {}
            func didFinish(request: URLRequest, data: Data?, response: URLResponse?, error: Error?, elapsed: TimeInterval) async {
                factory.completions.append(generation)
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func transportObservationsCaptureTheRequestContextBeforeNetworkSuspension() async throws {
        let observer = RequestObserverFactory()
        let transport = SuspendedSchoolCookies()
        let client = HTTPClient(transport: transport, observer: observer)
        let task = Task { try await client.send(URLRequest(url: AppURL.required("https://example.invalid/context"))) }
        try await waitForTestEvent { !(transport.pending == nil) }
        observer.generation = 1
        transport.pending?.resume()
        _ = try await task.value
        #expect(observer.completions == [0])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, 1, 2])
    func delayedSchoolCookiesCheckAccountGenerationAndCancellation(change: Int) async throws {
        let credentials = MutableSchoolCredentials()
        let owner = credentials.schoolSessionIdentity
        let transport = SuspendedSchoolCookies()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let state = TeachingCenterSessionState(cookieStorage: cookies)
        let service = ScheduleService(credentials: credentials, crypto: Crypto(), schoolSessionRestorer: Restorer(),
            teachingCenterState: state, transport: transport)
        let task = Task { try await service.ensureTeachingCenterAuthentication() }
        try await waitForTestEvent { !(transport.pending == nil) }
        if change == 0 { credentials.currentStudentID = "school-b" }
        if change == 1 { credentials.generation += 1 }
        if change == 2 { task.cancel() }
        transport.pending?.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cookies.cookies?.isEmpty == true)
        #expect(state.hasUsableSession(for: credentials.currentStudentID) == false)
        if change < 2 {
            let challenge = BITLoginAuthenticationChallenge(challengeID: "old", accessToken: "token",
                status: "waiting_sms", maskedPhone: nil, expiresIn: 300, ownerIdentity: owner)
            await #expect(throws: CancellationError.self) {
                try await service.submitSMSCodeForTeachingCenterAuthentication("123456", for: challenge)
            }
            #expect(transport.requests == 1)
        }
    }

    @Test func teachingCenterSMSChallengePreservesItsIdentityAndExposesExpiry() async throws {
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let transport = SequenceTransport([(202, Data(#"{"detail":{"challenge_id":"sms","access_token":"token","status":"waiting_sms","masked_phone":"138****0000","expires_in":300}}"#.utf8))])
        let service = service(transport: transport, state: TeachingCenterSessionState(cookieStorage: cookies))
        do {
            try await service.ensureTeachingCenterAuthentication()
            Issue.record("Expected SMS challenge")
        } catch let ScheduleServiceError.secondFactorRequired(challenge) {
            #expect(challenge.challengeID == "sms" && challenge.accessToken == "token")
            #expect(challenge.maskedPhone == "138****0000" && !challenge.isExpired)
        }
        let expired = BITLoginAuthenticationChallenge(challengeID: "expired", accessToken: "token",
            status: "waiting_sms", maskedPhone: nil, expiresIn: 0, receivedAt: .distantPast)
        do {
            try await service.submitSMSCodeForTeachingCenterAuthentication("123456", for: expired)
            Issue.record("Expected expired SMS challenge")
        } catch let ScheduleServiceError.challengeInvalid(message) {
            #expect(message.contains("验证码已过期"))
        }
        #expect(transport.requests.count == 1 && cookies.cookies?.isEmpty == true)
    }

    private struct AuthenticatedRestorer: SchoolSessionRestoring {
        func restoreSchoolSessionIfNeeded() async throws -> String? { "school-session" }
    }

    private final class SuspendedSecondFactor: HTTPTransport {
        static let html = #"<form action="/cas/login"><input id="login-page-flowkey" value="flow"><input id="user-object-id" value="user"><div id="secondSmsLoginForm"></div></form>"#
        let suspendedStage: String
        var pending: CheckedContinuation<Void, Never>?
        var requests: [URLRequest] = []
        init(_ stage: String) { suspendedStage = stage }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let url = try #require(request.url)
            let stage = url.path.contains("getPhoneNumber") ? "phone" : url.path.contains("sendSmsCode") ? "send"
                : url.path.contains("checkToken") ? "verify" : request.httpMethod == "POST" ? "login" : "html"
            if stage == suspendedStage { await withCheckedContinuation { pending = $0 } }
            let text = stage == "phone" ? #"{"code":200,"data":{"phone":"13800000000","maskTel":"138****0000"}}"#
                : stage == "html" ? Self.html : #"{"code":200}"#
            return (Data(text.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["html", "phone", "send", "input", "verify", "login"])
    func nativeSecondFactorKeepsOneOwnerAcrossEverySuspension(stage: String) async throws {
        for change in 0...2 {
            let credentials = MutableSchoolCredentials()
            let owner = credentials.schoolSessionIdentity
            let transport = SuspendedSecondFactor(stage)
            let service = ScheduleService(credentials: credentials, crypto: Crypto(), schoolSessionRestorer: AuthenticatedRestorer(),
                teachingCenterState: TeachingCenterSessionState(cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)),
                transport: transport)
            let context = try #require(SchoolLoginHTMLParser.parseSecondFactorPage(html: SuspendedSecondFactor.html,
                baseURL: AppURL.required("https://sso.bit.edu.cn")))
            var input: CheckedContinuation<String, Never>?
            let handler: SchoolSMSCodeHandler = { _ in
                if stage == "input" { return await withCheckedContinuation { input = $0 } }
                return "123456"
            }
            let task = Task<Void, any Error> {
                if stage == "html" { _ = try await service.refreshLexueCalendarURL(schoolSMSCodeHandler: handler) }
                else { try await service.completeSchoolSecondFactor(context, handler: handler, smsDeliveryMode: .send, owner: owner) }
            }
            try await waitForTestEvent { !(stage == "input" ? input == nil : transport.pending == nil) }
            let count = transport.requests.count
            if change == 0 { credentials.currentStudentID = "school-b" }
            if change == 1 { credentials.generation += 1 }
            if change == 2 { task.cancel() }
            if stage == "input" { input?.resume(returning: "123456") } else { transport.pending?.resume() }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(transport.requests.count == count)
        }
    }

    @Test func nativeSecondFactorSubmitsTheCapturedStudentAndFormContext() async throws {
        let credentials = MutableSchoolCredentials()
        let transport = SuspendedSecondFactor("none")
        let service = ScheduleService(credentials: credentials, crypto: Crypto(), schoolSessionRestorer: AuthenticatedRestorer(),
            teachingCenterState: TeachingCenterSessionState(cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)), transport: transport)
        let context = try #require(SchoolLoginHTMLParser.parseSecondFactorPage(html: SuspendedSecondFactor.html,
            baseURL: AppURL.required("https://sso.bit.edu.cn")))
        try await service.completeSchoolSecondFactor(context, handler: { _ in "123456" }, smsDeliveryMode: .send,
            owner: credentials.schoolSessionIdentity)
        let request = try #require(transport.requests.last)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(transport.requests.count == 4 && request.url?.path == "/cas/login")
        #expect(body.contains("username=school-a") && body.contains("execution=flow") && body.contains("password=123456"))
    }

    @Test func lexueSubscriptionUpgradesItsURLAndKeepsCompletedEventIdentity() async throws {
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
        let existing = DDLEventRecord(id: "homework", group: "lexue", title: "作业", text: "",
            dueAt: Date(timeIntervalSince1970: 0), done: true)
        let service = service(transport: transport, restorer: AuthenticatedRestorer())
        let result = try await service.syncDDLEventsForPreflight(existingEvents: [existing],
            storedURL: "http://lexue.bit.edu.cn/calendar/export_execute.php?userid=42&token=test")
        #expect(result.events.count == 1 && result.events.first?.done == true)
        #expect(result.events.first?.title == "作业" && result.events.first?.text == "提交报告")
        #expect(transport.requests.first?.url?.scheme == "https")
        #expect(transport.requests.first?.url?.query == "userid=42&token=test")
    }
}
