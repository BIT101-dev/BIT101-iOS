import TransportCore
import ClientCore
import Foundation
import Combine
import CommunityTransport
import Testing
@testable import BIT101_iOS

@Suite("Extended login state transitions")
struct ExtendedLoginTests {
    private final class ServiceStub: LoginServicing {
        let changes = PassthroughSubject<Void, Never>()
        var sessionChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
        var savedStudentID: String
        let savedPassword: String
        var hasCachedSession: Bool
        let bootstrapError: Error?
        let checkLoginResult: String?
        var loginResult: Result<String, Error> = .success("1120260001")
        var beforeLogin: (() async -> Void)?
        private(set) var checkLoginCalls = 0
        private(set) var loginCalls: [(String, String)] = []

        init(
            studentID: String = "1120260001",
            password: String = "saved",
            hasCachedSession: Bool = false,
            bootstrapError: Error? = nil,
            checkLoginResult: String? = nil
        ) {
            savedStudentID = studentID
            savedPassword = password
            self.hasCachedSession = hasCachedSession
            self.bootstrapError = bootstrapError
            self.checkLoginResult = checkLoginResult
        }

        func checkLogin() async throws -> String? {
            checkLoginCalls += 1
            if let bootstrapError {
                throw bootstrapError
            }
            return checkLoginResult
        }

        func login(studentID: String, password: String) async throws -> String {
            loginCalls.append((studentID, password))
            await beforeLogin?()
            return try loginResult.get()
        }

        func logout() {}
    }

