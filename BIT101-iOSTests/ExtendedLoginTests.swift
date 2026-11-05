import ClientCore
import Combine
import CommunityTransport
import Foundation
import Testing
import TransportCore

@testable import BIT101_iOS

@Suite("Extended login state transitions")
struct ExtendedLoginTests {
    private final class ServiceStub: LoginServicing {
        let changes = PassthroughSubject<Void, Never>()
        var sessionChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
        var savedStudentID: String
        var hasCachedSession: Bool
        let bootstrapError: Error?
        let checkLoginResult: String?
        var loginResult: Result<String, Error> = .success("1120260001")
        var beforeLogin: (() async -> Void)?
        private(set) var checkLoginCalls = 0
        private(set) var loginCalls: [(String, String)] = []

        init(
            studentID: String = "1120260001",
            hasCachedSession: Bool = false,
            bootstrapError: Error? = nil,
            checkLoginResult: String? = nil
        ) {
            savedStudentID = studentID
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
            await beforeLogin?()
            return try loginResult.get()
        }

        func logout() {}
    }

    @Test("Successful explicit login enters the signed-in state", .timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1))) @MainActor
    func repeatedKeyboardLoginSharesOperation() async throws {
        let service = ServiceStub()
        var pending: CheckedContinuation<Void, Never>?
        service.beforeLogin = { await withCheckedContinuation { pending = $0 } }
        let model = LoginViewModel(service: service)
        model.password = "secret"
        let first = Task { await model.login() }
        try await waitForTestEvent { pending != nil }
        service.loginResult = .failure(URLError(.timedOut))
        await model.login()
        #expect(service.loginCalls.count == 1 && model.isSubmitting)
        service.loginResult = .success("1120260001")
        pending?.resume()
        await first.value
        #expect(
            model.screenState == .signedIn(studentID: "1120260001") && model.isSubmitting == false)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func lateLoginFailureKeepsNewlyPublishedSession() async throws {
        let service = ServiceStub()
        var pending: CheckedContinuation<Void, Never>?
        service.beforeLogin = { await withCheckedContinuation { pending = $0 } }
        let model = LoginViewModel(service: service)
        model.password = "secret"
        let task = Task { await model.login() }
        try await waitForTestEvent { pending != nil }
        service.savedStudentID = "B"
        service.hasCachedSession = true
        service.changes.send(())
        service.loginResult = .failure(URLError(.timedOut))
        pending?.resume()
        await task.value
        #expect(model.screenState == .signedIn(studentID: "B") && model.alert == nil)
    }

    @Test("Failed explicit login stays signed out and exposes the error", .timeLimit(.minutes(1)))
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

    @Test("Cancelled login keeps the signed-out state and alert clear", .timeLimit(.minutes(1)))
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

    @Test("Blank credentials are rejected before the service is called", .timeLimit(.minutes(1)))
    @MainActor
    func blankCredentials() async {
        let service = ServiceStub()
        let viewModel = LoginViewModel(service: service)
        viewModel.studentID = ""

        await viewModel.login()

        #expect(service.loginCalls.isEmpty)
        #expect(viewModel.alert?.title == "请输入学号")
    }

    @Test("Logout clears the session and preserves the saved student identifier")
    @MainActor
    func logoutKeepsStudentID() {
        let service = ServiceStub()
        let viewModel = LoginViewModel(service: service)
        viewModel.logout()

        #expect(viewModel.screenState == .signedOut)
        #expect(viewModel.studentID == "1120260001")
    }

    @Test("Verified login identity replaces a stale cached identifier", .timeLimit(.minutes(1)))
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

    @Test(
        "Cached login remains available through transient bootstrap failure",
        .timeLimit(.minutes(1)))
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
