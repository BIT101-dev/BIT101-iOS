import ClientCore
import TransportCore
import ScoreInfrastructure
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
import Foundation
import UIKit
import Testing
@testable import BIT101_iOS

@Suite("Login parsing and authentication", .serialized)
struct LoginLogicTests {
    @Test(arguments: [#"<input id = 'login-croypto' value = 'c2FsdA==' />"#,
                      #"<input value = 'c2FsdA==' id = 'login-croypto' />"#,
                      #"<span id = 'login-croypto'>c2FsdA==</span>"#])
    func parsesHTMLAttributeWhitespace(html: String) {
        let context = SchoolLoginHTMLParser.parse(html: html + #"<input id = 'login-page-flowkey' value = 'flow' />"#)
        #expect(context.salt == "c2FsdA==" && context.execution == "flow")
    }

    @Test(arguments: [#"<input data-id='login-croypto' value='wrong' />"#,
                      #"<input value='wrong' data-id='login-croypto' />"#,
                      #"<span data-id='login-croypto'>wrong</span>"#])
    func distinguishesHTMLAttributeNames(html: String) {
        let context = SchoolLoginHTMLParser.parse(html: html + #"<a href='/logout'>退出登录</a>"#)
        #expect(context.salt == nil && context.isLoggedIn)
    }

    @Test func selectsTheSecondFactorFormWithItsOwnFields() throws {
        let html = #"<form action='/search'><input id='login-page-flowkey' value='other-flow'></form><form action='/cas/login?step=2'><input id = 'login-page-flowkey' value = 'flow'><input id = 'user-object-id' value = 'user'><div id='secondSmsLoginForm'></div></form>"#
        let baseURL = try #require(URL(string: "https://sso.bit.edu.cn/cas/login"))
        let context = try #require(SchoolLoginHTMLParser.parseSecondFactorPage(html: html, baseURL: baseURL))
        #expect(context.execution == "flow" && context.userObjectID == "user")
        #expect(context.formAction.absoluteString == "https://sso.bit.edu.cn/cas/login?step=2")
        #expect(SchoolLoginHTMLParser.parseSecondFactorPage(html: html + html, baseURL: baseURL) == nil)
    }

    @Test("CAS success gate 401 is a terminal browser landing response")
    func acceptsCASGateLandingResponse() throws {
        let gateURL = try #require(URL(string: "https://sso.bit.edu.cn/gate/cas-success"))
        let otherURL = try #require(URL(string: "https://sso.bit.edu.cn/cas/login"))

        #expect(BIT101APIClient.isAcceptedSchoolLoginCompletion(statusCode: 401, url: gateURL))
        #expect(BIT101APIClient.isSchoolLoginSuccessLanding(gateURL))
        let reportedGateURL = try #require(URL(string: "https://sso.bit.edu.cn/gate/cas-success/?ticket=test-ticket"))
        #expect(BIT101APIClient.isAcceptedSchoolLoginCompletion(statusCode: 401, url: reportedGateURL))
        #expect(BIT101APIClient.isSchoolLoginSuccessLanding(reportedGateURL))
        #expect(!BIT101APIClient.isAcceptedSchoolLoginCompletion(statusCode: 401, url: otherURL))
        #expect(!BIT101APIClient.isSchoolLoginSuccessLanding(otherURL))
        #expect(!BIT101APIClient.isAcceptedSchoolLoginCompletion(statusCode: 204, url: otherURL))
        #expect(BIT101APIClient.isAcceptedSchoolLoginCompletion(statusCode: 204, url: gateURL))
    }

    @Test("CAS fields are extracted from either quote style")
    func parsesCASLoginPage() {
        let html = """
        <span id='login-croypto'> c2FsdA== </span>
        <span id="login-page-flowkey"> execution-value </span>
        用户名密码
        """
        let context = SchoolLoginHTMLParser.parse(html: html)

        #expect(context.salt == "c2FsdA==")
        #expect(context.execution == "execution-value")
        #expect(!context.isLoggedIn)
    }

    @Test("Authenticated marker takes precedence over login fields")
    func recognizesAuthenticatedPage() {
        let context = SchoolLoginHTMLParser.parse(
            html: "<html><a href=\"/logout\">退出登录</a></html>"
        )
        #expect(context.salt == nil)
        #expect(context.execution == nil)
        #expect(context.isLoggedIn)
    }

    @Test("Password transforms stay compatible with the existing backend")
    func passwordTransformVectors() throws {
        #expect(LoginCrypto.md5Hex("abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(try LoginCrypto.encryptPassword(
            "abc",
            saltBase64: "AAAAAAAAAAAAAAAAAAAAAA=="
        ) == "l2qZX5TPTB4ktuL7Bn56aQ==")
    }

    @Test("Malformed salts are rejected before encryption")
    func rejectsMalformedSalt() {
        #expect(throws: LoginServiceError.self) {
            try LoginCrypto.encryptPassword("password", saltBase64: "not base64")
        }
    }

    @Test("Credential failure responses use the dedicated login error")
    func recognizesCredentialFailureResponse() {
        #expect(BIT101APIClient.isCredentialFailureMessage("统一身份认证失败Orz"))
        #expect(BIT101APIClient.isCredentialFailureMessage("用户名或密码错误"))
        #expect(!BIT101APIClient.isCredentialFailureMessage("服务暂时不可用"))
    }

    @Test("School second-factor pages expose a resumable form context")
    func parsesSchoolSecondFactorPage() throws {
        let html = """
        <div id="secondSmsLoginForm"></div>
        <span id="login-page-flowkey">execution-value</span>
        <input id="user-object-id" value="user-object-value" />
        <form action="/cas/login"></form>
        """
        let baseURL = try #require(URL(string: "https://sso.bit.edu.cn/cas/login"))
        let context = try #require(
            SchoolLoginHTMLParser.parseSecondFactorPage(
                html: html,
                baseURL: baseURL
            )
        )

        #expect(context.execution == "execution-value")
        #expect(context.userObjectID == "user-object-value")
        #expect(context.formAction.absoluteString == "https://sso.bit.edu.cn/cas/login")
    }
}

@MainActor
extension LoginLogicTests {
    private final class Credentials: LoginCredentialsStoring {
        var values: [String: String] = [:]
        var failWrites = false
        func read(account: String) throws -> String { values[account] ?? "" }
        func save(_ value: String, account: String) throws {
            if failWrites { throw CocoaError(.fileWriteUnknown) }
            values[account] = value
        }
        func delete(account: String) -> Bool { values[account] = nil; return true }
    }

    private final class SchoolLoginResponses: HTTPTransport {
        var requests: [URLRequest] = []
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            requests.append(request)
            let body: Data
            switch url.lastPathComponent {
            case "login": body = Data((url.host == "sso.bit.edu.cn"
                ? #"<a href="/logout">退出登录</a>"# : #"{"fake_cookie":"community-cookie"}"#).utf8)
            case "cookies": body = Data(#"{"data":{"wengine_vpn_ticket":"school-ticket"}}"#.utf8)
            case "xnxqcx.do": body = Data(#"{"datas":{"xnxqcx":{"rows":[{"DM":"2026-2027-1"},{"DM":"2025-2026-2"}]}}}"#.utf8)
            case "dqxnxq.do": body = Data(#"{"datas":{"dqxnxq":{"rows":[{"DM":"2026-2027-1"}]}}}"#.utf8)
            case "cxxszhxqkb.do":
                let bundle = Bundle(for: SchoolLoginResponses.self)
                let fixture = bundle.url(forResource: "schedule-service-response", withExtension: "json", subdirectory: "Fixtures")
                    ?? bundle.url(forResource: "schedule-service-response", withExtension: "json")
                body = try Data(contentsOf: #require(fixture))
            case "cxxsksap.do": body = Data(#"{"datas":{"cxxsksap":{"rows":[]}}}"#.utf8)
            case "cxzkbrq.do": body = Data(#"{"data":[{"XQ":1,"RQ":"2026-09-07"}]}"#.utf8)
            case "ggzdpx.do": body = Data(#"{"datas":{"ggzdpx":{"rows":[{"DM":"2","MC":"良乡校区"}]}}}"#.utf8)
            case "cxjxl.do": body = Data(#"{"datas":{"cxjxl":{"rows":[{"JXLDM":"2701-2","JXLMC":"文萃楼B","XXXQDM":"2"}]}}}"#.utf8)
            case "cxkxjasqk.do": body = Data(#"{"datas":{"cxkxjasqk":{"rows":[{"JASMC":"B101","ZYJC":"1,2"}]}}}"#.utf8)
            case "start": body = Data(#"{"challenge_id":"score-challenge","access_token":"score-token","status":"authenticated"}"#.utf8)
            case "wdkbby-5959167891382285.do", "i18n.do": body = Data("{}".utf8)
            default: throw URLError(.unsupportedURL)
            }
            return (body, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    private func schoolService(storage: LoginStorage, transport: SchoolLoginResponses) throws -> ScheduleService {
        ScheduleService(credentials: storage, crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: AppScheduleSchoolSessionRestorer(restore: { throw URLError(.unsupportedURL) }),
            teachingCenterState: TeachingCenterSessionState(cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)),
            transport: transport)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["terms", "courses", "classrooms", "scores", "school-session"])
    func freshLoginMakesSchoolFeaturesUsableWithOnePassword(first: String) async throws {
        let domain = "BIT101Tests.community-school"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let credentials = Credentials(), transport = SchoolLoginResponses()
        var prompts: [String] = []
        let storage = LoginStorage(defaults: defaults, credentials: credentials, clearSchoolCookies: {}, requestSchoolPassword: {
            prompts.append($0)
            return "unexpected-password"
        })
        let http = HTTPClient(transport: transport, observer: nil)
        let login = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        #expect(try await login.login(studentID: "A", password: "account-password") == "A")
        #expect(storage.currentPassword == "account-password" && prompts.isEmpty)
        let owner = storage.communityCredentials
        let school = try schoolService(storage: storage, transport: transport)
        func use(_ feature: String) async throws {
            switch feature {
            case "terms": #expect(try await school.fetchAvailableTerms() == ["2026-2027-1", "2025-2026-2"])
            case "courses":
                let payload = try await school.syncCourses()
                #expect(payload.term == "2026-2027-1" && !payload.courses.isEmpty)
            case "classrooms":
                #expect(try await school.fetchCampuses().first?.name == "良乡校区")
                #expect(try await school.fetchBuildings(campusCode: "2").first?.id == "2701-2")
                #expect(try await school.fetchCurrentTermOnly() == "2026-2027-1")
                #expect(try await school.fetchClassrooms(buildingID: "2701-2", term: "2026-2027-1", date: Date()).first?.name == "B101")
            case "school-session": #expect(try await login.restoreSchoolSessionIfNeeded() == "A")
            default:
                let score = ScoreService(credentials: storage, httpClient: http, sensitiveHTTPClient: http,
                    endpointBaseURL: try #require(URL(string: "https://example.invalid")))
                #expect(try await score.startScoreChallenge().status == "authenticated")
            }
        }
        try await use(first)
        for feature in ["terms", "courses", "classrooms", "scores", "school-session"] where feature != first { try await use(feature) }
        #expect(prompts.isEmpty && storage.currentPassword == "account-password")
        #expect(storage.communityCredentials == owner)
        #expect(try storage.loadCommunityPasswordDigest() == LoginCrypto.md5Hex("account-password"))
        let loginRequest = try #require(transport.requests.first?.httpBody)
        let loginBody = try #require(JSONSerialization.jsonObject(with: loginRequest) as? [String: String])
        #expect(loginBody["password"] == LoginCrypto.md5Hex("account-password"))
        for request in transport.requests where ["cookies", "start"].contains(request.url?.lastPathComponent ?? "") {
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["password"] as? String == "account-password")
        }
        let reopened = LoginStorage(defaults: defaults, credentials: credentials, clearSchoolCookies: {})
        try await reopened.prepareSchoolCredentials()
        #expect(reopened.currentPassword == "account-password" && reopened.communityCredentials.cookie == owner.cookie)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["empty-password", "saved-password", "switch-account"])
    func loginReusesPasswordWithinTheSelectedAccount(state: String) async throws {
        let domain = "BIT101Tests.login-password-reuse"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        try storage.saveLoginState(studentID: state == "switch-account" ? "B" : "A",
            password: state == "empty-password" ? "" : "saved-school-password", fakeCookie: "old-cookie",
            communityPasswordDigest: "old-digest")
        let http = HTTPClient(transport: SchoolLoginResponses(), observer: nil)
        let login = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        #expect(try await login.login(studentID: "A", password: "account-password") == "A")
        #expect(storage.currentPassword == (state == "saved-password" ? "saved-school-password" : "account-password"))
        #expect(try storage.loadCommunityPasswordDigest() == LoginCrypto.md5Hex("account-password"))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "switch", "write-failure", "empty"])
    func interruptedSchoolPasswordEntryPreservesCommunitySession(reason: String) async throws {
        let domain = "BIT101Tests.school-password-interruption"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let credentials = Credentials()
        var reply: CheckedContinuation<String, Error>?
        let storage = LoginStorage(defaults: defaults, credentials: credentials, clearSchoolCookies: {}, requestSchoolPassword: { _ in
            try await withCheckedThrowingContinuation { reply = $0 }
        })
        try storage.saveLoginState(studentID: "A", password: "", fakeCookie: "cookie-A", communityPasswordDigest: "community-A")
        let pending = Task { try await storage.prepareSchoolCredentials() }
        try await waitForTestEvent { reply != nil }
        if reason == "switch" {
            try storage.saveLoginState(studentID: "B", password: "", fakeCookie: "cookie-B", communityPasswordDigest: "community-B")
        }
        if reason == "cancel" { pending.cancel() }
        if reason == "write-failure" { credentials.failWrites = true }
        reply?.resume(returning: reason == "empty" ? "" : "school-password")
        do { try await pending.value; Issue.record("Interrupted password entry must retain the account state") }
        catch { if ["cancel", "switch"].contains(reason) { #expect(error is CancellationError) } }
        #expect(storage.currentPassword.isEmpty)
        #expect(storage.currentStudentID == (reason == "switch" ? "B" : "A"))
        #expect(storage.fakeCookie == (reason == "switch" ? "cookie-B" : "cookie-A"))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func concurrentSchoolRequestsSharePasswordEntryAndSettingsCanReplaceIt(cancelWaiter: Bool) async throws {
        let domain = "BIT101Tests.school-password-concurrency"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        var prompts = 0
        var reply: CheckedContinuation<String, Error>?
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {}, requestSchoolPassword: { _ in
            prompts += 1
            return try await withCheckedThrowingContinuation { reply = $0 }
        })
        try storage.saveLoginState(studentID: "A", password: "", fakeCookie: "cookie", communityPasswordDigest: "community")
        let first = Task { try await storage.prepareSchoolCredentials() }
        try await waitForTestEvent { reply != nil }
        var secondStarted = false
        let second = Task { secondStarted = true; try await storage.prepareSchoolCredentials() }
        try await waitForTestEvent { secondStarted }
        if cancelWaiter { second.cancel() }
        reply?.resume(returning: "school-password"); reply = nil
        try await first.value
        do { try await second.value; #expect(!cancelWaiter) }
        catch { #expect(cancelWaiter && error is CancellationError) }
        #expect(prompts == 1)
        let owner = storage.communityCredentials
        let replacement = Task { try await storage.updateSchoolCredentials() }
        try await waitForTestEvent { reply != nil }
        reply?.resume(returning: "updated-school-password")
        try await replacement.value
        #expect(prompts == 2 && storage.currentPassword == "updated-school-password")
        #expect(storage.communityCredentials == owner)
    }

    @Test(.timeLimit(.minutes(1)))
    func schoolPasswordPromptUsesSecureInputAndDismissesOnCancellation() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let prompt = SchoolPasswordPrompt(presenter: { controller })
        let pending = Task { try await prompt.requestPassword(studentID: "A") }
        try await waitForTestEvent { controller.presentedViewController is UIAlertController }
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        let field = try #require(alert.textFields?.first)
        #expect(field.isSecureTextEntry && field.accessibilityIdentifier == "school.credentials.password")
        #expect(alert.preferredAction?.isEnabled == false)
        field.text = "school-password"
        field.sendActions(for: .editingChanged)
        #expect(alert.preferredAction?.isEnabled == true)
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Canceled input must resume the waiting request") }
        catch { #expect(error is CancellationError) }
        #expect(controller.presentedViewController == nil && field.text?.isEmpty == true)
    }
}
