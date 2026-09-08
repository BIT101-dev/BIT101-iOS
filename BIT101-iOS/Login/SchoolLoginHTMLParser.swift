//
//  SchoolLoginHTMLParser.swift
//  BIT101-iOS
//

import Foundation

/// 从学校 CAS 登录页 HTML 中提取 salt 和 execution。
///
/// 学校登录页结构可能变化。解析提取必要字段，并兼容字段周围的属性和空白。
enum SchoolLoginHTMLParser {
    /// 从学校 CAS 登录页 HTML 中提取 salt、execution 和“是否已登录”状态。
    static func parse(html: String) -> SchoolLoginContext {
        SchoolLoginContext(
            salt: value(in: html, pattern: #"id=["']login-croypto["'][^>]*>\s*([^<\s]+)\s*<"#),
            execution: value(in: html, pattern: #"id=["']login-page-flowkey["'][^>]*>\s*([^<\s]+)\s*<"#),
            isLoggedIn: !html.contains("用户名密码")
        )
    }

    /// 使用正则从 HTML 中提取单个字段值。
    private static func value(in html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(html.startIndex..., in: html)
        guard
            let match = regex.firstMatch(in: html, options: [], range: range),
            let captureRange = Range(match.range(at: 1), in: html)
        else {
            return nil
        }

        return String(html[captureRange])
    }
}