    @Test("Successful explicit login enters the signed-in state", .timeLimit(.minutes(1)))
    @MainActor
    func successfulLogin() async {
        let service = ServiceStub()
        let viewModel = LoginViewModel(service: service)
        viewModel.studentID = " 1120260001 "
        viewModel.password = "secret"

        await viewModel.login()

        #expect(viewModel.screenState == .signedIn(studentID: "1120260001"))
        #expect(viewModel.password.isEmpty)
        #expect(service.loginCalls.map(\.0) == ["1120260001"])
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func repeatedKeyboardLoginSharesTheSubmittingOperation() async throws {
        let service = ServiceStub()
        var pending: CheckedContinuation<Void, Never>?
        service.beforeLogin = { await withCheckedContinuation { pending = $0 } }
        let model = LoginViewModel(service: service)
        model.password = "secret"
        let first = Task { await model.login() }
        try await waitForTestEvent { !(pending == nil) }
        service.loginResult = .failure(URLError(.timedOut))
        await model.login()
        #expect(service.loginCalls.count == 1 && model.isSubmitting)
        service.loginResult = .success("1120260001")
        pending?.resume()
        await first.value
        #expect(model.screenState == .signedIn(studentID: "1120260001") && model.isSubmitting == false)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func aLateLoginFailureKeepsTheNewlyPublishedSession() async throws {
        let service = ServiceStub()
        var pending: CheckedContinuation<Void, Never>?
        service.beforeLogin = { await withCheckedContinuation { pending = $0 } }
        let model = LoginViewModel(service: service)
        model.password = "secret"
        let task = Task { await model.login() }
        try await waitForTestEvent { !(pending == nil) }
        service.savedStudentID = "B"
        service.hasCachedSession = true
        service.changes.send(())
        service.loginResult = .failure(URLError(.timedOut))
        pending?.resume()
        await task.value
        #expect(model.screenState == .signedIn(studentID: "B") && model.alert == nil)
    }

    @Test("Failed explicit login stays signed out and exposes the error", .timeLimit(.minutes(1)))
    @MainActor
    func failedLogin() async {
        let service = ServiceStub()
        service.loginResult = .failure(URLError(.notConnectedToInternet))
        let viewModel = LoginViewModel(service: service)
        viewModel.studentID = "1120260001"
        viewModel.password = "secret"

        await viewModel.login()

        #expect(viewModel.screenState == .signedOut)
        #expect(viewModel.alert?.title == "登录失败")
    }

    @Test("Cancelled login keeps the signed-out state and alert clear", .timeLimit(.minutes(1)))
    @MainActor
    func cancelledLogin() async {
        let service = ServiceStub()
        service.loginResult = .failure(CancellationError())
        let viewModel = LoginViewModel(service: service)
        viewModel.studentID = "1120260001"
        viewModel.password = "secret"

        await viewModel.login()

        #expect(viewModel.screenState == .signedOut)
        #expect(viewModel.alert == nil)
        #expect(!viewModel.isSubmitting)
        #expect(service.loginCalls.count == 1)
    }

    @Test("Blank credentials are rejected before the service is called", .timeLimit(.minutes(1)))
    @MainActor
    func blankCredentials() async {
        let service = ServiceStub()
        let viewModel = LoginViewModel(service: service)
        viewModel.studentID = ""

        await viewModel.login()

        #expect(service.loginCalls.isEmpty)
        #expect(viewModel.alert?.title == "学号不能为空")
    }

    @Test("Logout keeps the saved student identifier but clears the session")
    @MainActor
    func logoutKeepsStudentID() {
        let service = ServiceStub(password: "")
        let viewModel = LoginViewModel(service: service)
        viewModel.logout()

        #expect(viewModel.screenState == .signedOut)
        #expect(viewModel.studentID == "1120260001")
    }

    @Test("Verified login identity replaces a stale cached identifier", .timeLimit(.minutes(1)))
    @MainActor
    func adoptsVerifiedStudentID() async {
        let service = ServiceStub(
            studentID: "1120260001",
            hasCachedSession: true,
            checkLoginResult: "1120260002"
        )
        let viewModel = LoginViewModel(service: service)

        await viewModel.bootstrapIfNeeded()

        #expect(viewModel.screenState == .signedIn(studentID: "1120260002"))
        #expect(viewModel.studentID == "1120260002")
        #expect(service.checkLoginCalls == 1)
    }

    @Test("Cached login remains available through transient bootstrap failure", .timeLimit(.minutes(1)))
    @MainActor
    func transientBootstrapFailure() async {
        let service = ServiceStub(hasCachedSession: true, bootstrapError: URLError(.timedOut))
        let viewModel = LoginViewModel(service: service)

        await viewModel.bootstrapIfNeeded()

        #expect(viewModel.screenState == .signedIn(studentID: "1120260001"))
        #expect(viewModel.alert == nil)
        #expect(service.checkLoginCalls == 1)
    }
}

@MainActor
@Suite(.serialized)
struct LoginStorageTests {
    private final class EndpointResponses: HTTPTransport {
        let scenario: String
        init(_ scenario: String) { self.scenario = scenario }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            if scenario == "cancelled" { throw CancellationError() }
            if scenario == "timeout" { throw URLError(.timedOut) }
            let requested = try #require(request.url)
            let target = scenario == "path" ? URL(string: "https://bit101.flwfdd.xyz/login")
                : scenario == "host" ? URL(string: "https://example.invalid/user/check")
                : scenario == "query" ? URL(string: requested.absoluteString + "?maintenance=1") : requested
            let targetURL = try #require(target)
            return (Data(), try #require(HTTPURLResponse(url: targetURL,
                statusCode: scenario == "revoked" ? 401 : 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["valid", "revoked", "path", "host", "query"])
    func communityLoginValidationRequiresItsBusinessEndpoint(scenario: String) async throws {
        let http = HTTPClient(transport: EndpointResponses(scenario), observer: nil)
        let client = BIT101APIClient(httpClient: http, noRedirectHTTPClient: http)
        if scenario == "valid" || scenario == "revoked" {
            #expect(try await client.checkBIT101Login(fakeCookie: "fixture") == (scenario == "valid"))
        } else {
            do {
                _ = try await client.checkBIT101Login(fakeCookie: "fixture")
                Issue.record("Login requires the requested business endpoint")
            } catch {
                guard case LoginServiceError.invalidServerResponse = error else {
                    Issue.record("Expected invalid business response: \(error)")
                    return
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["cancelled", "timeout"])
    func decoratedLoginErrorsPreserveCancellationAndTheirUnderlyingCause(scenario: String) async {
        let http = HTTPClient(transport: EndpointResponses(scenario), observer: nil)
        let client = BIT101APIClient(httpClient: http, noRedirectHTTPClient: http)
        do { _ = try await client.checkBIT101Login(fakeCookie: "fixture"); Issue.record("故障请求需要传播错误") }
        catch {
            #expect(TaskCancellation.matches(error) == (scenario == "cancelled"))
            if scenario == "timeout" {
                let cause = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                #expect(cause?.domain == NSURLErrorDomain && cause?.code == URLError.timedOut.rawValue)
            }
        }
    }
    private final class Credentials: LoginCredentialsStoring {
        var values: [String: String] = [:]
        var failsWrites = false
        var failsDeletes = false
        var writeCount = 0
        var failOnWrite: Int?
        var failsReads = false
        var readCount = 0
        func read(account: String) throws -> String {
            readCount += 1
            if failsReads { throw CocoaError(.fileReadNoPermission) }
            return values[account] ?? ""
        }
        func save(_ value: String, account: String) throws {
            writeCount += 1
            if failsWrites || failOnWrite == writeCount { throw CocoaError(.fileWriteNoPermission) }
            values[account] = value
        }
        func delete(account: String) -> Bool {
            guard !failsDeletes else { return false }
            values[account] = nil
            return true
        }
    }

    private enum RefreshFailure: Error, CommunityAPIServiceError {
        case notLoggedIn, invalidResponse
        static var communityNotLoggedIn: Self { .notLoggedIn }
        static var communityInvalidResponse: Self { .invalidResponse }
    }

    private final class RenewalResponses: HTTPTransport {
        var paths: [String] = []
        var beforeLoginResponse: (() async -> Void)?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            paths.append(url.path)
            if url.path == "/user/login" { await beforeLoginResponse?() }
            let body: String
            switch url.path {
            case "/user/login": body = #"{"fake_cookie":"renewed-cookie"}"#
            case "/user/webvpn_verify_init":
                body = #"{"salt":"AAAAAAAAAAAAAAAAAAAAAA==","execution":"school-flow","cookie":"school-cookie","captcha":""}"#
            case "/user/webvpn_verify": body = #"{"token":"school-proof","code":"123456"}"#
            case "/user/register": body = #"{"fake_cookie":"renewed-cookie"}"#
            default: body = ""
            }
            let status = request.value(forHTTPHeaderField: "fake-cookie") == "old-cookie" ? 401 : 200
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status,
                httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1))) func communityRenewalRetainsTheSelectedClientAndDiagnosticOwner() async throws {
        let domain = "BIT101Tests.community-renewal-dependencies"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        for sessionFactory in [false, true] {
            let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
            try storage.saveLoginState(studentID: "fixture-account", password: "fixture-password", fakeCookie: "old-cookie")
            let diagnostics = NetworkDiagnosticStore(currentIdentity: { storage.schoolSessionIdentity })
            let transport = RenewalResponses()
            let http = HTTPClient(transport: transport, networkWarningCenter: nil, storage: storage, diagnostics: diagnostics)
            let client: CommunityAPIClient<RefreshFailure> = sessionFactory
                ? CommunitySession.appSession(storage: storage, httpClient: http).client(errorDomain: "fixture")
                : CommunityAPIClient(storage: storage, httpClient: http, errorDomain: "fixture")
            try await client.requestVoid(path: "fixture-renewal", method: "GET")
            let expected = ["/fixture-renewal", "/user/login", "/fixture-renewal"]
            #expect(transport.paths == expected && storage.fakeCookie == "renewed-cookie")
            let records = await diagnostics.recent()
            #expect(records.compactMap { URL(string: $0.url)?.path } == expected)
            #expect(records.map(\.statusCode) == [401, 200, 200])
            storage.clearSession()
            #expect(await diagnostics.recent().isEmpty)
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func optionalCommunityReadsRecoverThroughBothApplicationFactories(sessionFactory: Bool) async throws {
        let domain = "BIT101Tests.optional-community-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "fixture-account", password: "fixture-password", fakeCookie: "old-cookie",
            communityPasswordDigest: "fixture-digest")
        let transport = RenewalResponses()
        var pending: CheckedContinuation<Void, Never>?
        transport.beforeLoginResponse = { await withCheckedContinuation { pending = $0 } }
        defer { storage.clearSession(); pending?.resume() }
        let http = HTTPClient(transport: transport, observer: nil)
        let client: CommunityAPIClient<RefreshFailure> = sessionFactory
            ? CommunitySession.appSession(storage: storage, httpClient: http).client(errorDomain: "fixture")
            : CommunityAPIClient(storage: storage, httpClient: http, errorDomain: "fixture")
        _ = try await client.requestData(path: "fixture-renewal", authentication: .optional)
        try await waitForTestEvent { pending != nil }
        #expect(storage.fakeCookie == "old-cookie" && transport.paths.filter { $0 == "/fixture-renewal" }.count == 2)
        pending?.resume(); pending = nil
        try await waitForTestEvent { storage.fakeCookie == "renewed-cookie" }
        #expect(transport.paths.filter { $0 == "/user/login" }.count == 1)
    }

    private final class SuspendedCookieCheck: HTTPTransport {
        let oldStatus: Int
        var pending: CheckedContinuation<Void, Never>?
        init(oldStatus: Int) { self.oldStatus = oldStatus }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let old = request.value(forHTTPHeaderField: "fake-cookie") == "old-cookie"
            if old { await withCheckedContinuation { pending = $0 } }
            let url = try #require(request.url)
            if url.path == "/user/webvpn_verify_init" {
                return (Data(#"{"salt":"AAAAAAAAAAAAAAAAAAAAAA==","execution":"school-flow","cookie":"school-cookie","captcha":""}"#.utf8),
                    try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            }
            if url.path == "/user/login" || url.path == "/user/webvpn_verify" {
                return (Data(#"{"detail":"账号或密码错误"}"#.utf8), try #require(HTTPURLResponse(url: url,
                    statusCode: 401, httpVersion: nil, headerFields: nil)))
            }
            return (Data(), try #require(HTTPURLResponse(url: url,
                statusCode: old ? oldStatus : 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test func restoredCredentialsRetainTheirAtomicOwnerDuringBackendReadFailures() throws {
        let domain = "BIT101Tests.login-storage.reads"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = Credentials()
        let storage = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "A", password: "fixture", fakeCookie: "cookie-A")
        let owner = storage.communityCredentials
        let reads = backend.readCount
        backend.failsReads = true
        #expect(storage.communityCredentials == owner)
        #expect(storage.currentStudentID == "A" && storage.currentPassword == "fixture")
        #expect(try storage.loadCredentials()?.studentID == "A")
        #expect(backend.readCount == reads)
        let reopened = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        #expect(reopened.credentialReadIssue != nil)
        #expect(reopened.hasResolvedSession == false)
        #expect(throws: CocoaError.self) { try reopened.loadCredentials() }
        var recoveredOwners: [CommunitySessionIdentity] = []
        let subscription = reopened.changes.sink { recoveredOwners.append($0) }
        backend.failsReads = false
        #expect(try reopened.loadCredentials()?.studentID == "A")
        #expect(reopened.communityCredentials.identity.accountIdentifier == "A")
        #expect(reopened.communityCredentials.cookie == owner.cookie && reopened.credentialReadIssue == nil)
        #expect(reopened.hasResolvedSession)
        #expect(recoveredOwners == [.init(accountIdentifier: "A", generation: 1)])
        withExtendedLifetime(subscription) {}
    }

    @Test(.timeLimit(.minutes(1)))
    func remoteRevocationUpdatesTheRootPresentationAndANewSessionRestoresIt() async throws {
        let domain = "BIT101Tests.login-presentation"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "A", password: "fixture", fakeCookie: "old-cookie", communityPasswordDigest: "fixture-digest")
        let owner = storage.communityCredentials.identity
        let transport = SuspendedCookieCheck(oldStatus: 401)
        let http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        let model = LoginViewModel(service: service)
        #expect(model.screenState == .signedIn(studentID: "A"))
        let check = Task { try await service.checkLogin() }
        try await waitForTestEvent { !(transport.pending == nil) }
        transport.pending?.resume()
        await #expect(throws: CommunitySessionRestorationError.self) { try await check.value }
        #expect(storage.communityCredentials.identity == owner && storage.fakeCookie.isEmpty && storage.hasCachedSession)
        #expect(model.screenState == .signedIn(studentID: "A") && model.password.isEmpty)
        try storage.saveLoginState(studentID: "B", password: "fixture", fakeCookie: "new-cookie")
        #expect(model.screenState == .signedIn(studentID: "B") && model.studentID == "B")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [200, 401])
    func backgroundCookieValidationKeepsTheNewlyRenewedSameAccountSession(status: Int) async throws {
        let domain = "BIT101Tests.cookie-check-renewal"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "A", password: "fixture", fakeCookie: "old-cookie")
        let identity = storage.communityCredentials.identity
        let transport = SuspendedCookieCheck(oldStatus: status)
        let http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        let old = Task { try await service.checkLogin() }
        try await waitForTestEvent { !(transport.pending == nil) }
        try storage.saveLoginState(studentID: "A", password: "fixture", fakeCookie: "renewed-cookie")
        #expect(storage.communityCredentials.identity == identity)
        transport.pending?.resume()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(storage.fakeCookie == "renewed-cookie")
        #expect(try await service.checkLogin() == "A")
    }

    private final class SchoolRestoreResponses: HTTPTransport {
        let scenario: String
        var requests = 0
        init(_ scenario: String) { self.scenario = scenario }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests += 1
            let url = try #require(request.url)
            let login = #"<input id="login-croypto" value="MTIzNDU2Nzg5MDEyMzQ1Ng=="><input id="login-page-flowkey" value="fixture-flow">"#
            var status = 200
            var headers: [String: String] = [:]
            let html: String
            if requests == 1 { html = login }
            else if requests == 2, scenario.hasPrefix("redirect-") {
                status = 302
                headers["Location"] = scenario == "redirect-gate" ? "/gate/cas-success" : "/cas/login?retry=1"
                html = ""
            } else {
                switch scenario {
                case "empty": html = ""
                case "english-error", "redirect-error": html = "<html>Invalid credentials</html>"
                case "login-form", "redirect-login": html = login
                case "spaced-login": html = #"<input name = "username"><span>注销</span>"#
                case "redirect-gate": status = 401; html = ""
                default: html = #"<a href="/cas/logout">退出登录</a>"#
                }
            }
            return (Data(html.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["empty", "english-error", "login-form", "spaced-login", "redirect-login", "redirect-error", "direct-success", "redirect-gate"])
    func productionSchoolRestoreRequiresPositiveAuthenticationEvidence(scenario: String) async throws {
        let domain = "BIT101Tests.school-restore-response"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "fixture-account", password: "fixture-password", fakeCookie: "fixture-cookie")
        let transport = SchoolRestoreResponses(scenario)
        let client = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: client, noRedirectHTTPClient: client))
        if ["direct-success", "redirect-gate"].contains(scenario) {
            #expect(try await service.restoreSchoolSessionIfNeeded() == "fixture-account")
        } else {
            await #expect(throws: LoginServiceError.self) { try await service.restoreSchoolSessionIfNeeded() }
        }
        #expect(transport.requests == (scenario.hasPrefix("redirect-") ? 3 : 2))
        #expect(storage.fakeCookie == "fixture-cookie")
    }

    private final class SuspendedSchoolRestore: HTTPTransport {
        let suspendedRequest: Int
        var requests = 0
        var pending: CheckedContinuation<Void, Never>?
        init(suspendedRequest: Int) { self.suspendedRequest = suspendedRequest }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests += 1
            if requests == suspendedRequest { await withCheckedContinuation { pending = $0 } }
            let url = try #require(request.url)
            let html = requests == 1
                ? #"<input id="login-croypto" value="MTIzNDU2Nzg5MDEyMzQ1Ng=="><input id="login-page-flowkey" value="fixture-flow">"#
                : "cas-success"
            return (Data(html.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [1, 2])
    func schoolRestoreKeepsItsCapturedAccountAcrossBothNetworkWaits(request: Int) async throws {
        let domain = "BIT101Tests.school-restore"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "account-a", password: "fixture-password", fakeCookie: "fixture-a")
        let transport = SuspendedSchoolRestore(suspendedRequest: request)
        let client = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: client, noRedirectHTTPClient: client))
        let task = Task { try await service.restoreSchoolSessionIfNeeded() }
        try await waitForTestEvent { !(transport.pending == nil) }
        storage.clearSession()
        try storage.saveLoginState(studentID: "account-a", password: "fixture-password", fakeCookie: "fixture-next")
        transport.pending?.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(storage.fakeCookie == "fixture-next")
        #expect(transport.requests == request)
    }

    @Test func credentialChangesCarryAccountGenerationsAndStayWithTheirOwner() throws {
        let firstDomain = "BIT101Tests.login-storage.first"
        let secondDomain = "BIT101Tests.login-storage.second"
        let firstDefaults = try #require(UserDefaults(suiteName: firstDomain))
        let secondDefaults = try #require(UserDefaults(suiteName: secondDomain))
        firstDefaults.removePersistentDomain(forName: firstDomain)
        secondDefaults.removePersistentDomain(forName: secondDomain)
        defer {
            firstDefaults.removePersistentDomain(forName: firstDomain)
            secondDefaults.removePersistentDomain(forName: secondDomain)
        }
        let firstBackend = Credentials()
        let secondBackend = Credentials()
        var clearedSchools = 0
        let first = LoginStorage(defaults: firstDefaults, credentials: firstBackend, clearSchoolCookies: { clearedSchools += 1 })
        let second = LoginStorage(defaults: secondDefaults, credentials: secondBackend, clearSchoolCookies: {})
        var firstChanges: [CommunitySessionIdentity] = []
        var secondChanges: [CommunitySessionIdentity] = []
        var cookies: [String] = []
        let session = CommunitySession.appSession(storage: first)
        let subscriptions = [first.changes.sink { firstChanges.append($0) }, second.changes.sink { secondChanges.append($0) },
            session.credentialsChanges.sink { cookies.append($0.cookie) }]
        try first.saveLoginState(studentID: " A ", password: "synthetic", fakeCookie: "cookie-A")
        try first.saveLoginState(studentID: "A", password: "synthetic", fakeCookie: "renewed-A")
        #expect(firstChanges == [.init(accountIdentifier: "A", generation: 1)])
        #expect(first.communityCredentials.cookie == "renewed-A")
        #expect(cookies == ["cookie-A", "renewed-A"])
        #expect(clearedSchools == 2)
        try first.saveLoginState(studentID: "B", password: "synthetic", fakeCookie: "cookie-B")
        first.clearSession()
        #expect(firstChanges.map(\.generation) == [1, 2, 3])
        #expect(first.currentStudentID == "B")
        #expect(first.currentPassword.isEmpty && first.fakeCookie.isEmpty)
        #expect(cookies == ["cookie-A", "renewed-A", "cookie-B", ""])
        #expect(first.clearAllLocalData())
        #expect(firstChanges.last == .init(accountIdentifier: "", generation: 4))
        #expect(clearedSchools == 5)
        #expect(secondChanges.isEmpty && secondBackend.values.isEmpty)
        withExtendedLifetime(subscriptions) {}
    }

    @Test func credentialWriteFailurePreservesThePublishedIdentity() throws {
        let domain = "BIT101Tests.login-storage.failure"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = Credentials()
        let storage = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "A", password: "synthetic", fakeCookie: "cookie-A")
        let previous = storage.communityCredentials
        var changes: [CommunitySessionIdentity] = []
        let subscription = storage.changes.sink { changes.append($0) }
        backend.failsWrites = true
        #expect(throws: CocoaError.self) {
            try storage.saveLoginState(studentID: "B", password: "synthetic", fakeCookie: "cookie-B")
        }
        #expect(storage.communityCredentials == previous)
        #expect(changes.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    @Test func atomicCredentialsAndRevocationSurviveBackendFailuresAndReopen() throws {
        let domain = "BIT101Tests.login-storage.revocation"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = Credentials()
        let storage = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "A", password: "password-A", fakeCookie: "cookie-A")
        let before = backend.writeCount
        backend.failOnWrite = before + 2
        try storage.saveLoginState(studentID: "B", password: "password-B", fakeCookie: "cookie-B")
        #expect(backend.writeCount == before + 1)
        #expect(storage.currentStudentID == "B")
        #expect(storage.currentPassword == "password-B")
        #expect(storage.fakeCookie == "cookie-B")
        backend.failsWrites = true
        backend.failsDeletes = true
        storage.clearSession()
        #expect(storage.fakeCookie.isEmpty && storage.currentPassword.isEmpty)
        #expect(try storage.loadCredentials() == nil)
        storage.preservingLoginMarkers { defaults.removePersistentDomain(forName: domain) }
        let reopened = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        #expect(reopened.currentStudentID == "B")
        #expect(reopened.fakeCookie.isEmpty && reopened.currentPassword.isEmpty)
        #expect(!reopened.clearAllLocalData())
        reopened.clearSession()
        #expect(reopened.currentStudentID.isEmpty && reopened.fakeCookie.isEmpty)
        backend.failsWrites = false
        backend.failsDeletes = false
        backend.failOnWrite = nil
        try reopened.saveLoginState(studentID: "C", password: "password-C", fakeCookie: "cookie-C")
        #expect(reopened.currentStudentID == "C" && reopened.fakeCookie == "cookie-C")
    }

