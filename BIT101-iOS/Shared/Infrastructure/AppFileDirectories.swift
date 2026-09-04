import Foundation

/// App 持久化文件共用的系统目录入口。
///
/// 业务仓库只追加自己的子目录，不重复取数组首项或各自处理目录不可用的边界。
enum AppFileDirectories {
    static var applicationSupport: URL {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            preconditionFailure("Application Support directory is unavailable")
        }
        return url
    }
}
