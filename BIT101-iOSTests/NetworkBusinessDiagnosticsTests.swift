import ClientCore
import Foundation
import ScoreDomain
import ScoreInfrastructure
import Testing
import TransportCore
@testable import BIT101_iOS

@MainActor
struct NetworkBusinessDiagnosticsTests {
    private final class Credentials: LoginCredentialsStoring {
        var values: [String: String] = [:]
        func read(account: String) -> String { values[account] ?? "" }
        func save(_ value: String, account: String) { values[account] = value }
        func delete(account: String) -> Bool { values[account] = nil; return true }
    }
    private struct Transport: HTTPTransport {
        let body: String
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil)))
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
    }

    private struct RedirectTransport: HTTPTransport {
        let destination: URL
        let statusCode: Int
        let capturesFinalRequest: Bool
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            var redirected = URLRequest(url: destination)
            redirected.httpMethod = "GET"
            if capturesFinalRequest { HTTPRequestEvidenceContext.didReceiveFinalRequest?(redirected) }
            return (Data(#"{"required":7}"#.utf8), try #require(HTTPURLResponse(url: destination,
                statusCode: statusCode, httpVersion: nil, headerFields: nil)))
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            try await data(for: request)
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func redirectedFailuresKeepBothRequestsAndRecoverTheFinalPage(parsingFailure: Bool, capturesFinalRequest: Bool) async throws {
        let domain = "BIT101Tests.redirect-diagnostics"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        let diagnostics = NetworkDiagnosticStore(currentIdentity: { storage.schoolSessionIdentity })
        let initial = try #require(URL(string: "https://sso.bit.edu.cn/cas/login?ticket=initial-token"))
        let destination = try #require(URL(string: "https://jxzxehall.bit.edu.cn/fault?token=redirect-token"))
        let http = HTTPClient(transport: RedirectTransport(destination: destination, statusCode: parsingFailure ? 200 : 503,
            capturesFinalRequest: capturesFinalRequest),
            networkWarningCenter: nil, storage: storage, diagnostics: diagnostics)
        var request = URLRequest(url: initial)
        request.httpMethod = "POST"
        do {
            let response = try await http.send(request)
            let _: [String: String] = try await response.validated { data, _ in
                try JSONDecoder().decode([String: String].self, from: data)
            }
            Issue.record("重定向后的错误应传播至调用者")
        } catch {
            #expect(parsingFailure ? error is DecodingError : error is HTTPClientError)
        }
        let records = await diagnostics.recent()
        let record = try #require(records.first)
        #expect(records.count == 1 && record.error != nil)
        #expect(record.method == "POST" && record.url == initial.absoluteString)
        let facts = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(facts["finalMethod"] as? String == (capturesFinalRequest ? "GET" : nil))
        #expect(facts["finalURL"] as? String == destination.absoluteString)
        #expect(await diagnostics.latestSchoolServicePageURL()?.absoluteString == "https://jxzxehall.bit.edu.cn/fault")
    }

    @Test(.timeLimit(.minutes(1)))
    func loginParsingFailureKeepsItsFieldPathInTheRequestDiagnostic() async throws {
        let domain = "BIT101Tests.login-business-diagnostics"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        let diagnostics = NetworkDiagnosticStore(currentIdentity: { storage.schoolSessionIdentity })
        let http = HTTPClient(transport: Transport(body: #"{"captcha":7}"#), networkWarningCenter: nil, storage: storage, diagnostics: diagnostics)
        let client = BIT101APIClient(httpClient: http, noRedirectHTTPClient: http)
        await #expect(throws: LoginServiceError.self) { try await client.webVPNVerifyInit(studentID: "fixture") }
        let records = await diagnostics.recent()
        #expect(records.count == 1 && records.first?.error?.contains("captcha") == true)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func scoreValidationAmendsOneRequestAndKeepsItsFailureAfterImageTraffic(malformed: Bool) async throws {
        let domain = "BIT101Tests.business-diagnostics.\(malformed)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "diagnostic-owner", password: "fixture", fakeCookie: "fixture")
        let owner = storage.schoolSessionIdentity
        let diagnostics = NetworkDiagnosticStore(currentIdentity: { storage.schoolSessionIdentity })
        let body = malformed ? #"{"msg":"查询成功","data":7}"# : #"{"msg":"学校成绩查询维护","data":[]}"#
        let http = HTTPClient(transport: Transport(body: body), networkWarningCenter: nil, storage: storage, diagnostics: diagnostics)
        let service = ScoreService(credentials: storage, httpClient: http, sensitiveHTTPClient: http,
            endpointBaseURL: try #require(URL(string: "https://example.invalid")))
        let challenge = BITLoginAuthenticationChallenge(challengeID: "fixture", accessToken: "token", status: "authenticated",
            maskedPhone: nil, expiresIn: 120, ownerIdentity: owner)
        do { _ = try await service.fetchScores(detail: false, authenticatedBy: challenge); Issue.record("响应校验应传播故障") }
        catch { #expect(!(error is CancellationError)) }
        let records = await diagnostics.recent()
        let record = try #require(records.first)
        #expect(records.count == 1 && record.statusCode == 200 && record.responseBody == body)
        #expect(record.error?.contains(malformed ? "data" : "学校成绩查询维护") == true)
        let imageURL = try #require(URL(string: "https://example.invalid/image"))
        for _ in 0..<30 {
            await diagnostics.record(owner: owner, request: URLRequest(url: imageURL), data: Data(),
                response: nil, error: nil, elapsed: 0)
        }
        #expect(await diagnostics.recent().contains { $0.id == record.id && $0.error != nil })
    }
}
