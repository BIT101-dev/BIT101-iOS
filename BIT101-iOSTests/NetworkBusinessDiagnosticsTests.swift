import ClientCore
import Foundation
import DesignSystemKit
import ScoreDomain
import ScoreInfrastructure
import SchedulePorts
import ScorePorts
import Testing
import TransportCore
@testable import BIT101_iOS

@MainActor
struct NetworkBusinessDiagnosticsTests {
    @Test func schoolAdaptersKeepTheirFailureIdentityThroughSharedAlerts() {
        let failures: [(any Error, SchoolServiceFailure)] = [
            (ScheduleServiceError.teachingCenterSessionExpired, .sessionExpired),
            (ScheduleServiceError.schoolTransportFailure, .secureConnection),
            (ScheduleServiceError.authenticationFailed("[status=401, risk=ustc-token]"), .authenticationRestricted),
            (ScheduleServiceError.schoolResponse("对不起，无权访问该资源"), .accessDenied),
            (ScoreServiceError.queryFailed("jxzxehall: 解析 service url 失败"), .authenticationChannel),
            (NativeSchoolAuthenticationError.serviceUnavailable(503), .unavailable)
        ]
        for (error, expected) in failures {
            #expect(SchoolServiceFailure.from(error) == expected)
            let alert = AppAlert(title: "可调整的标题", error: error)
            #expect(!AppErrorPresentation(alert: alert).allowsDiagnostics)
            #expect(!ErrorReportViewModel(alert: alert).allowsSubmission)
        }
        #expect(SchoolServiceFailure.from(ScheduleServiceError.invalidResponse) == nil)
        #expect(SchoolServiceFailure.from(ScoreServiceError.invalidResponse) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func schoolServiceFailuresKeepTheirGuidanceAndBlockDeveloperReports() async throws {
        for (title, failure) in [
            ("登录失败", SchoolServiceFailure.authenticationChannel),
            ("身份验证失败", .authenticationChannel), ("加载话廊失败", .authenticationChannel),
            ("课表同步失败", .authenticationRestricted), ("学期列表加载失败", .sessionExpired),
            ("验证已失效", .authenticationChannel), ("成绩查询失败", .authenticationChannel),
            ("可信成绩单申请失败", .sessionExpired), ("课表同步失败", .accessDenied),
            ("学校服务连接失败", .secureConnection), ("课表同步失败", .sessionExpired)
        ] {
            let alert = AppAlert(title: title, message: "可独立调整的页面文案", underlyingError: failure)
            let presentation = AppErrorPresentation(alert: alert)
            let expectedTitle = failure == .authenticationChannel ? "学校认证通道异常" : "学校服务异常"
            #expect(presentation.title == expectedTitle && presentation.message.contains("学校"))
            #expect(!presentation.allowsDiagnostics && presentation.allowsSchoolServiceLink)
            let inline = DiagnosticRecoveryActions(title: title, message: "页面错误提示", allowsDiagnostics: false, underlyingError: failure).presentation
            #expect(inline.title == expectedTitle && inline.allowsSchoolServiceLink && !inline.allowsDiagnostics)
            #expect(!presentation.message.contains("risk="))
            let page = try #require(URL(string: "https://jxzxehall.bit.edu.cn/fault"))
            #expect(AppErrorPresentation(alert: alert, schoolServiceURL: page).schoolServiceURL == page)
            var submitted = false
            let model = ErrorReportViewModel(alert: alert, submitReport: { _ in submitted = true })
            #expect(!model.allowsSubmission)
            #expect(!(await model.submit()) && !submitted)
        }
    }

