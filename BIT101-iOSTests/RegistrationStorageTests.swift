import ClientCore
import CommunityTransport
import Foundation
import Testing
import TransportCore

@testable import BIT101_iOS

extension LoginStorageTests {
    private final class RegistrationResponses: HTTPTransport {
        var requests: [(String, [String: Any])] = []
        var registerStatus = 200
        var registerFailure: (any Error)?
        var registerBody: String?
        var loginStatus = 200
        var captcha = ""
        var beforeResponse: (() async -> Void)?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let payload =
                try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
                ?? [:]
            requests.append((url.path, payload))
            await beforeResponse?()
            let body: String
            switch url.path {
            case "/user/mail_verify": body = #"{"token":"mail-proof"}"#
            case "/user/webvpn_verify_init":
                body =
                    #"""
                    {"salt":"AAAAAAAAAAAAAAAAAAAAAA==","cookie":"fixture","execution":"fixture\#
                    ","captcha":""}
                    """#
                    .replacingOccurrences(of: #""captcha":"""#, with: #""captcha":"\#(captcha)""#)
            case "/user/webvpn_verify": body = #"{"token":"school-proof","code":"123456"}"#
            case "/user/register":
                if let registerFailure { throw registerFailure }
                body = registerBody ?? #"{"fake_cookie":"registered-cookie"}"#
            case "/user/login":
                body =
                    loginStatus == 200
                    ? #"{"fake_cookie":"registered-cookie"}"# : #"{"msg":"用户名或密码错误Orz"}"#
            default: throw URLError(.unsupportedURL)
            }
            return (
                Data(body.utf8),
                try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: url.path == "/user/register"
                            ? registerStatus : url.path == "/user/login" ? loginStatus : 200,
                        httpVersion: nil, headerFields: nil))
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func schoolLogin() async throws {
        let domain = "BIT101Tests.school-captcha"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(
            defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in },
            requestSchoolPassword: { _ in "school-password" })
        let transport = RegistrationResponses()
        let http = HTTPClient(transport: transport, observer: nil)
        transport.loginStatus = 500
        transport.captcha = "data:image/png;base64,fixture"
        let service = LoginService(
            storage: storage,
            apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        for registration in [false, true] {
            do {
                if registration {
                    _ = try await service.verifyRegistration(studentID: "A", password: "fixture")
                } else {
                    _ = try await service.login(studentID: "A", password: "fixture")
                }
                Issue.record("Captcha requires an actionable authentication response")
            } catch LoginServiceError.schoolCaptchaRequired {
                #expect(
                    LoginServiceError.schoolCaptchaRequired.localizedDescription.contains("校园邮箱"))
            }
        }
        #expect(
            transport.requests.map(\.0) == [
                "/user/login", "/user/webvpn_verify_init", "/user/webvpn_verify_init",
            ])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [RegistrationVerificationMethod.school, .email])
    func registrationAndResetUseVerifiedIdentity(method: RegistrationVerificationMethod)
        async throws
    {
        let defaults = try #require(UserDefaults(suiteName: "BIT101Tests.registration"))
        defer { defaults.removePersistentDomain(forName: "BIT101Tests.registration") }
        let credentials = Credentials()
        let storage = LoginStorage(
            defaults: defaults, credentials: credentials, clearSchoolCookies: { _ in })
        let transport = RegistrationResponses()
        let http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(
            storage: storage,
            apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        let model = AccountRegistrationViewModel(studentID: " 1120260001 ", service: service)
        model.password = "community-password"
        model.confirmation = model.password
        model.method = method
        model.schoolPassword = "school-password"
        #expect(model.canVerify && !model.canSubmit)
        await model.verify()
        if method == .email {
            #expect(model.resendAt > Date() && !model.canSubmit)
            await model.verify()
            #expect(transport.requests.count == 1)
            model.code = "１２３４５６"
            #expect(!model.canSubmit)
            model.code = "123456"
        } else {
            #expect(model.verified)
        }
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
        #expect(
            request.1["token"] as? String == (method == .school ? "school-proof" : "mail-proof"))
        #expect(request.1["code"] as? String == "123456")
        #expect(
            storage.currentStudentID == "1120260001" && storage.fakeCookie == "registered-cookie")
        #expect(
            storage.currentPassword
                == (method == .school ? "school-password" : "community-password"))
        #expect(
            try storage.loadCredentials()?.password
                == (method == .school ? "school-password" : "community-password"))
        let reopened = LoginStorage(
            defaults: defaults, credentials: credentials, clearSchoolCookies: { _ in })
        #expect(try reopened.loadCommunityDigest() == LoginCrypto.md5Hex("community-password"))
        let reopenedService = LoginService(
            storage: reopened,
            apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        try await reopenedService.renewCommunitySession(observed: reopened.communityCredentials)
        #expect(transport.requests.last?.0 == "/user/login")
        #expect(
            transport.requests.last?.1["password"] as? String
                == LoginCrypto.md5Hex("community-password"))
        reopened.clearSession()
        #expect(try reopened.loadCommunityDigest() == nil && reopened.loadCredentials() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func communityLoginPreservesSchoolCredentials() async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101Tests.community-password"))
        defer { defaults.removePersistentDomain(forName: "BIT101Tests.community-password") }
        let storage = LoginStorage(
            defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in })
        try storage.saveLoginState(
            studentID: "A", password: "school-password", fakeCookie: "old-cookie",
            communityPasswordDigest: LoginCrypto.md5Hex("old-community-password"))
        let transport = RegistrationResponses()
        let http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(
            storage: storage,
            apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        _ = try await service.login(studentID: "A", password: "community-password")
        #expect(storage.currentPassword == "school-password")
        #expect(try storage.loadCommunityDigest() == LoginCrypto.md5Hex("community-password"))
        _ = try await service.login(studentID: "B", password: "another-password")
        #expect(storage.currentPassword == "another-password" && storage.currentStudentID == "B")
        #expect(try storage.loadCommunityDigest() == LoginCrypto.md5Hex("another-password"))
        #expect(transport.requests.map(\.0) == ["/user/login", "/user/login"])
    }

    @Test(.timeLimit(.minutes(1)))
    func registrationProofsFollowTheirAccount() async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101Tests.registration-proof"))
        defer { defaults.removePersistentDomain(forName: "BIT101Tests.registration-proof") }
        let storage = LoginStorage(
            defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in })
        let transport = RegistrationResponses()
        let http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(
            storage: storage,
            apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        let model = AccountRegistrationViewModel(studentID: "A", service: service)
        model.password = "community-password"
        model.confirmation = model.password
        model.schoolPassword = "school-password"
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
        try await waitForTestEvent { pending != nil }
        model.studentID = "C"
        pending?.resume()
        await operation.value
        model.code = "123456"
        #expect(!model.canSubmit && model.alert == nil)
    }

    @Test(
        .serialized, .timeLimit(.minutes(1)),
        arguments: [
            "lost", "malformed", "unconfirmed", "unsent", "rejected", "cancelled", "storage",
        ])
    func registrationConfirmsLostPreservesRecovery(scenario: String) async throws {
        let domain = "BIT101Tests.registration-outcome"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let credentials = Credentials()
        let storage = LoginStorage(
            defaults: defaults, credentials: credentials, clearSchoolCookies: { _ in })
        let transport = RegistrationResponses()
        let http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(
            storage: storage,
            apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        let model = AccountRegistrationViewModel(studentID: "A", service: service)
        model.method = .email
        model.password = "community-password"
        model.confirmation = model.password
        await model.verify()
        model.code = "123456"
        if ["lost", "unconfirmed"].contains(scenario) {
            transport.registerFailure = URLError(.networkConnectionLost)
        }
        if scenario == "malformed" { transport.registerBody = #"{"fake_cookie":" "}"# }
        if scenario == "unconfirmed" { transport.loginStatus = 401 }
        if scenario == "unsent" {
            transport.registerFailure = HTTPRequestNotSent(
                underlying: URLError(.cannotConnectToHost))
        }
        if scenario == "cancelled" { transport.registerFailure = URLError(.cancelled) }
        if scenario == "rejected" { transport.registerStatus = 400 }
        if scenario == "storage" { credentials.failsWrites = true }
        await model.submit()
        #expect(transport.requests.filter { $0.0 == "/user/register" }.count == 1)
        let confirms = ["lost", "malformed", "unconfirmed"].contains(scenario)
        #expect(transport.requests.filter { $0.0 == "/user/login" }.count == (confirms ? 1 : 0))
        if ["lost", "malformed"].contains(scenario) {
            #expect(
                model.alert == nil && storage.fakeCookie == "registered-cookie"
                    && model.password.isEmpty)
        } else {
            #expect(storage.fakeCookie.isEmpty && model.password == "community-password")
            let pending = ["unconfirmed", "cancelled", "storage"].contains(scenario)
            #expect(model.canSubmit == !pending)
            if pending {
                #expect(model.alert?.title == (scenario == "storage" ? "注册或重置已完成" : "注册或重置结果待确认"))
                #expect(model.alert?.message.contains("刚设置的新密码登录") == true && model.code.isEmpty)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func failedOrSupersededRegistrationKeepsSession(superseded: Bool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101Tests.registration-session"))
        defer { defaults.removePersistentDomain(forName: "BIT101Tests.registration-session") }
        let storage = LoginStorage(
            defaults: defaults, credentials: Credentials(), clearSchoolCookies: { _ in })
        try storage.saveLoginState(studentID: "A", password: "school", fakeCookie: "old-cookie")
        let transport = RegistrationResponses()
        let http = HTTPClient(transport: transport, observer: nil)
        let service = LoginService(
            storage: storage,
            apiClient: BIT101APIClient(httpClient: http, noRedirectHTTPClient: http))
        if superseded {
            transport.beforeResponse = {
                try? storage.saveLoginState(
                    studentID: "B", password: "school-B", fakeCookie: "new-cookie")
            }
        } else {
            transport.registerStatus = 400
        }
        do {
            try await service.registerAccount(
                studentID: "A", password: "community-password", token: "proof", code: "123456",
                schoolPassword: nil)
            Issue.record("A failed or superseded response must preserve the active session")
        } catch { #expect(TaskCancellation.matches(error) == superseded) }
        #expect(storage.fakeCookie == (superseded ? "new-cookie" : "old-cookie"))
        #expect(try storage.loadCommunityDigest() == nil)
    }
}
