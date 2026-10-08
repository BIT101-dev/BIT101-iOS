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
        var sessionChanges: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
        let savedStudentID: String
        let savedPassword: String
        let hasCachedSession: Bool
        let bootstrapError: Error?
        let checkLoginResult: String?
        var loginResult: Result<String, Error> = .success("1120260001")
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
            return try loginResult.get()
        }

        func logout() {}
    }

    @Test("Successful explicit login enters the signed-in state")
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

    @Test("Failed explicit login stays signed out and exposes the error")
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

    @Test("Cancelled login keeps the signed-out state and alert clear")
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

    @Test("Blank credentials are rejected before the service is called")
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

    @Test("Verified login identity replaces a stale cached identifier")
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

    @Test("Cached login remains available through transient bootstrap failure")
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
    private final class Credentials: LoginCredentialsStoring {
        var values: [String: String] = [:]
        var failsWrites = false
        var failsDeletes = false
        var writeCount = 0
        var failOnWrite: Int?
        func read(account: String) throws -> String { values[account] ?? "" }
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

    private final class SuspendedCookieCheck: HTTPTransport {
        let oldStatus: Int
        var pending: CheckedContinuation<Void, Never>?
        init(oldStatus: Int) { self.oldStatus = oldStatus }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let old = request.value(forHTTPHeaderField: "fake-cookie") == "old-cookie"
            if old { await withCheckedContinuation { pending = $0 } }
            let url = try #require(request.url)
            return (Data(), try #require(HTTPURLResponse(url: url,
                statusCode: old ? oldStatus : 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func remoteRevocationUpdatesTheRootPresentationAndANewSessionRestoresIt() async throws {
        let domain = "BIT101Tests.login-presentation"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "A", password: "fixture", fakeCookie: "old-cookie")
        let owner = storage.communityCredentials.identity
        let transport = SuspendedCookieCheck(oldStatus: 401)
        let service = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: HTTPClient(transport: transport, observer: nil)))
        let model = LoginViewModel(service: service)
        #expect(model.screenState == .signedIn(studentID: "A"))
        let check = Task { try await service.checkLogin() }
        while transport.pending == nil { await Task.yield() }
        transport.pending?.resume()
        #expect(try await check.value == nil)
        #expect(storage.communityCredentials.identity != owner && storage.fakeCookie.isEmpty)
        #expect(model.screenState == .signedOut && model.password.isEmpty)
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
        let service = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: HTTPClient(transport: transport, observer: nil)))
        let old = Task { try await service.checkLogin() }
        while transport.pending == nil { await Task.yield() }
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

    @Test(arguments: ["empty", "english-error", "login-form", "spaced-login", "redirect-login", "redirect-error", "direct-success", "redirect-gate"])
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
        while transport.pending == nil { await Task.yield() }
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
        let subscriptions = [first.changes.sink { firstChanges.append($0) }, second.changes.sink { secondChanges.append($0) }]
        try first.saveLoginState(studentID: " A ", password: "synthetic", fakeCookie: "cookie-A")
        try first.saveLoginState(studentID: "A", password: "synthetic", fakeCookie: "renewed-A")
        #expect(firstChanges == [.init(accountIdentifier: "A", generation: 1)])
        #expect(first.communityCredentials.cookie == "renewed-A")
        #expect(clearedSchools == 2)
        try first.saveLoginState(studentID: "B", password: "synthetic", fakeCookie: "cookie-B")
        first.clearSession()
        #expect(firstChanges.map(\.generation) == [1, 2, 3])
        #expect(first.currentStudentID == "B")
        #expect(first.currentPassword.isEmpty && first.fakeCookie.isEmpty)
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
        storage.preservingCredentialRevocation { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "login.installationMarker")
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

    @Test func credentialMigrationUsesTheSelectedBackend() throws {
        let domain = "BIT101Tests.login-storage.migration"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "login.installationMarker")
        defaults.set("legacy-cookie", forKey: "login.fakeCookie")
        let backend = Credentials()
        backend.values["login.sid"] = "A"
        let storage = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        #expect(storage.fakeCookie == "legacy-cookie")
        #expect(storage.communityCredentials.identity == .init(accountIdentifier: "A"))
        #expect(defaults.object(forKey: "login.fakeCookie") == nil)
    }
}
