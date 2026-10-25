import ScheduleDomain
import Foundation
import Combine

protocol LoginServicing {
    var savedStudentID: String { get }
    var hasCachedSession: Bool { get }
    var sessionChanges: AnyPublisher<Void, Never> { get }

    func checkLogin() async throws -> String?
    func login(studentID: String, password: String) async throws -> String
    func logout()
}

extension LoginService: LoginServicing {}

protocol AccountRegistrationServicing {
    func sendRegistrationEmail(studentID: String) async throws -> String
    func verifyRegistrationIdentity(studentID: String, password: String) async throws -> WebVPNVerifyResponse
    func registerAccount(studentID: String, password: String, token: String, code: String, schoolPassword: String?) async throws
}

extension LoginService: AccountRegistrationServicing {
    static func registrationRuntimeService() -> any AccountRegistrationServicing {
#if BIT101_UI_TESTING
        if AppFileDirectories.isRunningUITest && !AppUITestBootstrap.usesProductionComposition { return UITestLoginService() }
#endif
        return LoginService()
    }
}

extension LoginService {
    static func appRuntimeService() -> any LoginServicing {
#if BIT101_UI_TESTING
        if AppFileDirectories.isRunningUITest && !AppUITestBootstrap.usesProductionComposition {
            return UITestLoginService()
        }
#endif
        return LoginService()
    }
}

#if BIT101_UI_TESTING
struct UITestLoginService: LoginServicing, AccountRegistrationServicing {
    private enum Key {
        static let studentID = "ui-test.session.student-id"
        static let hasSession = "ui-test.session.has-session"
        static let seededScheduleAccounts = "ui-test.schedule.seeded-accounts"
    }

    private var defaults: UserDefaults { AppFileDirectories.defaults }

    var savedStudentID: String { defaults.string(forKey: Key.studentID) ?? "" }
    var hasCachedSession: Bool { defaults.bool(forKey: Key.hasSession) && !savedStudentID.isEmpty }
    var sessionChanges: AnyPublisher<Void, Never> { AppAccountSession.storage.changes.map { _ in () }.eraseToAnyPublisher() }

    func checkLogin() async throws -> String? {
        hasCachedSession ? savedStudentID : nil
    }

    func login(studentID: String, password: String) async throws -> String {
        let account = studentID.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(account, forKey: Key.studentID)
        defaults.set(true, forKey: Key.hasSession)
        let storage = AppAccountSession.storage
        try storage.saveLoginState(studentID: account, password: password, fakeCookie: "ui-test-cookie")
        var seededAccounts = defaults.stringArray(forKey: Key.seededScheduleAccounts) ?? []
        if !seededAccounts.contains(account) {
            var cache = ScheduleCache()
            cache.currentTerm = "ui-test-term"
            cache.iCloudSyncEnabled = false
            let firstDayString = ScheduleDateCodec.formatDate(ScheduleDateCodec.monday(containing: Date()))
            cache.courseData.store(TermScheduleSnapshot(term: cache.currentTerm, firstDayString: firstDayString,
                courses: [], exams: [], updatedAt: .distantPast))
            if AppUITestBootstrap.environment["BIT101_UI_TEST_SCHOOL"] == "1" {
                let payload = UITestSchoolService.payload
                cache.courseData.store(TermScheduleSnapshot(term: cache.currentTerm, firstDayString: firstDayString,
                    courses: payload.courses, exams: payload.exams ?? [], updatedAt: .distantPast))
                cache.cachedClassroomBuildingsByCampusCode["1"] = try await UITestSchoolService().fetchBuildings(campusCode: "1")
            }
            if let count = AppUITestBootstrap.environment["BIT101_UI_TEST_PERFORMANCE_COURSES"].flatMap(Int.init),
               let weeks = AppUITestBootstrap.environment["BIT101_UI_TEST_PERFORMANCE_WEEKS"].flatMap(Int.init) {
                let slots = TimeSlot.default
                let coursesPerSlot = AppUITestBootstrap.environment["BIT101_UI_TEST_PERFORMANCE_COURSES_PER_SLOT"].flatMap(Int.init) ?? 1
                let courses = (0..<count).map { index in
                    let position = index / coursesPerSlot
                    let section = slots[(position / 7) % slots.count].id
                    return CourseRecord(id: "performance-\(index)", term: cache.currentTerm, name: "性能课程 \(index + 1)",
                        teacher: "测试教师", classroom: "文萃A101", description: "课表性能负载", weeks: Array(1...weeks),
                        weekday: position % 7 + 1, startSection: section, endSection: section, campus: "良乡校区",
                        number: "PERF-\(index)", credit: 2, hour: 32, type: "必修", category: "专业", department: "测试学院")
                }
                cache.courseData.store(TermScheduleSnapshot(term: cache.currentTerm, firstDayString: firstDayString,
                    courses: courses, exams: [], updatedAt: .distantPast))
            }
            if let fixture = AppUITestBootstrap.environment["BIT101_UI_TEST_DDL_FIXTURE"] {
                let now = Date()
                if fixture == "overdue" { cache.ddlAfterDay = 0 }
                cache.ddlEvents = [DDLEventRecord(id: "eclass:23", group: "eclass", title: "课程中心测试作业",
                    text: "测试课程", dueAt: now.addingTimeInterval(fixture == "overdue" ? -24 * 3600 : 24 * 3600), done: false,
                    sourceCourseIDs: [42])]
                if fixture == "sources" {
                    cache.ddlEvents.append(DDLEventRecord(id: "lexue-ui", group: "lexue", title: "乐学测试日程",
                        text: "测试课程\n\n 测试说明 \n\n补充说明", dueAt: now.addingTimeInterval(48 * 3600), done: false))
                }
            }
            guard await ScheduleCacheStore.saveAndWait(cache) else {
                throw URLError(.cannotWriteToFile)
            }
            seededAccounts.append(account)
            defaults.set(seededAccounts, forKey: Key.seededScheduleAccounts)
        }
        return account
    }

    func logout() {
        defaults.set(false, forKey: Key.hasSession)
        AppAccountSession.storage.clearSession()
    }

    func sendRegistrationEmail(studentID: String) async throws -> String { "ui-test-mail-token" }

    func verifyRegistrationIdentity(studentID: String, password: String) async throws -> WebVPNVerifyResponse {
        WebVPNVerifyResponse(token: "ui-test-school-token", code: "123456")
    }

    func registerAccount(studentID: String, password: String, token: String, code: String, schoolPassword: String?) async throws {
        defer { AppUITestBootstrap.completedRequests.insert("registration-submit") }
        if AppUITestBootstrap.holdingRequests["registration-submit"] != nil {
            await AppUITestBootstrap.holdRequest("registration-submit")
        }
        try Task.checkCancellation()
        guard code == "123456" else { throw LoginServiceError.invalidServerResponse }
        _ = try await login(studentID: studentID, password: schoolPassword ?? password)
        try AppAccountSession.storage.saveLoginState(studentID: studentID, password: schoolPassword ?? "",
            fakeCookie: "ui-test-cookie", communityPasswordDigest: LoginCrypto.md5Hex(password))
    }
}
#endif
