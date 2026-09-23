import Foundation

/// App 持久化文件使用的 `Application Support` 目录。
///
/// 调用方从此 URL 追加业务子目录。首次访问时完成系统目录查询。
enum AppFileDirectories {
    static let applicationSupport: URL = {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            preconditionFailure("Application Support directory is unavailable")
        }
        return url
    }()
}
