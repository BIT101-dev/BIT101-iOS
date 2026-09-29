import ClientCore
import Foundation

/// 应用生命周期为基础存储提供当前账号、路径和偏好容器。
extension AccountScopedCodableStore {
    init(
        keyPrefix: String,
        defaults: UserDefaults = AppFileDirectories.defaults,
        session: @escaping () -> AppStorageSession = { AppFileDirectories.currentSession }
    ) {
        self.init(keyPrefix: keyPrefix, defaults: defaults, sessionProvider: session)
    }
}

extension AccountScopedFileCodableStore {
    init(
        filename: String,
        files: any AppFileService = AppFileDirectories.files,
        session: @escaping () -> AppStorageSession = { AppFileDirectories.currentSession }
    ) {
        self.init(filename: filename, files: files, session: session, directory: AppFileDirectories.applicationSupport)
    }
}
