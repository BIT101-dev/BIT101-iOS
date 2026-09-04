import Foundation

/// 应用内置 URL 的统一构造入口。
///
/// 这些 URL 是发布配置的一部分；配置错误应在定义位置立即失败，
/// 不应把强制解包散落到业务代码中。
enum AppURL {
    static func required(
        _ string: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid built-in URL: \(string)", file: file, line: line)
        }
        return url
    }
}
