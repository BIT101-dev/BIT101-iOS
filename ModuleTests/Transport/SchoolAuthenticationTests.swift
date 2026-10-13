import TransportCore
import ClientCore
import Foundation
import Testing

struct SchoolAuthenticationTests {
    @Test(arguments: [
        ("https://sso.bit.edu.cn", "https://sso.bit.edu.cn:443/cas/login", true),
        ("https://sso.bit.edu.cn:443", "https://sso.bit.edu.cn/cas/login", true),
        ("https://sso.bit.edu.cn", "https://sso.bit.edu.cn:444/cas/login", false),
        ("https://sso.bit.edu.cn", "http://sso.bit.edu.cn/cas/login", false),
        ("https://sso.bit.edu.cn", "https://user@sso.bit.edu.cn/cas/login", false)
    ])
    func schoolSecondFactorNormalizesTheDefaultSecurePort(fixture: (String, String, Bool)) throws {
        let (origin, action, valid) = fixture
        let html = "<form action=\"\(action)\"><input id=\"login-page-flowkey\" value=\"flow\"><input id=\"user-object-id\" value=\"user\"><div id=\"secondSmsLoginForm\"></div></form>"
        let context = SchoolLoginHTMLParser.parseSecondFactorPage(html: html, baseURL: AppURL.required(origin))
        if valid { #expect(try #require(context).formAction.absoluteString == action) }
        else { #expect(context == nil) }
    }

    @Test func schoolLoginParserBuildsSafeSecondFactorContext() throws {
        let html = #"""
        <form action="/cas/login">
          <input id="login-page-flowkey" value="flow-key">
          <input id="user-object-id" value="user-42">
          <div id="secondSmsLoginForm">短信验证</div>
        </form>
        """#
        let context = try #require(
            SchoolLoginHTMLParser.parseSecondFactorPage(
                html: html,
                baseURL: AppURL.required("https://sso.bit.edu.cn/cas/")
            )
        )

        #expect(context.execution == "flow-key")
        #expect(context.userObjectID == "user-42")
        #expect(context.formAction.absoluteString == "https://sso.bit.edu.cn/cas/login")
    }

    @Test(arguments: ["login", "?step=2", "", "https://evil.invalid/login"])
    func schoolSecondFactorActionsResolveAgainstTheResponseDocument(action: String) throws {
        let html = "<form action=\"\(action)\"><input id=\"login-page-flowkey\" value=\"flow\"><input id=\"user-object-id\" value=\"user\"><div id=\"secondSmsLoginForm\"></div></form>"
        let origin = AppURL.required("https://sso.bit.edu.cn")
        let context = SchoolLoginHTMLParser.parseSecondFactorPage(html: html, baseURL: origin,
            documentURL: AppURL.required("https://sso.bit.edu.cn/cas/login?service=fixture"))
        if action.hasPrefix("https:") { #expect(context == nil) }
        else {
            let expected = action.isEmpty ? "https://sso.bit.edu.cn/cas/login?service=fixture"
                : action.hasPrefix("?") ? "https://sso.bit.edu.cn/cas/login?step=2" : "https://sso.bit.edu.cn/cas/login"
            #expect(try #require(context).formAction.absoluteString == expected)
        }
    }

    @Test func cryptoCompletionAcceptsOnlyExpectedSchoolLanding() {
        let crypto = TestCrypto()
        #expect(crypto.isAcceptedSchoolLoginCompletion(
            statusCode: 200,
            url: AppURL.required("https://sso.bit.edu.cn/cas/login")
        ))
        #expect(crypto.isAcceptedSchoolLoginCompletion(
            statusCode: 401,
            url: AppURL.required("https://sso.bit.edu.cn/gate/cas-success")
        ))
        #expect(crypto.isAcceptedSchoolLoginCompletion(
            statusCode: 401,
            url: AppURL.required("https://sso.bit.edu.cn/gate/cas-success/?ticket=test-ticket")
        ))
        #expect(!crypto.isAcceptedSchoolLoginCompletion(
            statusCode: 401,
            url: AppURL.required("https://evil.example/gate/cas-success")
        ))
    }

    @Test @MainActor func schoolSessionsUseIndependentCookieContainers() throws {
        let firstCookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let secondCookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let first = TeachingCenterSessionState(cookieStorage: firstCookies)
        let second = TeachingCenterSessionState(cookieStorage: secondCookies)
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "webvpn.bit.edu.cn", .path: "/", .name: "module-session", .value: "test-session"
        ]))
        firstCookies.setCookie(cookie)
        secondCookies.setCookie(cookie)
        first.markAuthenticated(for: "module-a")
        second.markAuthenticated(for: "module-b")

        #expect(first.hasUsableSession(for: "module-a"))
        #expect(second.hasUsableSession(for: "module-b"))
        first.clearSchoolAuthenticationCookies()
        #expect(firstCookies.cookies?.isEmpty == true)
        #expect(second.hasUsableSession(for: "module-b"))
    }

    private struct TestCrypto: SchoolServiceCryptoProviding {
        let schoolURLCryptoPublicKey = "test-key"
        let browserUserAgent = "test-agent"

        func schoolProtectedHeaders() -> [String: String] { [:] }

        func encryptSchoolURLCryptoBody(
            object: [String: String],
            publicKeyPEM: String
        ) throws -> (body: String, encryptedKey: String, aesKey: Data) {
            ("", "", Data())
        }

        func decryptSchoolURLCryptoResponse(_ data: Data, aesKey: Data) throws -> Data {
            data
        }
    }
}
