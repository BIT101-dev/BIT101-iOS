import ClientCore
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Login parsing and cryptography")
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
