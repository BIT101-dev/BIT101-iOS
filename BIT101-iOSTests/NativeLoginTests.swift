import ClientCore
import Foundation
import Testing
import TransportCore
@testable import BIT101_iOS

@Suite(.serialized)
struct NativeLoginTests {
    private final class Credentials: LoginCredentialsStoring {
        var values: [String: String] = [:]
        func read(account: String) throws -> String { values[account] ?? "" }
        func save(_ value: String, account: String) throws { values[account] = value }
        func delete(account: String) -> Bool { values.removeValue(forKey: account); return true }
    }
    private final class Transport: HTTPTransport {
        var requests: [URLRequest] = []
        var loginRejections = 0
        var serverFailure = false
        var registrationFailure = false
        var unexpectedCASResponseURL = false
        var schoolFailureStatus: Int?
        var schoolPasswordRejections = 0
        var identityPasswordRejections = 0
        var rejectedSchoolStatus = 200
        var serviceTicket = false
        var sessionActivations = 0
        var holdCAS = false
        var pendingCAS: CheckedContinuation<Void, Never>?
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let url = try #require(request.url)
            if holdCAS, url.path == "/cas/login", request.httpMethod == "GET" {
                await withCheckedContinuation { pendingCAS = $0 }
            }
            var status = 200
            var headers: [String: String] = [:]
            let text: String
            switch url.path {
            case "/user/login":
                if serverFailure { status = 500; text = #"{"msg":"database unavailable"}"# }
                else if loginRejections > 0 {
                    loginRejections -= 1; status = 500; text = #"{"msg":"用户名或密码错误Orz"}"#
                } else { text = #"{"fake_cookie":"direct-cookie"}"# }
            case "/user/check": status = 401; text = ""
            case "/user/webvpn_verify_init": text = #"{"captcha":"","cookie":"fixture","execution":"fixture","salt":"MTIzNDU2Nzg5MDEyMzQ1Ng=="}"#
            case "/user/webvpn_verify":
                if identityPasswordRejections > 0 {
                    identityPasswordRejections -= 1; status = 401; text = #"{"msg":"用户名或密码错误"}"#
                } else { text = #"{"token":"proof","code":"proof-code"}"# }
            case "/user/register":
                if registrationFailure { status = 503; text = #"{"msg":"database unavailable"}"# }
                else { text = #"{"fake_cookie":"proof-cookie"}"# }
            case "/cas/login":
                if request.httpMethod == "POST", let failure = schoolFailureStatus {
                    status = failure; text = failure == 200 ? "对不起，无权访问该资源" : "school unavailable"
                } else if request.httpMethod == "POST", schoolPasswordRejections > 0 {
                    schoolPasswordRejections -= 1; status = rejectedSchoolStatus; text = "<p id='login-error-code'>1030027</p>"
                } else if request.httpMethod == "POST", serviceTicket {
                    if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "service" })?.value?.isEmpty == false {
                        status = 302; headers["Location"] = "https://webvpn.bit.edu.cn/login?cas_login=true&ticket=fixture"; text = ""
                    } else { text = "cas-success" }
                } else if request.httpMethod == "POST" {
                    text = "cas-success"
                } else { text = #"<form method="post"><p id="login-croypto">MTIzNDU2Nzg5MDEyMzQ1Ng==</p><p id="login-page-flowkey">flow</p></form>"# }
            case "/ustc-rba-front/fp": text = #"{"responsetoken":"risk-token"}"#
            default: throw URLError(.badURL)
            }
            let responseURL = unexpectedCASResponseURL && url.path == "/cas/login" && request.httpMethod == "POST"
                ? AppURL.required("https://outside.invalid/login") : url
            return (Data(text.utf8), try #require(HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: headers)))
        }
    }

    private func fixture(_ action: (LoginStorage, Transport, LoginService, Credentials, () -> Int) async throws -> Void) async throws {
        let domain = "BIT101Tests.native-login"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = Credentials(), transport = Transport()
        var prompts = 0
        let storage = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {}, requestSchoolPassword: { _ in
            prompts += 1; return "school-B"
        })
        let client = HTTPClient(transport: transport, observer: nil)
        try await action(storage, transport, LoginService(storage: storage,
            apiClient: BIT101APIClient(httpClient: client, noRedirectHTTPClient: client), verifySchoolIdentity: { account, password in
                try await AppNativeSchoolAuthentication.verifyIdentity(studentID: account, password: password,
                    state: AppSchoolSession.isolatedState(), transport: transport,
                    activateSession: { _ in transport.sessionActivations += 1 })
            }), backend, { prompts })
    }

    @Test(.timeLimit(.minutes(1))) func directLoginKeepsSeparateSchoolPassword() async throws {
        try await fixture { storage, transport, service, _, prompts in
            try storage.saveLoginState(studentID: "owner", password: "school-B", fakeCookie: "old-cookie")
            #expect(try await service.login(studentID: "owner", password: "community-A") == "owner")
            #expect(storage.currentPassword == "school-B" && prompts() == 0)
            #expect(try storage.loadCommunityPasswordDigest() == LoginCrypto.md5Hex("community-A"))
            #expect(transport.requests.compactMap { $0.url?.path } == ["/user/login"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func matchingPasswordsAuthenticateSchoolServicesWithoutPrompting() async throws {
        try await fixture { storage, transport, service, _, prompts in
            _ = try await service.login(studentID: "owner", password: "community-A")
            #expect(storage.hasCachedSession && storage.currentPassword == "community-A" && prompts() == 0)
            #expect(try await service.restoreSchoolSessionIfNeeded() == "owner")
            #expect(storage.currentPassword == "community-A" && prompts() == 0)
            #expect(transport.requests.compactMap { $0.url?.path } == ["/user/login", "/cas/login", "/cas/login"])
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [200, 401, 403]) func differentPasswordsAskForSchoolPasswordAfterExplicitRejection(status: Int) async throws {
        try await fixture { storage, transport, service, _, prompts in
            _ = try await service.login(studentID: "owner", password: "community-A")
            transport.schoolPasswordRejections = 1
            transport.rejectedSchoolStatus = status
            #expect(try await service.restoreSchoolSessionIfNeeded() == "owner")
            #expect(storage.currentPassword == "school-B" && prompts() == 1)
            #expect(storage.fakeCookie == "direct-cookie")
            #expect(try storage.loadCommunityPasswordDigest() == LoginCrypto.md5Hex("community-A"))
            #expect(transport.requests.compactMap { $0.url?.path } == ["/user/login", "/cas/login", "/cas/login", "/cas/login", "/cas/login"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func mergedCredentialFailureUsesIdentityProofAndPreservesExisting101Password() async throws {
        try await fixture { storage, transport, service, _, prompts in
            transport.loginRejections = 2
            #expect(try await service.login(studentID: "owner", password: "community-A") == "owner")
            #expect(storage.fakeCookie == "proof-cookie" && storage.currentPassword == "community-A" && prompts() == 0)
            #expect(try storage.loadCommunityPasswordDigest() == nil)
            let request = try #require(transport.requests.first { $0.url?.path == "/user/register" })
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["login_mode"] as? Bool == true && body["password"] as? String == LoginCrypto.md5Hex("community-A"))
        }
    }

    @Test(.timeLimit(.minutes(1))) func newAccountStoresValidatedCommunityDigestAfterIdentityProof() async throws {
        try await fixture { storage, transport, service, _, prompts in
            transport.loginRejections = 1
            _ = try await service.login(studentID: "owner", password: "community-A")
            #expect(storage.fakeCookie == "direct-cookie" && storage.currentPassword == "community-A" && prompts() == 0)
            #expect(try storage.loadCommunityPasswordDigest() == LoginCrypto.md5Hex("community-A"))
        }
    }

    @Test(.timeLimit(.minutes(1))) func communityServerFailurePreservesExistingLocalAccountAndAvoidsSchoolDetour() async throws {
        try await fixture { storage, transport, service, _, prompts in
            try storage.saveLoginState(studentID: "owner", password: "school-B", fakeCookie: "cached-cookie")
            transport.serverFailure = true
            await #expect(throws: (any Error).self) { try await service.login(studentID: "owner", password: "community-A") }
            #expect(storage.fakeCookie == "cached-cookie" && storage.hasCachedSession && prompts() == 0)
            #expect(transport.requests.compactMap { $0.url?.path } == ["/user/login"])
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func freshLoginUsesVerifiedSchoolIdentityDuringACommunityOutage(registrationOnly: Bool) async throws {
        try await fixture { storage, transport, service, backend, prompts in
            transport.serverFailure = !registrationOnly; transport.serviceTicket = true
            if registrationOnly { transport.loginRejections = 1; transport.registrationFailure = true }
            #expect(try await service.login(studentID: "owner", password: "community-A") == "owner")
            #expect(storage.hasCachedSession && storage.fakeCookie.isEmpty && storage.currentPassword == "community-A")
            #expect(try storage.loadCommunityPasswordDigest() == nil)
            #expect(prompts() == 0 && transport.sessionActivations == 1)
            let expected = registrationOnly ? ["/user/login", "/user/webvpn_verify_init", "/user/webvpn_verify", "/user/register", "/cas/login", "/cas/login"]
                : ["/user/login", "/cas/login", "/cas/login"]
            #expect(transport.requests.compactMap { $0.url?.path } == expected)
            let defaults = try #require(UserDefaults(suiteName: "BIT101Tests.native-login"))
            let reopened = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
            #expect(reopened.hasCachedSession && reopened.currentStudentID == "owner" && reopened.fakeCookie.isEmpty)
            let reopenedService = LoginService(storage: reopened,
                apiClient: BIT101APIClient(httpClient: HTTPClient(transport: transport, observer: nil),
                    noRedirectHTTPClient: HTTPClient(transport: transport, observer: nil)))
            let model = LoginViewModel(service: reopenedService)
            await model.bootstrapIfNeeded()
            #expect(model.screenState == .signedIn(studentID: "owner"))
            #expect(AppRestoreReadiness.sessionIsReady(model.screenState, storage: reopened))
            #expect(!AppRestoreReadiness.sessionIsReady(.signedOut, storage: reopened))
            transport.serverFailure = false; transport.registrationFailure = false
            #expect(try await reopenedService.checkLogin() == "owner")
            #expect(reopened.fakeCookie == "direct-cookie" && !reopened.hasVerifiedSchoolIdentity)
            reopened.clearSession()
            #expect(!reopened.hasCachedSession && reopened.currentPassword.isEmpty)
            #expect(!LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {}).hasCachedSession)
        }
    }

    @Test(.timeLimit(.minutes(1))) func failedSchoolProofKeepsTheFreshAccountSignedOut() async throws {
        try await fixture { storage, transport, service, _, prompts in
            transport.serverFailure = true; transport.schoolPasswordRejections = 2
            await #expect(throws: LoginServiceError.self) { try await service.login(studentID: "owner", password: "community-A") }
            #expect(!storage.hasCachedSession && storage.currentStudentID.isEmpty && storage.fakeCookie.isEmpty)
            #expect(prompts() == 1 && transport.sessionActivations == 0)
        }
    }

    @Test(.timeLimit(.minutes(1))) func freshLoginRejectsAnUnexpectedSchoolResponseOrigin() async throws {
        try await fixture { storage, transport, service, _, prompts in
            transport.serverFailure = true; transport.serviceTicket = true; transport.unexpectedCASResponseURL = true
            await #expect(throws: NativeSchoolAuthenticationError.self) { try await service.login(studentID: "owner", password: "community-A") }
            #expect(!storage.hasCachedSession && transport.sessionActivations == 0 && prompts() == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["native", "community", "registration-outage"])
    func schoolPasswordPromptFollowsOneExplicitRejection(route: String) async throws {
        try await fixture { storage, transport, service, _, prompts in
            let native = route == "native"
            if native {
                transport.serverFailure = true; transport.serviceTicket = true; transport.schoolPasswordRejections = 1
            } else {
                transport.loginRejections = 1; transport.identityPasswordRejections = 1
                if route == "registration-outage" { transport.registrationFailure = true; transport.serviceTicket = true }
            }
            #expect(try await service.login(studentID: "owner", password: "community-A") == "owner")
            #expect(storage.currentPassword == "school-B" && prompts() == 1)
            let path = native ? "/cas/login" : "/user/webvpn_verify"
            let attempts = transport.requests.filter { $0.url?.path == path && $0.httpMethod == "POST" }
            #expect(attempts.count == 2)
            for (request, password) in zip(attempts, ["community-A", "school-B"]) {
                let data = try #require(request.httpBody)
                let encrypted: String?
                if native {
                    encrypted = URLComponents(string: "https://fixture.invalid?" + String(decoding: data, as: UTF8.self))?
                        .queryItems?.first { $0.name == "password" }?.value
                } else { encrypted = (try JSONSerialization.jsonObject(with: data) as? [String: String])?["password"] }
                #expect(encrypted == (try LoginCrypto.encryptPassword(password, saltBase64: "MTIzNDU2Nzg5MDEyMzQ1Ng==")))
            }
            if route == "registration-outage" {
                let nativePost = try #require(transport.requests.last { $0.url?.path == "/cas/login" && $0.httpMethod == "POST" })
                let body = String(decoding: try #require(nativePost.httpBody), as: UTF8.self)
                let fields = URLComponents(string: "https://fixture.invalid?" + body)?.queryItems ?? []
                #expect(fields.first { $0.name == "password" }?.value == (try LoginCrypto.encryptPassword("school-B", saltBase64: "MTIzNDU2Nzg5MDEyMzQ1Ng==")))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [200, 403, 503])
    func independentLoginPreservesKnownSchoolFailureAttribution(status: Int) async throws {
        try await fixture { storage, transport, service, _, prompts in
            transport.serverFailure = true; transport.schoolFailureStatus = status
            do {
                _ = try await service.login(studentID: "owner", password: "community-A")
                Issue.record("学校拒绝访问时应保留错误来源。")
            } catch {
                #expect(SchoolServiceFailure.from(error) == (status == 503 ? .unavailable : .accessDenied))
            }
            #expect(!storage.hasCachedSession && transport.sessionActivations == 0 && prompts() == 0)
        }
    }

    @Test(.timeLimit(.minutes(1))) func accountChangeCancelsTheIndependentSchoolProof() async throws {
        try await fixture { storage, transport, service, _, _ in
            transport.serverFailure = true; transport.serviceTicket = true; transport.holdCAS = true
            let login = Task { try await service.login(studentID: "owner", password: "community-A") }
            defer { login.cancel(); transport.pendingCAS?.resume(); transport.pendingCAS = nil }
            try await waitForTestEvent { transport.pendingCAS != nil }
            storage.clearSession()
            transport.pendingCAS?.resume(); transport.pendingCAS = nil
            await #expect(throws: CancellationError.self) { try await login.value }
            #expect(!storage.hasCachedSession && transport.sessionActivations == 0)
        }
    }

    @Test(.timeLimit(.minutes(1))) func legacyKeychainSessionMigratesCommunityCredentialThroughDirectLogin() async throws {
        try await fixture { storage, transport, service, _, prompts in
            try storage.saveLoginState(studentID: "owner", password: "legacy-password", fakeCookie: "old-cookie")
            #expect(try await service.checkLogin() == "owner")
            #expect(try storage.loadCommunityPasswordDigest() == LoginCrypto.md5Hex("legacy-password"))
            #expect(storage.currentPassword == "legacy-password" && prompts() == 0)
            #expect(transport.requests.compactMap { $0.url?.path } == ["/user/check", "/user/login"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func explicitSchoolPasswordRejectionRequestsOneReplacementAndKeepsCommunitySession() async throws {
        try await fixture { storage, transport, service, _, prompts in
            try storage.saveLoginState(studentID: "owner", password: "old-B", fakeCookie: "community-cookie",
                communityPasswordDigest: LoginCrypto.md5Hex("community-A"))
            transport.schoolPasswordRejections = 1
            #expect(try await service.restoreSchoolSessionIfNeeded() == "owner")
            #expect(prompts() == 1 && storage.currentPassword == "school-B" && storage.fakeCookie == "community-cookie")
            #expect(transport.requests.count == 4)
            #expect(try storage.loadCommunityPasswordDigest() == LoginCrypto.md5Hex("community-A"))
        }
    }

    @Test(.timeLimit(.minutes(1))) func localCASServiceSubmissionUsesSchoolPasswordAndTheCurrentRiskToken() async throws {
        try await fixture { storage, transport, _, _, prompts in
            try storage.saveLoginState(studentID: "owner", password: "school-B", fakeCookie: "community-cookie",
                communityPasswordDigest: LoginCrypto.md5Hex("community-A"))
            transport.serviceTicket = true
            let client = HTTPClient(transport: transport, observer: nil)
            let api = BIT101APIClient(httpClient: client, noRedirectHTTPClient: client)
            let html = #"<p id="login-croypto">MTIzNDU2Nzg5MDEyMzQ1Ng==</p><p id="login-page-flowkey">flow</p><p id="riskSystemSwitch">USTC</p>"#
            let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
            let next = try await api.submitSchoolServiceLogin(url: AppURL.required("https://sso.bit.edu.cn/cas/login?service=fixture"),
                html: html, storage: storage, cookieStorage: cookies)
            #expect(next.host == "webvpn.bit.edu.cn" && prompts() == 0)
            #expect(transport.requests.compactMap { $0.url?.path } == ["/ustc-rba-front/fp", "/cas/login"])
            let post = try #require(transport.requests.last)
            #expect(post.url?.query == "service=fixture")
            let body = String(decoding: try #require(post.httpBody), as: UTF8.self)
            let fields = URLComponents(string: "https://fixture.invalid?" + body)?.queryItems ?? []
            #expect(fields.first { $0.name == "password" }?.value == (try LoginCrypto.encryptPassword("school-B", saltBase64: "MTIzNDU2Nzg5MDEyMzQ1Ng==")))
            #expect(fields.first { $0.name == "riskEngine" }?.value == "true")
            #expect(fields.first { $0.name == "risk_payload" }?.value?.isEmpty == false)
            #expect(storage.fakeCookie == "community-cookie" && storage.currentPassword == "school-B")
        }
    }
}
