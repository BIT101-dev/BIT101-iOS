import Foundation
import StorageCore
import ClientCore

/// App 选择凭据后端、学校会话清理和账号存储分区。
enum AppAccountSession {
    static let storage: LoginStorage = {
#if BIT101_AUTOMATED_TESTING && !BIT101_UI_TESTING
        return LoginStorage(defaults: AppFileDirectories.defaults,
            credentials: AutomatedTestPreferenceCloudStore.shared, clearSchoolCookies: {})
#else
        let service: String
        let clearSchoolCookies: () -> Void
#if BIT101_UI_TESTING
        if AppFileDirectories.isRunningUITest {
            service = uiTestKeychainService
            clearSchoolCookies = {}
        } else {
            service = "harrybit.BIT101-iOS.login"
            clearSchoolCookies = { AppSchoolSession.clearSchoolAuthenticationCookies() }
        }
#else
        service = "harrybit.BIT101-iOS.login"
        clearSchoolCookies = { AppSchoolSession.clearSchoolAuthenticationCookies() }
#endif
        return LoginStorage(defaults: AppFileDirectories.defaults,
            credentials: KeychainLoginCredentials(service: service), clearSchoolCookies: clearSchoolCookies)
#endif
    }()

    static var currentSession: AppStorageSession {
        let studentID = storage.currentStudentID
#if BIT101_AUTOMATED_TESTING && !BIT101_UI_TESTING
        return AppStorageSession(accountIdentifier: "__automated_tests__.\(studentID.isEmpty ? "guest" : studentID)")
#else
#if BIT101_UI_TESTING
        if AppFileDirectories.isRunningUITest {
            let account = studentID.isEmpty ? "guest" : studentID
            return AppStorageSession(accountIdentifier: "__ui_tests__.\(AppFileDirectories.uiTestRunIdentifier).\(account)")
        }
#endif
        return AppStorageSession(accountIdentifier: studentID)
#endif
    }

#if BIT101_UI_TESTING
    private static var uiTestKeychainService: String {
        "harrybit.BIT101-iOS.ui-tests.\(AppFileDirectories.uiTestRunIdentifier)"
    }

    @discardableResult
    static func resetUITestCredentials() -> Bool {
        KeychainLoginCredentials(service: uiTestKeychainService).deleteAll()
    }
#endif
}

#if BIT101_AUTOMATED_TESTING
@MainActor
final class AutomatedTestPreferenceCloudStore: PreferenceCloudStoring, LoginCredentialsStoring {
    static let shared = AutomatedTestPreferenceCloudStore()
    private var keys: [String: String] = [:]
    func read(account: String) throws -> String { keys[account] ?? "" }
    func save(_ value: String, account: String) throws { keys[account] = value }
    func delete(account: String) -> Bool { keys[account] = nil; return true }
    private(set) var dictionaryRepresentation: [String: Any] = [:]
    func data(forKey key: String) -> Data? { dictionaryRepresentation[key] as? Data }
    func set(_ value: Any?, forKey key: String) { dictionaryRepresentation[key] = value }
    func synchronize() -> Bool { true }
}

#endif
