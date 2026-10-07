import Foundation
import CommunityTransport
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

@MainActor
@Suite(.serialized)
struct LoginStorageTests {
    private final class Credentials: LoginCredentialsStoring {
        var values: [String: String] = [:]
        var failsWrites = false
        func read(account: String) throws -> String { values[account] ?? "" }
        func save(_ value: String, account: String) throws {
            if failsWrites { throw CocoaError(.fileWriteNoPermission) }
            values[account] = value
        }
        func delete(account: String) -> Bool { values[account] = nil; return true }
    }

    @Test func credentialChangesCarryAccountGenerationsAndStayWithTheirOwner() throws {
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
        let first = LoginStorage(defaults: firstDefaults, credentials: firstBackend, clearSchoolCookies: { clearedSchools += 1 })
        let second = LoginStorage(defaults: secondDefaults, credentials: secondBackend, clearSchoolCookies: {})
        var firstChanges: [CommunitySessionIdentity] = []
        var secondChanges: [CommunitySessionIdentity] = []
        let subscriptions = [first.changes.sink { firstChanges.append($0) }, second.changes.sink { secondChanges.append($0) }]
        try first.saveLoginState(studentID: " A ", password: "synthetic", fakeCookie: "cookie-A")
        try first.saveLoginState(studentID: "A", password: "synthetic", fakeCookie: "renewed-A")
        #expect(firstChanges == [.init(accountIdentifier: "A", generation: 1)])
        #expect(first.communityCredentials.cookie == "renewed-A")
        try first.saveLoginState(studentID: "B", password: "synthetic", fakeCookie: "cookie-B")
        first.clearSession()
        #expect(firstChanges.map(\.generation) == [1, 2, 3])
        #expect(first.currentStudentID == "B")
        #expect(first.currentPassword.isEmpty && first.fakeCookie.isEmpty)
        #expect(first.clearAllLocalData())
        #expect(firstChanges.last == .init(accountIdentifier: "", generation: 4))
        #expect(clearedSchools == 3)
        #expect(secondChanges.isEmpty && secondBackend.values.isEmpty)
        withExtendedLifetime(subscriptions) {}
    }

    @Test func credentialWriteFailurePreservesThePublishedIdentity() throws {
        let domain = "BIT101Tests.login-storage.failure"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = Credentials()
        let storage = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        try storage.saveLoginState(studentID: "A", password: "synthetic", fakeCookie: "cookie-A")
        let previous = storage.communityCredentials
        var changes: [CommunitySessionIdentity] = []
        let subscription = storage.changes.sink { changes.append($0) }
        backend.failsWrites = true
        #expect(throws: CocoaError.self) {
            try storage.saveLoginState(studentID: "B", password: "synthetic", fakeCookie: "cookie-B")
        }
        #expect(storage.communityCredentials == previous)
        #expect(changes.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    @Test func credentialMigrationUsesTheSelectedBackend() throws {
        let domain = "BIT101Tests.login-storage.migration"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "login.installationMarker")
        defaults.set("legacy-cookie", forKey: "login.fakeCookie")
        let backend = Credentials()
        backend.values["login.sid"] = "A"
        let storage = LoginStorage(defaults: defaults, credentials: backend, clearSchoolCookies: {})
        #expect(storage.fakeCookie == "legacy-cookie")
        #expect(storage.communityCredentials.identity == .init(accountIdentifier: "A"))
        #expect(defaults.object(forKey: "login.fakeCookie") == nil)
    }
}
