protocol LoginServicing {
    var savedStudentID: String { get }
    var hasCachedSession: Bool { get }

    func checkLogin() async throws -> String?
    func login(studentID: String, password: String) async throws -> String
    func logout()
}

extension LoginService: LoginServicing {}

extension LoginService {
    static func appRuntimeService() -> any LoginServicing {
#if BIT101_UI_TESTING
        if AppFileDirectories.isRunningUITest {
            return UITestLoginService()
        }
#endif
        return LoginService()
    }
}

#if BIT101_UI_TESTING
private struct UITestLoginService: LoginServicing {
    private var storage: LoginStorage { .shared }

    var savedStudentID: String { storage.currentStudentID }
    var hasCachedSession: Bool { !storage.fakeCookie.isEmpty && !savedStudentID.isEmpty }

    func checkLogin() async throws -> String? {
        hasCachedSession ? savedStudentID : nil
    }

    func login(studentID: String, password: String) async throws -> String {
        let account = studentID.trimmingCharacters(in: .whitespacesAndNewlines)
        try storage.saveLoginState(studentID: account, password: password, fakeCookie: "ui-test-session")
        return account
    }

    func logout() {
        storage.clearSession()
    }
}
#endif