    @Test(arguments: [false, true])
    func freshInstallationClearsCredentialsLeftInKeychain(hasResidue: Bool) throws {
        let domain = "BIT101Tests.login-storage.fresh-install"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = Credentials()
        if hasResidue {
            backend.values = ["login.sid": "previous-account", "login.password": "previous-password",
                "login.fakeCookie": "previous-cookie",
                "login.session": #"{"studentID":"previous-account","password":"previous-password","fakeCookie":"previous-cookie"}"#]
        }
        var schoolCookieClears = 0
        let storage = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: { schoolCookieClears += 1 })
        #expect(storage.currentStudentID.isEmpty && storage.currentPassword.isEmpty && storage.fakeCookie.isEmpty)
        #expect(try storage.loadCredentials() == nil && storage.loadCommunityPasswordDigest() == nil)
        #expect(backend.values.isEmpty && schoolCookieClears == 1)
        #expect(defaults.bool(forKey: "login.installationMarker"))
        try storage.saveLoginState(studentID: "new-account", password: "school-password", fakeCookie: "new-cookie")
        let reopened = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        #expect(reopened.currentStudentID == "new-account" && reopened.currentPassword == "school-password")
        #expect(reopened.fakeCookie == "new-cookie")
    }

    @Test(arguments: ["legacy-keys", "session-record"])
    func credentialMigrationUsesTheSelectedBackend(format: String) throws {
        let domain = "BIT101Tests.login-storage.migration"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "login.installationMarker")
        let backend = Credentials()
        if format == "legacy-keys" {
            defaults.set("legacy-cookie", forKey: "login.fakeCookie")
            backend.values = ["login.sid": "A", "login.password": "school-password"]
        } else {
            backend.values["login.session"] = #"{"studentID":"A","password":"school-password","fakeCookie":"legacy-cookie"}"#
        }
        var schoolCookieClears = 0
        let storage = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: { schoolCookieClears += 1 })
        #expect(storage.fakeCookie == "legacy-cookie")
        #expect(storage.currentPassword == "school-password" && schoolCookieClears == 0)
        #expect(storage.communityCredentials.identity == .init(accountIdentifier: "A"))
        #expect(defaults.object(forKey: "login.fakeCookie") == nil)
        #expect(try storage.loadCommunityPasswordDigest() == nil)
        let reopened = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        #expect(reopened.currentStudentID == "A" && reopened.currentPassword == "school-password")
        #expect(reopened.fakeCookie == "legacy-cookie")
    }

    @Test func clearingPreferencesAndSigningInAgainKeepsTheNewSessionAcrossLaunch() throws {
        let domain = "BIT101Tests.login-storage.clear-and-login"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = Credentials()
        let storage = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "A", password: "password-A", fakeCookie: "cookie-A")
        #expect(storage.clearAllLocalData())
        storage.preservingLoginMarkers { defaults.removePersistentDomain(forName: domain) }
        #expect(defaults.bool(forKey: "login.installationMarker"))
        #expect(defaults.string(forKey: "login.session.revoked") == "all")
        try storage.saveLoginState(studentID: "B", password: "password-B", fakeCookie: "cookie-B")
        let reopened = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        #expect(reopened.currentStudentID == "B" && reopened.currentPassword == "password-B" && reopened.fakeCookie == "cookie-B")
    }

    @Test(.timeLimit(.minutes(1))) func emptySessionRecoveryPublishesResolvedLogoutAfterReadFailure() async throws {
        let domain = "BIT101Tests.login-storage.empty-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "login.installationMarker")
        let backend = Credentials()
        backend.failsReads = true
        let storage = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        #expect(storage.hasResolvedSession == false)
        var readiness: [Bool] = []
        let observer = storage.changes.sink { _ in
            readiness.append(AppRestoreReadiness.sessionIsReady(.signedOut, storage: storage))
        }
        backend.failsReads = false
        storage.retrySessionReadIfNeeded()
        #expect(storage.hasResolvedSession && storage.fakeCookie.isEmpty)
        #expect(readiness == [true])
        withExtendedLifetime(observer) {}
        backend.failsReads = true
        backend.failsWrites = true
        let pending = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        #expect(pending.hasResolvedSession == false)
        pending.clearSession()
        #expect(AppRestoreReadiness.sessionIsReady(.signedOut, storage: pending))
    }

    @Test(.timeLimit(.minutes(1))) func foregroundAndProtectedDataRecoveryRestoreTheExistingLoginPresentation() async throws {
        let domain = "BIT101Tests.login-storage.lifecycle-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        for protectedDataEvent in [false, true] {
            defaults.removePersistentDomain(forName: domain)
            let backend = Credentials()
            let stored = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
            try stored.saveLoginState(studentID: "A", password: "fixture", fakeCookie: "cookie-A")
            backend.failsReads = true
            let reopened = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
            let http = HTTPClient(transport: EndpointResponses("valid"), observer: nil)
            let model = LoginViewModel(service: LoginService(storage: reopened,
                apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http)))
            await model.bootstrapIfNeeded()
            #expect(model.screenState == .signedOut && reopened.credentialReadIssue != nil)
            var readiness: [Bool] = []
            let observer = model.$screenState.sink { readiness.append(AppRestoreReadiness.sessionIsReady($0, storage: reopened)) }
            #expect(readiness == [false])
            let delegate = AppDelegate()
            delegate.restoreLoginSession = { reopened.retrySessionReadIfNeeded() }
            backend.failsReads = false
            if protectedDataEvent { delegate.applicationProtectedDataDidBecomeAvailable(.shared) }
            else { delegate.restoreLoginSession() }
            #expect(model.screenState == .signedIn(studentID: "A"))
            #expect(reopened.fakeCookie == "cookie-A" && reopened.credentialReadIssue == nil)
            #expect(readiness == [false, true])
            withExtendedLifetime(observer) {}
        }
    }
}