    @Test func clientAndUnclassifiedFailuresKeepDeveloperReports() {
        for (title, message) in [
            ("DDL 同步失败", "课表缓存读取受阻"), ("课表同步失败", "服务器返回了无法识别的数据"),
            ("加载话廊失败", "服务器响应异常（HTTP 500）：数据库错误Orz"), ("登录失败", "当前会话已过期"),
            ("客户端数据读取失败", "学校会话暂时失效"),
            ("空教室同步失败", "查询教室失败")
        ] {
            let alert = AppAlert(title: title, message: message)
            let recentSchoolPage = AppURL.required("https://jxzxehall.bit.edu.cn/fault")
            let presentation = AppErrorPresentation(alert: alert, schoolServiceURL: recentSchoolPage)
            #expect(presentation.title == title && presentation.message == message && presentation.allowsDiagnostics)
            #expect(!presentation.allowsSchoolServiceLink && presentation.schoolServiceURL == nil)
            #expect(ErrorReportViewModel(alert: alert).allowsSubmission)
        }
        let userInput = DiagnosticRecoveryActions(title: "需要短信验证", message: "请输入验证码。", allowsDiagnostics: false).presentation
        #expect(!userInput.allowsDiagnostics && !userInput.allowsSchoolServiceLink)
    }

    private final class Credentials: LoginCredentialsStoring {
        var values: [String: String] = [:]
        func read(account: String) -> String { values[account] ?? "" }
        func save(_ value: String, account: String) { values[account] = value }
        func delete(account: String) -> Bool { values[account] = nil; return true }
    }
    private struct Transport: HTTPTransport {
        let body: String
        var statusCode = 200
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: statusCode,
                httpVersion: nil, headerFields: nil)))
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func loginAdapterClassifiesItsSchoolProtocolResponseBeforePresentation() async throws {
        let transport = Transport(body: #"{"msg":"初始化WebVPN验证失败Orz"}"#, statusCode: 500)
        let client = HTTPClient(transport: transport, observer: nil)
        let api = BIT101APIClient(httpClient: client, noRedirectHTTPClient: client)
        do {
            _ = try await api.webVPNVerifyInit(studentID: "fixture-owner")
            Issue.record("Expected initialization failure")
        } catch {
            #expect(SchoolServiceFailure.from(error) == .authenticationChannel)
            #expect(AppErrorPresentation(alert: AppAlert(title: "Changed title", error: error)).title == "学校认证通道异常")
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
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in })
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

    @Test(.timeLimit(.minutes(1)), arguments: [SchoolServiceTarget.teachingCenter, .grades, .transcript, .webVPN], [false, true])
    func schoolRecoveryLinksUseConfirmedFailuresAndCurrentBusinessHosts(target: SchoolServiceTarget, businessFailure: Bool) async throws {
        let owner = SchoolSessionIdentity(accountIdentifier: "school-recovery", generation: 0)
        let diagnostics = NetworkDiagnosticStore(currentIdentity: { owner })
        let failed = target.baseURL.appending(path: "failed").appending(queryItems: [URLQueryItem(name: "ticket", value: "fixture")])
        let response = try #require(HTTPURLResponse(url: failed, statusCode: businessFailure ? 200 : 503, httpVersion: nil, headerFields: nil))
        await diagnostics.record(owner: owner, request: URLRequest(url: failed),
            data: Data((businessFailure ? "<html>对不起，无权访问该资源</html>" : "unavailable").utf8), response: response, error: nil, elapsed: 0)
        let normal = AppURL.required("https://sso.bit.edu.cn/normal")
        let success = try #require(HTTPURLResponse(url: normal, statusCode: 200, httpVersion: nil, headerFields: nil))
        for error in [nil, URLError(.cancelled)] {
            await diagnostics.record(owner: owner, request: URLRequest(url: normal),
                data: Data("<script>window.onerror = () => {}; const certificate = 'valid';</script>".utf8),
                response: success, error: error, elapsed: 0)
        }
        #expect(await diagnostics.latestSchoolServicePageURL() == target.baseURL.appending(path: "failed"))
    }

    @Test(.timeLimit(.minutes(1)))
    func loginParsingFailureKeepsItsFieldPathInTheRequestDiagnostic() async throws {
        let domain = "BIT101Tests.login-business-diagnostics"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in })
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
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in })
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
