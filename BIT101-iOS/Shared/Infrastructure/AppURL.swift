import Foundation

/// 提供应用内置 URL 的统一构造入口。
///
/// 内置 URL 来自发布配置字符串。字符串有效时返回 URL；字符串无效时，入口立即触发
/// 前置条件失败，让配置错误在定义位置暴露，调用方统一使用已校验的 URL。
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
