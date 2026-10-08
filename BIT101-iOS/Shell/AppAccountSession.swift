import Foundation
import StorageCore
import ClientCore

/// App 选择凭据后端、学校会话清理和账号存储分区。
enum AppAccountSession {
    static let storage: LoginStorage = {
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
    }()

    static var currentSession: AppStorageSession {
        let studentID = storage.currentStudentID
#if BIT101_UI_TESTING
        if AppFileDirectories.isRunningUITest {
            let account = studentID.isEmpty ? "guest" : studentID
            return AppStorageSession(accountIdentifier: "__ui_tests__.\(AppFileDirectories.uiTestRunIdentifier).\(account)")
        }
#endif
        return AppStorageSession(accountIdentifier: studentID)
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
