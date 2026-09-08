import Foundation

/// App 持久化文件使用的 `Application Support` 目录。
///
/// 调用方从此 URL 追加业务子目录。系统目录查询返回空结果时，访问 `applicationSupport` 触发 `preconditionFailure`。
enum AppFileDirectories {
    static var applicationSupport: URL {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            preconditionFailure("Application Support directory is unavailable")
        }
        return url
    }
}
