import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Extended login state transitions")
struct ExtendedLoginTests {
    private final class ServiceStub: LoginServicing {
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
