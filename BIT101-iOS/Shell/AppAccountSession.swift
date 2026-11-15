import ClientCore
import Foundation
import StorageCore

/// App 选择凭据后端、学校会话清理和账号存储分区。
enum AppAccountSession {
    static let storage: LoginStorage = {
        #if DEBUG
        if AppFileDirectories.isRunningIsolatedUnitTest
            || AppFileDirectories.isRunningIsolatedNetworkSmoke
        {
            return LoginStorage(
                defaults: AppFileDirectories.defaults,
                credentials: AutomatedTestPreferenceCloudStore.shared,
                clearSchoolCookies: { _ in })
        }
        if AppFileDirectories.isRunningUITest {
            return LoginStorage(
                defaults: AppFileDirectories.defaults,
                credentials: KeychainLoginCredentials(service: uiTestKeychainService),
                clearSchoolCookies: { _ in },
                requestSchoolPassword: {
                    try await SchoolPasswordPrompt.shared.requestPassword(studentID: $0)
                })
        }
        #endif
        return LoginStorage(
            defaults: AppFileDirectories.defaults,
            credentials: KeychainLoginCredentials(service: "harrybit.BIT101-iOS.login"),
            clearSchoolCookies: { AppSchoolSession.clearSchoolCookies($0) },
            requestSchoolPassword: {
                try await SchoolPasswordPrompt.shared.requestPassword(studentID: $0)
            })
    }()

    static var currentSession: AppStorageSession {
        let studentID = storage.currentStudentID
        #if DEBUG
        if AppFileDirectories.isRunningIsolatedUnitTest {
            return AppStorageSession(
                accountIdentifier:
                    "__automated_tests__.\(studentID.isEmpty ? "guest" : studentID)")
        }
        if AppFileDirectories.isRunningUITest {
            let account = studentID.isEmpty ? "guest" : studentID
            return AppStorageSession(
                accountIdentifier:
                    "__ui_tests__.\(AppFileDirectories.uiTestRunIdentifier).\(account)")
        }
        if AppFileDirectories.isRunningIsolatedNetworkSmoke {
            let account = studentID.isEmpty ? "guest" : studentID
            return AppStorageSession(accountIdentifier: "__network_smoke__.\(account)")
        }
        #endif
        return AppStorageSession(accountIdentifier: studentID)
    }

    #if DEBUG
    private static var uiTestKeychainService: String {
        "harrybit.BIT101-iOS.ui-tests.\(AppFileDirectories.uiTestRunIdentifier)"
    }

    @discardableResult
    static func resetUITestCredentials() -> Bool {
        storage.clearAllLocalData()
    }
    #endif
}

#if DEBUG
@MainActor
final class AutomatedTestPreferenceCloudStore: PreferenceCloudStoring, LoginCredentialsStoring {
    static let shared = AutomatedTestPreferenceCloudStore()
    private var keys: [String: String] = [:]
    func read(account: String) throws -> String { keys[account] ?? "" }
    func save(_ value: String, account: String) throws { keys[account] = value }
    func delete(account: String) -> Bool {
        keys[account] = nil
        return true
    }
    private(set) var dictionaryRepresentation: [String: Any] = [:]
    func data(forKey key: String) -> Data? { dictionaryRepresentation[key] as? Data }
    func set(_ value: Any?, forKey key: String) { dictionaryRepresentation[key] = value }
    func synchronize() -> Bool { true }
}

#endif
