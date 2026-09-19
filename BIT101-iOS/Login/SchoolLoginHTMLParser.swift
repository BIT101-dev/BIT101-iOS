//
//  SchoolLoginHTMLParser.swift
//  BIT101-iOS
//

import Foundation

/// 从学校 CAS 登录页 HTML 中提取 salt 和 execution。
///
/// 解析器使用 Foundation 的正则能力处理学校页面中的表单字段，兼容字段属性顺序、
/// 隐藏 input 和文本节点。
enum SchoolLoginHTMLParser {
    /// 从学校 CAS 登录页 HTML 中提取 salt、execution 和“是否已登录”状态。
    static func parse(html: String) -> SchoolLoginContext {
        let salt = field(in: html, id: "login-croypto")
        let execution = field(in: html, id: "login-page-flowkey")

        return SchoolLoginContext(
            salt: salt,
            execution: execution,
            isLoggedIn: containsAuthenticatedPageMarker(in: html) && !containsLoginPageMarker(in: html)
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
            let execution = field(in: html, id: "login-page-flowkey"),
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
        let decodedAction = decodeHTML(action).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let formAction = URL(string: decodedAction, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        guard isSameSecureOrigin(formAction, as: baseURL) else {
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

    private static func containsLoginPageMarker(in html: String) -> Bool {
        let markers = [
            #"id=["']login-croypto["']"#,
            #"id=["']login-page-flowkey["']"#,
            #"name=["']username["']"#,
        ]
        return markers.contains { marker in
            html.range(of: marker, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func containsAuthenticatedPageMarker(in html: String) -> Bool {
        let markers = [
            "退出登录",
            "注销",
            #"cas-success"#,
            #"login-success"#,
        ]
        return markers.contains { marker in
            html.range(of: marker, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func isSameSecureOrigin(_ url: URL, as baseURL: URL) -> Bool {
        guard
            url.scheme?.lowercased() == "https",
            url.host?.lowercased() == baseURL.host?.lowercased(),
            url.port == baseURL.port,
            url.user == nil,
            url.password == nil
        else {
            return false
        }
        return true
    }

    private static func field(in html: String, id: String) -> String? {
        let escapedID = NSRegularExpression.escapedPattern(for: id)
        let valuePatterns = [
            #"id=["']"# + escapedID + #"["'][^>]*\bvalue\s*=\s*["']([^"']+)["']"#,
            #"\bvalue\s*=\s*["']([^"']+)["'][^>]*\bid\s*=\s*["']"# + escapedID + #"["']"#,
        ]
        for pattern in valuePatterns {
            guard let rawValue = attribute(in: html, pattern: pattern) else { continue }
            let normalized = decodeHTML(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return normalized
            }
        }

        let innerText = value(
            in: html,
            pattern: #"id=["']"# + escapedID + #"["'][^>]*>\s*([^<\s]+)\s*<"#
        )
        if let innerText {
            let normalized = decodeHTML(innerText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return nil
    }

    private static func decodeHTML(_ value: String) -> String {
        var decoded = value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#47;", with: "/")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")

        guard let regex = try? NSRegularExpression(pattern: #"&#(?:x([0-9A-Fa-f]+)|([0-9]+));"#) else {
            return decoded
        }

        let range = NSRange(decoded.startIndex..., in: decoded)
        for match in regex.matches(in: decoded, options: [], range: range).reversed() {
            let number: Int?
            if let hexRange = Range(match.range(at: 1), in: decoded) {
                number = Int(decoded[hexRange], radix: 16)
            } else if let decimalRange = Range(match.range(at: 2), in: decoded) {
                number = Int(decoded[decimalRange])
            } else {
                number = nil
            }

            guard
                let number,
                let scalar = UnicodeScalar(number),
                let entityRange = Range(match.range, in: decoded)
            else {
                continue
            }
            decoded.replaceSubrange(entityRange, with: String(scalar))
        }

        return decoded
    }
}
