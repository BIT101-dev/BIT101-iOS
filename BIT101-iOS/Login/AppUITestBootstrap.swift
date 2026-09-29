#if BIT101_UI_TESTING
import Foundation

enum AppUITestBootstrap {
    static func prepareForLaunch() {
        let environment = ProcessInfo.processInfo.environment
        guard AppFileDirectories.isRunningUITest else {
            preconditionFailure("The UI automation App requires its isolated launch configuration")
        }
        guard environment["BIT101_UI_TEST_RESET_STORAGE"] == "1" else { return }

        AppFileDirectories.defaults.removePersistentDomain(
            forName: AppFileDirectories.uiTestDefaultsSuiteName
        )
        LoginStorage.resetUITestCredentials()

        let supportDirectory = AppFileDirectories.applicationSupportDirectoryURL(named: "BIT101-iOS")
        guard AppFileDirectories.files.fileExists(at: supportDirectory) else { return }
        do {
            let testSession = AppStorageSession(
                accountIdentifier: "__ui_tests__.\(AppFileDirectories.uiTestRunIdentifier)."
            )
            let testAccountPrefixes = [testSession.accountStorageIdentifier, testSession.accountDirectoryName]
            let directories = try AppFileDirectories.files.contentsOfDirectory(at: supportDirectory, options: [])
            for directory in directories where testAccountPrefixes.contains(where: directory.lastPathComponent.hasPrefix) {
                try AppFileDirectories.files.removeItem(at: directory)
            }
        } catch {
            preconditionFailure("UI test account storage cleanup failed: \(error)")
        }
    }
}
#endif
