import TransportCore
import ClientCore
import Foundation
import CommunityTransport
import Testing
@testable import BIT101_iOS

@MainActor
struct CommunitySessionRecoveryTests {
    @Test(.serialized, .timeLimit(.minutes(1)), arguments: ["switch", "logout", "cancel"])
    func reauthenticationKeepsItsCapturedAccountAndCancellationBoundary(interruption: String) async throws {
        let domain = "BIT101Tests.community-reauthentication-owner"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "A", password: "school-A", fakeCookie: "old-cookie")
        storage.requireCommunityAuthentication()
        let transport = SharedRenewalResponses(), http = HTTPClient(transport: transport, observer: nil)
        let login = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        var pending: CheckedContinuation<Void, Never>?
        transport.beforeRenew = { await withCheckedContinuation { pending = $0 } }
        let work = Task { try await login.restoreCommunitySession(password: "community-A") }
        defer { work.cancel(); pending?.resume(); pending = nil }
        try await waitForTestEvent { pending != nil }
        if interruption == "switch" { try storage.saveLoginState(studentID: "B", password: "school-B", fakeCookie: "cookie-B") }
        else if interruption == "logout" { login.logout() }
        else { work.cancel() }
        pending?.resume(); pending = nil
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(storage.fakeCookie == (interruption == "switch" ? "cookie-B" : ""))
        #expect(storage.currentPassword == (interruption == "switch" ? "school-B" : interruption == "logout" ? "" : "school-A"))
    }

    private final class Credentials: LoginCredentialsStoring {
        var values: [String: String] = [:]
        func read(account: String) throws -> String { values[account] ?? "" }
        func save(_ value: String, account: String) throws { values[account] = value }
        func delete(account: String) -> Bool { values[account] = nil; return true }
    }
    private enum RefreshFailure: Error, CommunityAPIServiceError {
        case notLoggedIn, invalidResponse
        static var communityNotLoggedIn: Self { .notLoggedIn }
        static var communityInvalidResponse: Self { .invalidResponse }
    }

    private final class SharedRenewalResponses: HTTPTransport {
        var paths: [String] = []
        var outcome = "success"
        var beforeRenew: (() async throws -> Void)?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            paths.append(url.path)
            var status = request.value(forHTTPHeaderField: "fake-cookie") == "old-cookie" ? 401 : 200
            var body = "{}"
            if url.path == "/user/login" {
                try await beforeRenew?()
                if outcome == "offline" { throw URLError(.timedOut) }
                status = outcome == "rejected" ? 401 : 200
                body = outcome == "rejected" ? #"{"detail":"账号或密码错误"}"# : #"{"fake_cookie":"renewed-cookie"}"#
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func startupAndCommunityRequestsShareOneCredentialRecoveryInEitherOrder() async throws {
        let domain = "BIT101Tests.shared-community-renewal"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        for startupFirst in [false, true] {
            for sessionFactory in [false, true] {
                let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
                try storage.saveLoginState(studentID: "A", password: "fixture", fakeCookie: "old-cookie", communityPasswordDigest: "digest")
                let transport = SharedRenewalResponses(), http = HTTPClient(transport: transport, observer: nil)
                let login = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
                let model = LoginViewModel(service: login)
                let client: CommunityAPIClient<RefreshFailure> = sessionFactory
                    ? CommunitySession.appSession(storage: storage, httpClient: http).client(errorDomain: "fixture")
                    : CommunityAPIClient(storage: storage, httpClient: http, errorDomain: "fixture")
                var pending: CheckedContinuation<Void, Never>?
                transport.beforeRenew = { await withCheckedContinuation { pending = $0 } }
                let first = Task {
                    if startupFirst { #expect(try await login.checkLogin() == "A") }
                    else { try await client.requestVoid(path: "fixture-renewal", method: "GET") }
                }
                try await waitForTestEvent { pending != nil }
                let second = Task {
                    if startupFirst { try await client.requestVoid(path: "fixture-renewal", method: "GET") }
                    else { #expect(try await login.checkLogin() == "A") }
                }
                try await waitForTestEvent { transport.paths.contains(startupFirst ? "/fixture-renewal" : "/user/check") }
                pending?.resume()
                try await first.value; try await second.value
                #expect(transport.paths.filter { $0 == "/user/login" }.count == 1)
                #expect(storage.fakeCookie == "renewed-cookie" && model.screenState == .signedIn(studentID: "A"))
                #expect(storage.currentPassword == "fixture")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func credentialRejectionAndTransientFailureHaveConsistentRootPresentation() async throws {
        let domain = "BIT101Tests.community-rejection"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        for outcome in ["rejected", "offline"] {
            for entry in ["startup", "client", "session"] {
                let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
                try storage.saveLoginState(studentID: "A", password: "fixture", fakeCookie: "old-cookie", communityPasswordDigest: "digest")
                let transport = SharedRenewalResponses(), http = HTTPClient(transport: transport, observer: nil)
                transport.outcome = outcome
                let login = LoginService(storage: storage, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
                let model = LoginViewModel(service: login)
                do {
                    if entry == "startup" { _ = try await login.checkLogin(); Issue.record("Rejected online credentials require recovery") }
                    else {
                        let client: CommunityAPIClient<RefreshFailure> = entry == "session"
                            ? CommunitySession.appSession(storage: storage, httpClient: http).client(errorDomain: "fixture")
                            : CommunityAPIClient(storage: storage, httpClient: http, errorDomain: "fixture")
                        try await client.requestVoid(path: "fixture-renewal", method: "GET")
                        Issue.record("An expired session requires recovery")
                    }
                } catch {
                    #expect(outcome == "offline" ? (error as? URLError)?.code == .timedOut
                        : entry == "startup" ? error is CommunitySessionRestorationError : error is RefreshFailure)
                }
                #expect(model.screenState == .signedIn(studentID: "A") && login.hasCachedSession)
                #expect(storage.fakeCookie == (outcome == "rejected" ? "" : "old-cookie"))
                #expect(storage.currentPassword == "fixture")
                await model.bootstrapIfNeeded()
                #expect(model.screenState == .signedIn(studentID: "A"))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func communityReauthenticationPreservesTheLocalAndSchoolAccountAcrossRelaunch() async throws {
        let domain = "BIT101Tests.local-community-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let credentials = Credentials()
        var schoolClears = 0
        let storage = LoginStorage(defaults: defaults, credentials: credentials, clearSchoolCookies: { schoolClears += 1 })
        try storage.saveLoginState(studentID: "A", password: "school-password", fakeCookie: "old-cookie", communityPasswordDigest: "digest")
        let identity = storage.schoolSessionIdentity
        schoolClears = 0
        storage.requireCommunityAuthentication()
        let reopened = LoginStorage(defaults: defaults, credentials: credentials, clearSchoolCookies: { schoolClears += 1 })
        #expect(reopened.hasCachedSession && reopened.fakeCookie.isEmpty && reopened.currentStudentID == "A")
        #expect(reopened.currentPassword == "school-password" && storage.schoolSessionIdentity == identity && schoolClears == 0)
        try await reopened.prepareSchoolCredentials()
        let transport = SharedRenewalResponses(), http = HTTPClient(transport: transport, observer: nil)
        let login = LoginService(storage: reopened, apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        let model = LoginViewModel(service: login), owner = reopened.communityCredentials.identity
        await model.bootstrapIfNeeded()
        #expect(model.screenState == .signedIn(studentID: "A"))
        try await login.restoreCommunitySession(password: "community-password")
        #expect(reopened.communityCredentials.identity == owner && reopened.fakeCookie == "renewed-cookie")
        #expect(reopened.currentPassword == "school-password" && schoolClears == 0)
        let restored = LoginStorage(defaults: defaults, credentials: credentials, clearSchoolCookies: { schoolClears += 1 })
        #expect(restored.hasCachedSession && restored.fakeCookie == "renewed-cookie" && restored.currentPassword == "school-password")
        login.logout()
        #expect(!login.hasCachedSession && reopened.fakeCookie.isEmpty && reopened.currentPassword.isEmpty && schoolClears == 1)
        #expect(model.screenState == .signedOut)
    }
}