extension LoginStorageTests {
    private final class RegistrationResponses: HTTPTransport {
        var requests: [(String, [String: Any])] = []
        var registerStatus = 200
        var loginStatus = 200
        var captcha = ""
        var beforeResponse: (() async -> Void)?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let payload = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any] ?? [:]
            requests.append((url.path, payload))
            await beforeResponse?()
            let body: String
            switch url.path {
            case "/user/mail_verify": body = #"{"token":"mail-proof"}"#
            case "/user/webvpn_verify_init":
                body = #"{"salt":"AAAAAAAAAAAAAAAAAAAAAA==","cookie":"fixture","execution":"fixture","captcha":""}"#
                    .replacingOccurrences(of: #""captcha":"""#, with: #""captcha":"\#(captcha)""#)
            case "/user/webvpn_verify": body = #"{"token":"school-proof","code":"123456"}"#
            case "/user/register": body = #"{"fake_cookie":"registered-cookie"}"#
            case "/user/login": body = loginStatus == 200 ? #"{"fake_cookie":"registered-cookie"}"# : #"{"msg":"用户名或密码错误Orz"}"#
            default: throw URLError(.unsupportedURL)
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url,
                statusCode: url.path == "/user/register" ? registerStatus : url.path == "/user/login" ? loginStatus : 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func schoolLoginAndRegistrationExposeCaptchaRequirements() async throws {
        let domain = "BIT101Tests.school-captcha"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {}, requestSchoolPassword: { _ in "school-password" })
        let transport = RegistrationResponses(), http = HTTPClient(transport: transport, observer: nil)
        transport.loginStatus = 500
        transport.captcha = "data:image/png;base64,fixture"
        let service = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        for registration in [false, true] {
            do {
                if registration { _ = try await service.verifyRegistrationIdentity(studentID: "A", password: "fixture") }
                else { _ = try await service.login(studentID: "A", password: "fixture") }
                Issue.record("Captcha requires an actionable authentication response")
            } catch LoginServiceError.schoolCaptchaRequired {
                #expect(LoginServiceError.schoolCaptchaRequired.localizedDescription.contains("校园邮箱"))
            }
        }
        #expect(transport.requests.map(\.0) == ["/user/login", "/user/webvpn_verify_init", "/user/webvpn_verify_init"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [RegistrationVerificationMethod.school, .email])
    func registrationAndResetUseTheVerifiedIdentityAndKeepSchoolCredentialsSeparate(method: RegistrationVerificationMethod) async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101Tests.registration"))
        defer { defaults.removePersistentDomain(forName: "BIT101Tests.registration") }
        let credentials = Credentials()
        let storage = LoginStorage(defaults: defaults, credentials: credentials, clearSchoolCookies: {})
        let transport = RegistrationResponses(), http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        let model = AccountRegistrationViewModel(studentID: " 1120260001 ", service: service)
        model.password = "community-password"; model.confirmation = model.password
        model.method = method; model.schoolPassword = "school-password"
        #expect(model.canVerify && !model.canSubmit)
        await model.verify()
        if method == .email {
            #expect(model.resendAt > Date() && !model.canSubmit)
            await model.verify()
            #expect(transport.requests.count == 1)
            model.code = "１２３４５６"
            #expect(!model.canSubmit)
            model.code = "123456"
        } else { #expect(model.verified) }
        model.confirmation = "different"
        #expect(!model.canSubmit)
        model.confirmation = model.password
        #expect(model.canSubmit)
        await model.submit()
        #expect(model.alert == nil && model.password.isEmpty && model.schoolPassword.isEmpty)
        let request = try #require(transport.requests.last)
        #expect(request.0 == "/user/register")
        #expect(request.1["login_mode"] as? Bool == false)
        #expect(request.1["password"] as? String == LoginCrypto.md5Hex("community-password"))
        #expect(request.1["token"] as? String == (method == .school ? "school-proof" : "mail-proof"))
        #expect(request.1["code"] as? String == "123456")
        #expect(storage.currentStudentID == "1120260001" && storage.fakeCookie == "registered-cookie")
        #expect(storage.currentPassword == (method == .school ? "school-password" : "community-password"))
        #expect(try storage.loadCredentials()?.password == (method == .school ? "school-password" : "community-password"))
        let reopened = LoginStorage(defaults: defaults, credentials: credentials, clearSchoolCookies: {})
        #expect(try reopened.loadCommunityPasswordDigest() == LoginCrypto.md5Hex("community-password"))
        let reopenedService = LoginService(storage: reopened, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        try await reopenedService.renewCommunitySession(observed: reopened.communityCredentials)
        #expect(transport.requests.last?.0 == "/user/login")
        #expect(transport.requests.last?.1["password"] as? String == LoginCrypto.md5Hex("community-password"))
        reopened.clearSession()
        #expect(try reopened.loadCommunityPasswordDigest() == nil && reopened.loadCredentials() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func communityLoginPreservesSchoolCredentialsAndTracksValidatedCommunityPasswords() async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101Tests.community-password"))
        defer { defaults.removePersistentDomain(forName: "BIT101Tests.community-password") }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "A", password: "school-password", fakeCookie: "old-cookie",
            communityPasswordDigest: LoginCrypto.md5Hex("old-community-password"))
        let transport = RegistrationResponses(), http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        _ = try await service.login(studentID: "A", password: "community-password")
        #expect(storage.currentPassword == "school-password")
        #expect(try storage.loadCommunityPasswordDigest() == LoginCrypto.md5Hex("community-password"))
        _ = try await service.login(studentID: "B", password: "another-password")
        #expect(storage.currentPassword == "another-password" && storage.currentStudentID == "B")
        #expect(try storage.loadCommunityPasswordDigest() == LoginCrypto.md5Hex("another-password"))
        #expect(transport.requests.map(\.0) == ["/user/login", "/user/login"])
    }

    @Test(.timeLimit(.minutes(1)))
    func registrationProofsFollowTheirAccountAndVerificationMethod() async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101Tests.registration-proof"))
        defer { defaults.removePersistentDomain(forName: "BIT101Tests.registration-proof") }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        let transport = RegistrationResponses(), http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        let model = AccountRegistrationViewModel(studentID: "A", service: service)
        model.password = "community-password"; model.confirmation = model.password; model.schoolPassword = "school-password"
        await model.verify()
        #expect(model.canSubmit)
        model.studentID = "B"
        #expect(!model.canSubmit && !model.verified)
        await model.verify()
        model.schoolPassword = "changed-password"
        #expect(!model.canSubmit && !model.verified)
        model.method = .email
        var pending: CheckedContinuation<Void, Never>?
        transport.beforeResponse = { await withCheckedContinuation { pending = $0 } }
        let operation = Task { await model.verify() }
        try await waitForTestEvent { !(pending == nil) }
        model.studentID = "C"
        pending?.resume(); await operation.value
        model.code = "123456"
        #expect(!model.canSubmit && model.alert == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func failedOrSupersededRegistrationKeepsTheCurrentSession(superseded: Bool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101Tests.registration-session"))
        defer { defaults.removePersistentDomain(forName: "BIT101Tests.registration-session") }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "A", password: "school", fakeCookie: "old-cookie")
        let transport = RegistrationResponses(), http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        if superseded {
            transport.beforeResponse = { try? storage.saveLoginState(studentID: "B", password: "school-B", fakeCookie: "new-cookie") }
        } else { transport.registerStatus = 400 }
        do {
            try await service.registerAccount(studentID: "A", password: "community-password", token: "proof", code: "123456", schoolPassword: nil)
            Issue.record("A failed or superseded response must preserve the active session")
        } catch { #expect(TaskCancellation.matches(error) == superseded) }
        #expect(storage.fakeCookie == (superseded ? "new-cookie" : "old-cookie"))
        #expect(try storage.loadCommunityPasswordDigest() == nil)
    }
}
