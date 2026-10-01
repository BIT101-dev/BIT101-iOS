import ScheduleDomain
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
        try LoginStorage.shared.saveLoginState(studentID: account, password: password, fakeCookie: "ui-test-cookie")
        defaults.set(account, forKey: Key.studentID)
        defaults.set(true, forKey: Key.hasSession)
        var seededAccounts = defaults.stringArray(forKey: Key.seededScheduleAccounts) ?? []
        if !seededAccounts.contains(account) {
            var cache = ScheduleCache()
            cache.firstDayString = ScheduleDateCodec.formatDate(ScheduleDateCodec.monday(containing: Date()))
            cache.currentTerm = "ui-test-term"
            cache.iCloudSyncEnabled = false
            if let fixture = ProcessInfo.processInfo.environment["BIT101_UI_TEST_DDL_FIXTURE"] {
                let now = Date()
                if fixture == "overdue" { cache.ddlAfterDay = 0 }
                cache.ddlEvents = [DDLEventRecord(id: "eclass:ui", group: "eclass", title: "课程中心测试作业",
                    text: "测试课程", dueAt: now.addingTimeInterval(fixture == "overdue" ? -24 * 3600 : 24 * 3600), done: false)]
                if fixture == "sources" {
                    cache.ddlEvents.append(DDLEventRecord(id: "lexue-ui", group: "lexue", title: "乐学测试日程",
                        text: "测试课程", dueAt: now.addingTimeInterval(48 * 3600), done: false))
                }
            }
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
        LoginStorage.shared.clearSession()
        defaults.set(false, forKey: Key.hasSession)
        NotificationCenter.default.post(name: .loginStorageDidChange, object: nil)
    }
}
#endif
