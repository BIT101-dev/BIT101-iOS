#if BIT101_UI_TESTING
import Foundation

enum AppUITestBootstrap {
    static func prepareForLaunch() {
        let environment = ProcessInfo.processInfo.environment
        guard AppFileDirectories.isRunningUITest,
              environment["BIT101_UI_TEST_RESET_STORAGE"] == "1"
        else { return }

        AppFileDirectories.defaults.removePersistentDomain(
            forName: AppFileDirectories.uiTestDefaultsSuiteName
        )
        LoginStorage.resetUITestCredentials()
    }
}
#endif
