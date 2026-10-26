//
//  SchoolLoginHTMLParser.swift
//  BIT101-iOS
//

import Foundation
import TransportCore

/// 从学校 CAS 登录页 HTML 中提取 salt 和 execution。
///
/// 解析器使用 Foundation 的正则能力处理学校页面中的表单字段，兼容字段属性顺序、
/// 隐藏 input 和文本节点。
public nonisolated enum SchoolLoginHTMLParser {
    /// 从学校 CAS 登录页 HTML 中提取 salt、execution 和“是否已登录”状态。
    public static func parse(html: String) -> SchoolLoginContext {
        let salt = field(in: html, id: "login-croypto")
        let execution = field(in: html, id: "login-page-flowkey")

        return SchoolLoginContext(
            salt: salt,
            execution: execution,
            isLoggedIn: containsAuthenticatedPageMarker(in: html) && !containsLoginPageMarker(in: html)
        )
    }

    /// CAS 表单省略 action 时沿当前文档提交，保留 service 与 execution 上下文。
    public static func loginFormAction(html: String, documentURL: URL) -> URL? {
        let action = attribute(in: html, pattern: #"<form\b[^>]*\saction\s*=\s*["']([^"']*)["'][^>]*>"#) ?? ""
        let decoded = decodeHTML(action).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = decoded.isEmpty ? documentURL : URL(string: decoded, relativeTo: documentURL)?.absoluteURL,
              isSameSecureOrigin(url, as: documentURL) else { return nil }
        return url
    }

    /// CAS 明确的密码拒绝码触发凭据更新；风控和页面异常沿原错误呈现。
    public static func rejectsPassword(html: String) -> Bool {
        guard let code = field(in: html, id: "login-error-code") else { return false }
        return ["1030027", "1030031"].contains(code)
    }

    /// 从学校 CAS 短信验证页提取继续提交所需的表单上下文。
    public static func parseSecondFactorPage(html: String, baseURL: URL, documentURL: URL? = nil) -> SchoolSecondFactorContext? {
        let hasSecondFactorMarker = html.range(
            of: "secondSmsLoginForm|second-auth-tip|sso-second|current-login-type|cas-gateway",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        guard hasSecondFactorMarker else { return nil }
        guard let form = secondFactorForm(in: html) else { return nil }
        let fields = field(in: form, id: "user-object-id") == nil ? html : form

        guard
            let execution = field(in: fields, id: "login-page-flowkey"),
            let userObjectID = field(in: fields, id: "user-object-id"),
            !execution.isEmpty,
            !userObjectID.isEmpty
        else {
            return nil
        }

        let action = attribute(
            in: form,
            pattern: #"<form\b[^>]*\saction\s*=\s*["']([^"']+)["'][^>]*>"#
        ) ?? ""
        let decodedAction = decodeHTML(action).trimmingCharacters(in: .whitespacesAndNewlines)
        let pageURL = documentURL ?? baseURL
        guard let formAction = decodedAction.isEmpty ? pageURL : URL(string: decodedAction, relativeTo: pageURL)?.absoluteURL else {
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

    private static func secondFactorForm(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<form\b[^>]*>[\s\S]*?</form\s*>"#, options: [.caseInsensitive]) else { return nil }
        let forms = regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            Range(match.range, in: html).map { String(html[$0]) }
        }
        if forms.count == 1 { return forms[0] }
        let candidates = forms.filter { form in
            field(in: form, id: "user-object-id") != nil && field(in: form, id: "login-page-flowkey") != nil
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func containsLoginPageMarker(in html: String) -> Bool {
        let markers = [
            #"\sid\s*=\s*["']login-croypto["']"#,
            #"\sid\s*=\s*["']login-page-flowkey["']"#,
            #"\sname\s*=\s*["']username["']"#,
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
        url.scheme?.lowercased() == "https" && AppURL.isSameOrigin(url, as: baseURL)
    }

    private static func field(in html: String, id: String) -> String? {
        let escapedID = NSRegularExpression.escapedPattern(for: id)
        let valuePatterns = [
            #"<[^>]*\sid\s*=\s*["']"# + escapedID + #"["'][^>]*\svalue\s*=\s*["']([^"']+)["']"#,
            #"<[^>]*\svalue\s*=\s*["']([^"']+)["'][^>]*\sid\s*=\s*["']"# + escapedID + #"["']"#,
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
            pattern: #"<[^>]*\sid\s*=\s*["']"# + escapedID + #"["'][^>]*>\s*([^<\s]+)\s*<"#
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
