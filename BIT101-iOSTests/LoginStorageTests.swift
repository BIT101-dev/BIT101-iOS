import ClientCore
import Combine
import CommunityTransport
import Foundation
import Testing
import TransportCore

@testable import BIT101_iOS

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
            let target =
                scenario == "path"
                ? URL(string: "https://bit101.flwfdd.xyz/login")
                : scenario == "host"
                    ? URL(string: "https://example.invalid/user/check")
                    : scenario == "query"
                        ? URL(string: requested.absoluteString + "?maintenance=1") : requested
            let targetURL = try #require(target)
            return (
                Data(),
                try #require(
                    HTTPURLResponse(
                        url: targetURL,
                        statusCode: scenario == "revoked" ? 401 : 200, httpVersion: nil,
                        headerFields: nil))
            )
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["valid", "revoked", "path", "host", "query"])
    func communityLoginValidationRequiresEndpoint(scenario: String) async throws {
        let http = HTTPClient(transport: EndpointResponses(scenario), observer: nil)
        let client = BIT101APIClient(httpClient: http, noRedirectHTTPClient: http)
        if scenario == "valid" || scenario == "revoked" {
            #expect(
                try await client.checkBIT101Login(fakeCookie: "fixture") == (scenario == "valid"))
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
    func decoratedLoginErrorsPreserveCancel(scenario: String) async {
        let http = HTTPClient(transport: EndpointResponses(scenario), observer: nil)
        let client = BIT101APIClient(httpClient: http, noRedirectHTTPClient: http)
        do {
            _ = try await client.checkBIT101Login(fakeCookie: "fixture")
            Issue.record("故障请求需要传播错误")
        } catch {
            #expect(TaskCancellation.matches(error) == (scenario == "cancelled"))
            if scenario == "timeout" {
                let cause = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                #expect(
                    cause?.domain == NSURLErrorDomain && cause?.code == URLError.timedOut.rawValue)
            }
        }
    }
    final class Credentials: LoginCredentialsStoring {
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
                body =
                    #"""
                    {"salt":"AAAAAAAAAAAAAAAAAAAAAA==","execution":"school-flow","cookie":"sch\#
                    ool-cookie","captcha":""}
                    """#
            case "/user/webvpn_verify": body = #"{"token":"school-proof","code":"123456"}"#
            case "/user/register": body = #"{"fake_cookie":"renewed-cookie"}"#
            default: body = ""
            }
            let status =
                request.value(forHTTPHeaderField: "fake-cookie") == "old-cookie" ? 401 : 200
            return (
                Data(body.utf8),
                try #require(
                    HTTPURLResponse(
                        url: url, statusCode: status,
                        httpVersion: nil, headerFields: nil))
            )
        }
    }

    @Test(.timeLimit(.minutes(1))) func communityRenewalRetainsSelectedClient() async throws {
        let domain = "BIT101Tests.community-renewal-dependencies"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        for sessionFactory in [false, true] {
            let storage = LoginStorage(
                defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in })
            try storage.saveLoginState(
                studentID: "fixture-account", password: "fixture-password", fakeCookie: "old-cookie"
            )
            let diagnostics = NetworkDiagnosticStore(currentIdentity: {
                storage.schoolSessionIdentity
            })
            let transport = RenewalResponses()
            let http = HTTPClient(
                transport: transport, networkWarningCenter: nil, storage: storage,
                diagnostics: diagnostics)
            let client: CommunityAPIClient<RefreshFailure> =
                sessionFactory
                ? CommunitySession.appSession(storage: storage, httpClient: http).client(
                    errorDomain: "fixture")
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
    func optionalCommunityReadsRecoverFactories(sessionFactory: Bool) async throws {
        let domain = "BIT101Tests.optional-community-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(
            defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in })
        try storage.saveLoginState(
            studentID: "fixture-account", password: "fixture-password", fakeCookie: "old-cookie",
            communityPasswordDigest: "fixture-digest")
        let transport = RenewalResponses()
        var pending: CheckedContinuation<Void, Never>?
        transport.beforeLoginResponse = { await withCheckedContinuation { pending = $0 } }
        defer {
            storage.clearSession()
            pending?.resume()
        }
        let http = HTTPClient(transport: transport, observer: nil)
        let client: CommunityAPIClient<RefreshFailure> =
            sessionFactory
            ? CommunitySession.appSession(storage: storage, httpClient: http).client(
                errorDomain: "fixture")
            : CommunityAPIClient(storage: storage, httpClient: http, errorDomain: "fixture")
        _ = try await client.requestData(path: "fixture-renewal", authentication: .optional)
        try await waitForTestEvent { pending != nil }
        #expect(
            storage.fakeCookie == "old-cookie"
                && transport.paths.filter { $0 == "/fixture-renewal" }.count == 2)
        pending?.resume()
        pending = nil
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
                return (
                    Data(
                        #"""
                        {"salt":"AAAAAAAAAAAAAAAAAAAAAA==","execution":"school-flow","cookie":\#
                        "school-cookie","captcha":""}
                        """#
                        .utf8),
                    try #require(
                        HTTPURLResponse(
                            url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                )
            }
            if url.path == "/user/login" || url.path == "/user/webvpn_verify" {
                return (
                    Data(#"{"detail":"账号或密码错误"}"#.utf8),
                    try #require(
                        HTTPURLResponse(
                            url: url,
                            statusCode: 401, httpVersion: nil, headerFields: nil))
                )
            }
            return (
                Data(),
                try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: old ? oldStatus : 200, httpVersion: nil, headerFields: nil))
            )
        }
    }

    @Test func restoredCredentialsRetainTheirFailures() throws {
        let domain = "BIT101Tests.login-storage.reads"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = Credentials()
        let storage = LoginStorage(
            defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
        try storage.saveLoginState(studentID: "A", password: "fixture", fakeCookie: "cookie-A")
        let owner = storage.communityCredentials
        let reads = backend.readCount
        backend.failsReads = true
        #expect(storage.communityCredentials == owner)
        #expect(storage.currentStudentID == "A" && storage.currentPassword == "fixture")
        #expect(try storage.loadCredentials()?.studentID == "A")
        #expect(backend.readCount == reads)
        let reopened = LoginStorage(
            defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
        #expect(reopened.credentialReadIssue != nil)
        #expect(reopened.hasResolvedSession == false)
        #expect(throws: CocoaError.self) { try reopened.loadCredentials() }
        var recoveredOwners: [CommunitySessionIdentity] = []
        let subscription = reopened.changes.sink { recoveredOwners.append($0) }
        backend.failsReads = false
        #expect(try reopened.loadCredentials()?.studentID == "A")
        #expect(reopened.communityCredentials.identity.accountIdentifier == "A")
        #expect(
            reopened.communityCredentials.cookie == owner.cookie
                && reopened.credentialReadIssue == nil)
        #expect(reopened.hasResolvedSession)
        #expect(recoveredOwners == [.init(accountIdentifier: "A", generation: 1)])
        withExtendedLifetime(subscription) {}
    }

    @Test(.timeLimit(.minutes(1)))
    func remoteRevocationUpdatesRootPresentation() async throws {
        let domain = "BIT101Tests.login-presentation"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(
            defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in })
        try storage.saveLoginState(
            studentID: "A", password: "fixture", fakeCookie: "old-cookie",
            communityPasswordDigest: "fixture-digest")
        let owner = storage.communityCredentials.identity
        let transport = SuspendedCookieCheck(oldStatus: 401)
        let http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(
            storage: storage,
            apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        let model = LoginViewModel(service: service)
        #expect(model.screenState == .signedIn(studentID: "A"))
        let check = Task { try await service.checkLogin() }
        try await waitForTestEvent { !(transport.pending == nil) }
        transport.pending?.resume()
        await #expect(throws: CommunitySessionRestorationError.self) { try await check.value }
        #expect(
            storage.communityCredentials.identity == owner && storage.fakeCookie.isEmpty
                && storage.hasCachedSession)
        #expect(model.screenState == .signedIn(studentID: "A") && model.password.isEmpty)
        try storage.saveLoginState(studentID: "B", password: "fixture", fakeCookie: "new-cookie")
        #expect(model.screenState == .signedIn(studentID: "B") && model.studentID == "B")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [200, 401])
    func backgroundCookieValidationKeepsSession(status: Int) async throws {
        let domain = "BIT101Tests.cookie-check-renewal"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(
            defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in })
        try storage.saveLoginState(studentID: "A", password: "fixture", fakeCookie: "old-cookie")
        let identity = storage.communityCredentials.identity
        let transport = SuspendedCookieCheck(oldStatus: status)
        let http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(
            storage: storage,
            apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        let old = Task { try await service.checkLogin() }
        try await waitForTestEvent { !(transport.pending == nil) }
        try storage.saveLoginState(
            studentID: "A", password: "fixture", fakeCookie: "renewed-cookie")
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
            let login =
                #"""
                <input id="login-croypto" value="MTIzNDU2Nzg5MDEyMzQ1Ng=="><input id="login-pa\#
                ge-flowkey" value="fixture-flow">
                """#
            var status = 200
            var headers: [String: String] = [:]
            let html: String
            if requests == 1 {
                html = login
            } else if requests == 2, scenario.hasPrefix("redirect-") {
                status = 302
                headers["Location"] =
                    scenario == "redirect-gate" ? "/gate/cas-success" : "/cas/login?retry=1"
                html = ""
            } else {
                switch scenario {
                case "empty": html = ""
                case "english-error", "redirect-error": html = "<html>Invalid credentials</html>"
                case "login-form", "redirect-login": html = login
                case "spaced-login": html = #"<input name = "username"><span>注销</span>"#
                case "redirect-gate":
                    status = 401
                    html = ""
                default: html = #"<a href="/cas/logout">退出登录</a>"#
                }
            }
            return (
                Data(html.utf8),
                try #require(
                    HTTPURLResponse(
                        url: url, statusCode: status, httpVersion: nil, headerFields: headers))
            )
        }
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "empty", "english-error", "login-form", "spaced-login", "redirect-login",
            "redirect-error", "direct-success", "redirect-gate",
        ])
    func productionSchoolRestoreRequiresEvidence(scenario: String) async throws {
        let domain = "BIT101Tests.school-restore-response"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(
            defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in })
        try storage.saveLoginState(
            studentID: "fixture-account", password: "fixture-password", fakeCookie: "fixture-cookie"
        )
        let transport = SchoolRestoreResponses(scenario)
        let client = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(
            storage: storage,
            apiClient: BIT101APIClient(httpClient: client, noRedirectHTTPClient: client))
        if ["direct-success", "redirect-gate"].contains(scenario) {
            #expect(try await service.restoreSchoolSession() == "fixture-account")
        } else {
            await #expect(throws: LoginServiceError.self) {
                try await service.restoreSchoolSession()
            }
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
            let html =
                requests == 1
                ? #"""
                <input id="login-croypto" value="MTIzNDU2Nzg5MDEyMzQ1Ng=="><input id="login-pa\#
                ge-flowkey" value="fixture-flow">
                """#
                : "cas-success"
            return (
                Data(html.utf8),
                try #require(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [1, 2])
    func schoolRestoreKeepsCapturedWaits(request: Int) async throws {
        let domain = "BIT101Tests.school-restore"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(
            defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in })
        try storage.saveLoginState(
            studentID: "account-a", password: "fixture-password", fakeCookie: "fixture-a")
        let transport = SuspendedSchoolRestore(suspendedRequest: request)
        let client = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(
            storage: storage,
            apiClient: BIT101APIClient(httpClient: client, noRedirectHTTPClient: client))
        let task = Task { try await service.restoreSchoolSession() }
        try await waitForTestEvent { !(transport.pending == nil) }
        storage.clearSession()
        try storage.saveLoginState(
            studentID: "account-a", password: "fixture-password", fakeCookie: "fixture-next")
        transport.pending?.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(storage.fakeCookie == "fixture-next")
        #expect(transport.requests == request)
    }

    @Test func credentialChangesCarryAccountGenerations() throws {
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
        let first = LoginStorage(
            defaults: firstDefaults, credentials: firstBackend,
            clearSchoolCookies: { _ in clearedSchools += 1 })
        let second = LoginStorage(
            defaults: secondDefaults, credentials: secondBackend, clearSchoolCookies: { _ in })
        var firstChanges: [CommunitySessionIdentity] = []
        var secondChanges: [CommunitySessionIdentity] = []
        var cookies: [String] = []
        let session = CommunitySession.appSession(storage: first)
        let subscriptions = [
            first.changes.sink { firstChanges.append($0) },
            second.changes.sink { secondChanges.append($0) },
            session.credentialsChanges.sink { cookies.append($0.cookie) },
        ]
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

    @Test func credentialWriteFailurePreservesIdentity() throws {
        let domain = "BIT101Tests.login-storage.failure"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = Credentials()
        let storage = LoginStorage(
            defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
        try storage.saveLoginState(studentID: "A", password: "synthetic", fakeCookie: "cookie-A")
        let previous = storage.communityCredentials
        var changes: [CommunitySessionIdentity] = []
        let subscription = storage.changes.sink { changes.append($0) }
        backend.failsWrites = true
        #expect(throws: CocoaError.self) {
            try storage.saveLoginState(
                studentID: "B", password: "synthetic", fakeCookie: "cookie-B")
        }
        #expect(storage.communityCredentials == previous)
        #expect(changes.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    @Test func atomicCredentialsAndSurviveBackendFailures() throws {
        let domain = "BIT101Tests.login-storage.revocation"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = Credentials()
        let storage = LoginStorage(
            defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
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
        let reopened = LoginStorage(
            defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
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
    func installationClearsCredentialsLeftKeychain(hasResidue: Bool) throws {
        let domain = "BIT101Tests.login-storage.fresh-install"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = Credentials()
        if hasResidue {
            backend.values = [
                "login.sid": "previous-account", "login.password": "previous-password",
                "login.fakeCookie": "previous-cookie",
                "login.session":
                    #"""
                {"studentID":"previous-account","password":"previous-password","fakeCookie\#
                ":"previous-cookie"}
                """#,
            ]
        }
        var schoolCookieClears = 0
        let storage = LoginStorage(
            defaults: defaults, credentials: backend,
            clearSchoolCookies: { _ in schoolCookieClears += 1 })
        #expect(
            storage.currentStudentID.isEmpty && storage.currentPassword.isEmpty
                && storage.fakeCookie.isEmpty)
        #expect(try storage.loadCredentials() == nil && storage.loadCommunityDigest() == nil)
        #expect(backend.values.isEmpty && schoolCookieClears == 1)
        #expect(defaults.bool(forKey: "login.installationMarker"))
        try storage.saveLoginState(
            studentID: "new-account", password: "school-password", fakeCookie: "new-cookie")
        let reopened = LoginStorage(
            defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
        #expect(
            reopened.currentStudentID == "new-account"
                && reopened.currentPassword == "school-password")
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
            backend.values["login.session"] =
                #"{"studentID":"A","password":"school-password","fakeCookie":"legacy-cookie"}"#
        }
        var schoolCookieClears = 0
        let storage = LoginStorage(
            defaults: defaults, credentials: backend,
            clearSchoolCookies: { _ in schoolCookieClears += 1 })
        #expect(storage.fakeCookie == "legacy-cookie")
        #expect(storage.currentPassword == "school-password" && schoolCookieClears == 0)
        #expect(storage.communityCredentials.identity == .init(accountIdentifier: "A"))
        #expect(defaults.object(forKey: "login.fakeCookie") == nil)
        #expect(try storage.loadCommunityDigest() == nil)
        let reopened = LoginStorage(
            defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
        #expect(reopened.currentStudentID == "A" && reopened.currentPassword == "school-password")
        #expect(reopened.fakeCookie == "legacy-cookie")
    }

    @Test func clearingPrefsAndKeepsNewSessionLaunch() throws {
        let domain = "BIT101Tests.login-storage.clear-and-login"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = Credentials()
        let storage = LoginStorage(
            defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
        try storage.saveLoginState(studentID: "A", password: "password-A", fakeCookie: "cookie-A")
        #expect(storage.clearAllLocalData())
        storage.preservingLoginMarkers { defaults.removePersistentDomain(forName: domain) }
        #expect(defaults.bool(forKey: "login.installationMarker"))
        #expect(defaults.string(forKey: "login.session.revoked") == "all")
        try storage.saveLoginState(studentID: "B", password: "password-B", fakeCookie: "cookie-B")
        let reopened = LoginStorage(
            defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
        #expect(
            reopened.currentStudentID == "B" && reopened.currentPassword == "password-B"
                && reopened.fakeCookie == "cookie-B")
    }

    @Test(.timeLimit(.minutes(1))) func emptySessionRecoveryLogout() async throws {
        let domain = "BIT101Tests.login-storage.empty-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "login.installationMarker")
        let backend = Credentials()
        backend.failsReads = true
        let storage = LoginStorage(
            defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
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
        let pending = LoginStorage(
            defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
        #expect(pending.hasResolvedSession == false)
        pending.clearSession()
        #expect(AppRestoreReadiness.sessionIsReady(.signedOut, storage: pending))
    }

    @Test(.timeLimit(.minutes(1))) func foregroundAndProtectedRestorePresentation() async throws {
        let domain = "BIT101Tests.login-storage.lifecycle-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        for protectedDataEvent in [false, true] {
            defaults.removePersistentDomain(forName: domain)
            let backend = Credentials()
            let stored = LoginStorage(
                defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
            try stored.saveLoginState(studentID: "A", password: "fixture", fakeCookie: "cookie-A")
            backend.failsReads = true
            let reopened = LoginStorage(
                defaults: defaults, credentials: backend, clearSchoolCookies: { _ in })
            let http = HTTPClient(transport: EndpointResponses("valid"), observer: nil)
            let model = LoginViewModel(
                service: LoginService(
                    storage: reopened,
                    apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http)))
            await model.bootstrapIfNeeded()
            #expect(model.screenState == .signedOut && reopened.credentialReadIssue != nil)
            var readiness: [Bool] = []
            let observer = model.$screenState.sink {
                readiness.append(AppRestoreReadiness.sessionIsReady($0, storage: reopened))
            }
            #expect(readiness == [false])
            let delegate = AppDelegate()
            delegate.restoreLoginSession = { reopened.retrySessionReadIfNeeded() }
            backend.failsReads = false
            if protectedDataEvent {
                delegate.applicationProtectedDataDidBecomeAvailable(.shared)
            } else {
                delegate.restoreLoginSession()
            }
            #expect(model.screenState == .signedIn(studentID: "A"))
            #expect(reopened.fakeCookie == "cookie-A" && reopened.credentialReadIssue == nil)
            #expect(readiness == [false, true])
            withExtendedLifetime(observer) {}
        }
    }
}
