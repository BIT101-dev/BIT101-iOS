import ClientCore
import BIT101TestSupport
import Foundation
import Testing
import TransportCore
import ScheduleInfrastructure

@MainActor
struct NativeSchoolAuthenticationTests {
    @Test(.timeLimit(.minutes(1))) func identityVerificationStopsAtTheIssuedTicket() async throws {
        let credentials = Credentials(), restorer = Restorer()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let transport = Transport { request in
            #expect(request.url?.host == "sso.bit.edu.cn")
            return (200, [:], #"<span id="login-croypto">salt</span><span id="login-page-flowkey">flow</span>"#)
        }
        var passwordSubmissions = 0
        let authenticator = NativeSchoolAuthenticator(credentials: credentials, restorer: restorer,
            client: HTTPClient(transport: transport, observer: nil), cookies: { cookies }, secondFactor: { _ in },
            serviceLogin: { _, _ in
                passwordSubmissions += 1
                return AppURL.required("https://webvpn.bit.edu.cn/login?cas_login=true&ticket=fixture")
            })
        try await authenticator.verifyIdentity()
        #expect(passwordSubmissions == 1 && restorer.calls == 0 && transport.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func identityVerificationRequiresAnExplicitCredentialSubmission() async throws {
        let credentials = Credentials(), restorer = Restorer()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let transport = Transport { _ in (302, ["Location": "https://webvpn.bit.edu.cn/login?cas_login=true&ticket=old"], "") }
        let authenticator = NativeSchoolAuthenticator(credentials: credentials, restorer: restorer,
            client: HTTPClient(transport: transport, observer: nil), cookies: { cookies }, secondFactor: { _ in })
        await #expect(throws: NativeSchoolAuthenticationError.self) { try await authenticator.verifyIdentity() }
        #expect(restorer.calls == 0 && transport.requests.count == 1)
    }

    @Test(arguments: ["http://webvpn.bit.edu.cn/login?cas_login=true&ticket=a", "https://webvpn.bit.edu.cn/login?ticket=a",
        "https://webvpn.bit.edu.cn/login?cas_login=true&ticket=a&ticket=b", "https://webvpn.bit.edu.cn/login?cas_login=true&ticket=",
        "https://webvpn.bit.edu.cn/login?cas_login=true&ticket=a#fragment", "https://sso.bit.edu.cn/cas/login?cas_login=true&ticket=a"])
    func identityTicketsRequireTheDeclaredServiceCallback(address: String) {
        #expect(!NativeSchoolAuthenticator.isIdentityServiceTicket(AppURL.required(address)))
    }

    private final class Credentials: SchoolCredentialsProviding {
        var generation = 0
        let currentStudentID = "owner"
        let currentPassword = "school-password"
        var schoolSessionIdentity: SchoolSessionIdentity { .init(accountIdentifier: currentStudentID, generation: generation) }
    }
    private final class Restorer: SchoolSessionRestoring {
        var calls = 0
        func restoreSchoolSessionIfNeeded() async throws -> String? { calls += 1; return "owner" }
    }
    private final class Transport: HTTPTransport {
        var requests: [URLRequest] = []
        let handler: (URLRequest) throws -> (Int, [String: String], String)
        init(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], String)) { self.handler = handler }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let (status, headers, body) = try handler(request)
            let url = try #require(request.url)
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)))
        }
    }

    @Test func FoundationTransportErrorsPermitSchoolRouteRecovery() {
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
            userInfo: [NSLocalizedDescriptionKey: "fixture DNS failure"])
        #expect(NativeSchoolAuthenticator.permitsFallback(failure))
        #expect(NativeSchoolAuthenticator.permitsFallback(HTTPRequestNotSent(underlying: failure)))
        #expect(!NativeSchoolAuthenticator.permitsFallback(HTTPRequestNotSent(underlying: URLError(.cancelled))))
    }

    @Test(.timeLimit(.minutes(1))) func localTicketsFollowSchoolRedirectsWithHTTPSUpgrade() async throws {
        let credentials = Credentials(), restorer = Restorer()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let transport = Transport { request in
            if request.url?.host == "sso.bit.edu.cn" { return (302, ["Location": "http://jwms.bit.edu.cn/?ticket=fixture"], "") }
            return (200, [:], "school landing")
        }
        let authenticator = NativeSchoolAuthenticator(credentials: credentials, restorer: restorer,
            client: HTTPClient(transport: transport, observer: nil), cookies: { cookies }, secondFactor: { _ in Issue.record("unexpected SMS") })
        let session = try await authenticator.authenticate(.grades)
        #expect(session.baseURL == SchoolServiceTarget.grades.baseURL && session.owner == credentials.schoolSessionIdentity)
        #expect(restorer.calls == 1 && transport.requests.count == 2)
        #expect(transport.requests.allSatisfy { $0.url?.scheme == "https" && $0.url?.host?.hasSuffix(".bit.edu.cn") == true })
        #expect(transport.requests.last?.url?.query == "ticket=fixture")
    }

    @Test(.timeLimit(.minutes(1))) func teachingCenterLandingUsesTheRequestedTimetableApplication() async throws {
        let credentials = Credentials(), restorer = Restorer()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let transport = Transport { request in
            let url = try #require(request.url)
            if url.host == "jxzxehall.bit.edu.cn" {
                let service = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "service" }?.value
                guard service?.contains("/wdkbby/") == true else { return (403, [:], "无权访问该资源") }
                return (302, ["Location": try #require(service)], "")
            }
            return (200, [:], "timetable landing")
        }
        let authenticator = NativeSchoolAuthenticator(credentials: credentials, restorer: restorer,
            client: HTTPClient(transport: transport, observer: nil), cookies: { cookies }, secondFactor: { _ in })
        let session = try await authenticator.authenticate(.teachingCenter)
        #expect(session.baseURL == SchoolServiceTarget.teachingCenter.baseURL)
        #expect(transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func transcriptCookiesStayScopedToTheTranscriptPath() async throws {
        let credentials = Credentials(), restorer = Restorer()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        for (domain, path, name) in [("jwb.bit.edu.cn", "/cjd", "report"), ("sso.bit.edu.cn", "/", "cas"), ("jwb.bit.edu.cn", "/other", "other")] {
            cookies.setCookie(try #require(HTTPCookie(properties: [.domain: domain, .path: path, .name: name, .value: "fixture", .secure: "TRUE"])))
        }
        let transport = Transport { _ in (200, [:], "report landing") }
        let authenticator = NativeSchoolAuthenticator(credentials: credentials, restorer: restorer,
            client: HTTPClient(transport: transport, observer: nil), cookies: { cookies }, secondFactor: { _ in })
        let session = try await authenticator.authenticate(.transcript)
        #expect(session.cookieHeader == "report=fixture")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["https://outside.invalid/?ticket=fixture", "https://jxzxehallapp.bit.edu.cn:444/", "https://user:password@sso.bit.edu.cn/"])
    func redirectsRespectSchoolOriginAndCredentialBoundaries(location: String) async throws {
        let credentials = Credentials(), restorer = Restorer()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let transport = Transport { _ in (302, ["Location": location], "") }
        let authenticator = NativeSchoolAuthenticator(credentials: credentials, restorer: restorer,
            client: HTTPClient(transport: transport, observer: nil), cookies: { cookies }, secondFactor: { _ in })
        await #expect(throws: NativeSchoolAuthenticationError.self) { try await authenticator.authenticate(.transcript) }
        #expect(transport.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func accountChangesCancelLocalAuthenticationBeforeFollowingTickets() async throws {
        let credentials = Credentials(), restorer = Restorer()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let transport = Transport { _ in
            credentials.generation += 1
            return (302, ["Location": "https://jwms.bit.edu.cn/?ticket=fixture"], "")
        }
        let authenticator = NativeSchoolAuthenticator(credentials: credentials, restorer: restorer,
            client: HTTPClient(transport: transport, observer: nil), cookies: { cookies }, secondFactor: { _ in })
        await #expect(throws: CancellationError.self) { try await authenticator.authenticate(.grades) }
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: ["1030027", "1030031", "1030028", "risk=ustc-token", ""])
    func explicitPasswordRejectionUsesCASCode(code: String) {
        #expect(SchoolLoginHTMLParser.rejectsPassword(html: "<p id='login-error-code'>\(code)</p>")
            == ["1030027", "1030031"].contains(code))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["wengine_vpn_ticket", "wengine_vpn_ticketwebvpn_bit_edu_cn"])
    func localWebVPNRegistersFingerprintBeforeServiceTicketCallback(cookieName: String) async throws {
        let credentials = Credentials(), restorer = Restorer()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let transport = Transport { request in
            let url = try #require(request.url)
            if url.path == "/set-fingerprint" { return (302, ["Location": "/login"], "") }
            if url.host == "sso.bit.edu.cn" {
                return (302, ["Location": "https://webvpn.bit.edu.cn/login?cas_login=true&ticket=fixture"], "")
            }
            cookies.setCookie(try #require(HTTPCookie(properties: [.domain: "webvpn.bit.edu.cn", .path: "/",
                .name: cookieName, .value: "fixture", .secure: "TRUE"])))
            return (200, [:], "VPN landing")
        }
        let authenticator = NativeSchoolAuthenticator(credentials: credentials, restorer: restorer,
            client: HTTPClient(transport: transport, observer: nil), cookies: { cookies }, secondFactor: { _ in })
        let session = try await authenticator.authenticate(.webVPN)
        #expect(session.cookieHeader.contains("\(cookieName)=fixture"))
        #expect(transport.requests.compactMap { $0.url?.path } == ["/set-fingerprint", "/cas/login", "/login"])
        let casURL = try #require(transport.requests[1].url)
        #expect(URLComponents(url: casURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "https://webvpn.bit.edu.cn/login?cas_login=true")
    }

    private final class DirectAuthenticator: SchoolServiceAuthenticating {
        let owner: SchoolSessionIdentity
        var calls = 0
        init(_ owner: SchoolSessionIdentity) { self.owner = owner }
        func authenticate(_ target: SchoolServiceTarget) async throws -> SchoolAuthenticatedSession {
            calls += 1
            return .init(baseURL: target.baseURL, cookieHeader: "", owner: owner)
        }
    }
    private struct Crypto: SchoolServiceCryptoProviding {
        let schoolURLCryptoPublicKey = "fixture"
        let browserUserAgent = "fixture"
        func schoolProtectedHeaders() -> [String: String] { [:] }
        func encryptSchoolURLCryptoBody(object: [String: String], publicKeyPEM: String) throws -> (body: String, encryptedKey: String, aesKey: Data) { ("", "", Data()) }
        func decryptSchoolURLCryptoResponse(_ data: Data, aesKey: Data) throws -> Data { data }
    }

    @Test(.timeLimit(.minutes(1))) func teachingCenterUsesNativeAuthenticationAndReusesItsPreparedRoute() async throws {
        let credentials = Credentials(), restorer = Restorer()
        let native = DirectAuthenticator(credentials.schoolSessionIdentity)
        let state = TeachingCenterSessionState(cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage))
        let transport = Transport { request in
            #expect(request.url?.host == "jxzxehallapp.bit.edu.cn")
            return (200, [:], request.url?.path.hasSuffix("xnxqcx.do") == true
                ? #"{"datas":{"xnxqcx":{"rows":[{"DM":"term"}]}}}"# : "{}")
        }
        let service = ScheduleService(credentials: credentials, crypto: Crypto(), schoolSessionRestorer: restorer,
            teachingCenterState: state, transport: transport, nativeAuthenticator: native)
        #expect(try await service.fetchAvailableTerms() == ["term"])
        #expect(try await service.fetchAvailableTerms() == ["term"])
        #expect(native.calls == 1 && restorer.calls == 0 && transport.requests.count == 4)
    }

    @Test func CASFormSubmissionRetainsFlowAndRespectsSameOrigin() throws {
        let url = AppURL.required("https://sso.bit.edu.cn/cas/login?service=fixture")
        for html in ["<form method='post'>", "<form action=''>", "<form action='  '>"] {
            #expect(SchoolLoginHTMLParser.loginFormAction(html: html, documentURL: url) == url)
        }
        #expect(SchoolLoginHTMLParser.loginFormAction(html: "<form action='login'>", documentURL: url)?.absoluteString == "https://sso.bit.edu.cn/cas/login")
        #expect(SchoolLoginHTMLParser.loginFormAction(html: "<form action='?service=a&amp;renew=true'>", documentURL: url)?.query == "service=a&renew=true")
        #expect(SchoolLoginHTMLParser.loginFormAction(html: "<form action='https://outside.invalid/'>", documentURL: url) == nil)
        #expect(SchoolLoginHTMLParser.loginFormAction(html: "<form method='post'>", documentURL: AppURL.required("http://sso.bit.edu.cn/cas/login")) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func schoolWebVPNFallbackMapsTeachingCenterPreflightAndCallback() async throws {
        let credentials = Credentials(), restorer = Restorer()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let transport = Transport { request in
            let url = try #require(request.url)
            if url.host == "jxzxehall.bit.edu.cn" { throw HTTPRequestNotSent(underlying: URLError(.cannotFindHost)) }
            if url.path == "/set-fingerprint" { return (302, ["Location": "/login"], "") }
            if url.host == "sso.bit.edu.cn" { return (302, ["Location": "https://webvpn.bit.edu.cn/login?ticket=fixture"], "") }
            if url.path == "/login" {
                cookies.setCookie(try #require(HTTPCookie(properties: [.domain: "webvpn.bit.edu.cn", .path: "/",
                    .name: "wengine_vpn_ticket", .value: "fixture", .secure: "TRUE"])))
            }
            if url.path.hasSuffix("/auth-protocol-core/login") {
                return (302, ["Location": "https://jxzxehallapp.bit.edu.cn/jwapp/?ticket=fixture"], "")
            }
            return (200, [:], "school landing")
        }
        let authenticator = NativeSchoolAuthenticator(credentials: credentials, restorer: restorer,
            client: HTTPClient(transport: transport, observer: nil), cookies: { cookies }, secondFactor: { _ in })
        let session = try await authenticator.authenticate(.teachingCenter)
        #expect(session.baseURL == SchoolServiceTarget.teachingCenter.webVPNBaseURL)
        #expect(transport.requests.count == 6)
        #expect(transport.requests[4].url?.host == "webvpn.bit.edu.cn")
        #expect(transport.requests[4].url?.path.hasSuffix("/auth-protocol-core/login") == true)
    }

    private final class SuspendedTransport: HTTPTransport {
        var pending: CheckedContinuation<Void, Never>?
        var requests = 0
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await data(for: request, maximumBytes: nil)
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            requests += 1
            if requests == 1 { await withCheckedContinuation { pending = $0 } }
            let url = try #require(request.url)
            return (Data("landing".utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1))) func concurrentSchoolServicesSerializeCASFlowsAndCancelQueuedRequests() async throws {
        let credentials = Credentials(), restorer = Restorer(), transport = SuspendedTransport()
        let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let authenticator = NativeSchoolAuthenticator(credentials: credentials, restorer: restorer,
            client: HTTPClient(transport: transport, observer: nil), cookies: { cookies }, secondFactor: { _ in })
        let first = Task { try await authenticator.authenticate(.transcript) }
        try await waitForTestEvent { transport.pending != nil }
        let second = Task { try await authenticator.authenticate(.transcript) }
        var secondStarted = false
        let cancelled = Task {
            secondStarted = true
            return try await authenticator.authenticate(.transcript)
        }
        try await waitForTestEvent { secondStarted }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(transport.requests == 1 && restorer.calls == 1)
        transport.pending?.resume()
        _ = try await first.value
        _ = try await second.value
        #expect(transport.requests == 2 && restorer.calls == 2)
    }
}
