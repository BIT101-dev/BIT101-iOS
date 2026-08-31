import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Login parsing and cryptography")
struct LoginLogicTests {
    @Test("CAS success gate 401 is a terminal browser landing response")
    func acceptsCASGateLandingResponse() throws {
        let gateURL = try #require(URL(string: "https://sso.bit.edu.cn/gate/cas-success"))
        let otherURL = try #require(URL(string: "https://sso.bit.edu.cn/cas/login"))

        #expect(BIT101APIClient.isAcceptedSchoolLoginCompletion(statusCode: 401, url: gateURL))
        #expect(BIT101APIClient.isSchoolLoginSuccessLanding(gateURL))
        #expect(!BIT101APIClient.isAcceptedSchoolLoginCompletion(statusCode: 401, url: otherURL))
        #expect(!BIT101APIClient.isSchoolLoginSuccessLanding(otherURL))
        #expect(BIT101APIClient.isAcceptedSchoolLoginCompletion(statusCode: 204, url: otherURL))
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

    @Test("A page without the login prompt is recognized as authenticated")
    func recognizesAuthenticatedPage() {
        let context = SchoolLoginHTMLParser.parse(html: "<html>统一身份认证成功</html>")
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
}
