import Foundation

/// Shared field encoding for school forms and their query values.
public nonisolated enum HTTPFormEncoding {
    public static func body(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\(percentEncoded($0.0))=\(percentEncoded($0.1))" }.joined(separator: "&").utf8)
    }

    public static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            preconditionFailure("Form field encoding failed")
        }
        return encoded
    }
}

/// 提供应用内置 URL 的统一构造入口。
///
/// 内置 URL 来自发布配置字符串。字符串有效时返回 URL；字符串无效时，入口立即触发
/// 前置条件失败，让配置错误在定义位置暴露，调用方统一使用包含 scheme 的绝对 URL。
public nonisolated enum AppURL {
    public static func isSameOrigin(_ url: URL?, as expected: URL?) -> Bool {
        guard let url, let expected, let scheme = expected.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.scheme?.lowercased() == scheme,
              let host = expected.host?.lowercased(), url.host?.lowercased() == host,
              url.user == nil, url.password == nil, expected.user == nil, expected.password == nil else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (url.port ?? defaultPort) == (expected.port ?? defaultPort)
    }

    public static func required(
        _ string: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> URL {
        guard let url = URL(string: string), url.scheme != nil else {
            preconditionFailure("Invalid built-in URL: \(string)", file: file, line: line)
        }
        return url
    }
}
