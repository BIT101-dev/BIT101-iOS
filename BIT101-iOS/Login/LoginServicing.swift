import Foundation

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
struct UITestLoginService: LoginServicing {
    private enum Key {
        static let studentID = "ui-test.session.student-id"
        static let hasSession = "ui-test.session.has-session"
        static let seededScheduleAccounts = "ui-test.schedule.seeded-accounts"
    }

    private var defaults: UserDefaults { AppFileDirectories.defaults }

    var savedStudentID: String { defaults.string(forKey: Key.studentID) ?? "" }
    var hasCachedSession: Bool { defaults.bool(forKey: Key.hasSession) && !savedStudentID.isEmpty }

    func checkLogin() async throws -> String? {
        hasCachedSession ? savedStudentID : nil
    }

    func login(studentID: String, password: String) async throws -> String {
        let account = studentID.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(account, forKey: Key.studentID)
        defaults.set(true, forKey: Key.hasSession)
        var seededAccounts = defaults.stringArray(forKey: Key.seededScheduleAccounts) ?? []
        if !seededAccounts.contains(account) {
            var cache = ScheduleCache()
            cache.firstDayString = ScheduleDateCodec.formatDate(ScheduleDateCodec.monday(containing: Date()))
            cache.currentTerm = "ui-test-term"
            cache.iCloudSyncEnabled = false
            guard await ScheduleCacheStore.saveAndWait(cache) else {
                throw URLError(.cannotWriteToFile)
            }
            seededAccounts.append(account)
            defaults.set(seededAccounts, forKey: Key.seededScheduleAccounts)
        }
        NotificationCenter.default.post(name: .loginStorageDidChange, object: nil)
        return account
    }

    func logout() {
        defaults.set(false, forKey: Key.hasSession)
        NotificationCenter.default.post(name: .loginStorageDidChange, object: nil)
    }
}
#endif
