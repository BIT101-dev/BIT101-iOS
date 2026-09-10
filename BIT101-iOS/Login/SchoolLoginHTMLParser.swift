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

    /// 从学校 CAS 短信验证页提取继续提交所需的表单上下文。
    static func parseSecondFactorPage(html: String, baseURL: URL) -> SchoolSecondFactorContext? {
        let hasSecondFactorMarker = html.range(
            of: "secondSmsLoginForm|second-auth-tip|sso-second|current-login-type|cas-gateway",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        guard hasSecondFactorMarker else { return nil }

        guard
            let execution = value(in: html, pattern: #"id=["']login-page-flowkey["'][^>]*>\s*([^<\s]+)\s*<"#),
            let userObjectID = field(in: html, id: "user-object-id"),
            !execution.isEmpty,
            !userObjectID.isEmpty
        else {
            return nil
        }

        let action = attribute(
            in: html,
            pattern: #"<form\b[^>]*\baction\s*=\s*["']([^"']+)["'][^>]*>"#
        ) ?? "cas/login"
        let decodedAction = decodeHTML(action)
        guard let formAction = URL(string: decodedAction, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }

        return SchoolSecondFactorContext(
            execution: execution,
            formAction: formAction,
            userObjectID: userObjectID
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

    private static func attribute(in html: String, pattern: String) -> String? {
        value(in: html, pattern: pattern)
    }

    private static func field(in html: String, id: String) -> String? {
        let innerText = value(
            in: html,
            pattern: #"id=["']"# + NSRegularExpression.escapedPattern(for: id) + #"["'][^>]*>\s*([^<\s]+)\s*<"#
        )
        if let innerText, !innerText.isEmpty {
            return innerText
        }
        return attribute(
            in: html,
            pattern: #"id=["']"# + NSRegularExpression.escapedPattern(for: id) + #"["'][^>]*\bvalue\s*=\s*["']([^"']+)["']"#
        )
    }

    private static func decodeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
