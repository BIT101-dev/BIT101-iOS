import ClientCore
import CryptoKit
import Foundation
import TransportCore

extension BIT101APIClient {
    /// 部分 CAS service 要求重新提交学校密码，并携带本次页面的风控令牌。
    func submitSchoolServiceLogin(url: URL, html: String, storage: LoginStorage, cookieStorage: HTTPCookieStorage? = nil) async throws -> URL {
        let cookies = cookieStorage ?? AppSchoolSession.teachingCenter.cookieStorage
        let owner = storage.schoolSessionIdentity
        var html = html
        for attempt in 0 ... 1 {
            try Task.checkCancellation()
            guard storage.schoolSessionIdentity == owner else { throw CancellationError() }
            let context = SchoolLoginHTMLParser.parse(html: html)
            guard let salt = context.salt, let execution = context.execution else { throw LoginServiceError.invalidSchoolLoginPage }
            var fields = [("username", storage.currentStudentID),
                ("password", try LoginCrypto.encryptPassword(storage.currentPassword, saltBase64: salt)),
                ("execution", execution), ("croypto", salt), ("captcha_payload", try LoginCrypto.encryptPassword("{}", saltBase64: salt)),
                ("type", "UsernamePassword"), ("geolocation", ""), ("captcha_code", ""), ("_eventId", "submit")]
            if Self.casField("riskSystemSwitch", in: html) == "USTC" {
                let token = try await schoolRiskToken(referer: url, cookies: cookies)
                try Task.checkCancellation()
                guard storage.schoolSessionIdentity == owner else { throw CancellationError() }
                let group = cookies.cookies?.first { $0.name == "riskSystemGroupId" && $0.domain.hasSuffix("bit.edu.cn") }?.value ?? ""
                let payload = try JSONSerialization.data(withJSONObject: ["token": token, "groupId": group])
                fields += [("risk_payload", try LoginCrypto.encryptPassword(String(decoding: payload, as: UTF8.self), saltBase64: salt)),
                    ("targetSystem", Self.casField("targetSystem", in: html) ?? "sso"),
                    ("siteId", Self.casField("siteId", in: html) ?? "sourceId"), ("riskEngine", "true")]
            }
            guard let action = SchoolLoginHTMLParser.loginFormAction(html: html, documentURL: url) else {
                throw NativeSchoolAuthenticationError.invalidResponse
            }
            var request = URLRequest(url: action)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("https://sso.bit.edu.cn", forHTTPHeaderField: "Origin")
            request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
            request.httpBody = HTTPFormEncoding.body(fields)
            let (data, response) = try await sendRequest(request, followRedirects: false)
            try Task.checkCancellation()
            guard storage.schoolSessionIdentity == owner else { throw CancellationError() }
            if (300 ..< 400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
               let next = HTTPSURLUpgrade.resolvedURL(from: location, relativeTo: action) { return next }
            let responseHTML = String(decoding: data, as: UTF8.self)
            if let secondFactor = SchoolLoginHTMLParser.parseSecondFactorPage(html: responseHTML,
                baseURL: AppURL.required("https://sso.bit.edu.cn"), documentURL: url) {
                throw LoginServiceError.schoolSMSRequired(secondFactor)
            }
            if SchoolLoginHTMLParser.rejectsPassword(html: responseHTML) {
                guard attempt == 0 else { throw LoginServiceError.schoolPasswordRejected }
                try await storage.updateSchoolCredentials()
                let (fresh, _) = try await sendRequest(URLRequest(url: url), followRedirects: false)
                html = String(decoding: fresh, as: UTF8.self)
                continue
            }
            throw NativeSchoolAuthenticationError.invalidResponse
        }
        throw NativeSchoolAuthenticationError.invalidResponse
    }

    private func schoolRiskToken(referer: URL, cookies: HTTPCookieStorage) async throws -> String {
        let base = AppURL.required("https://sso.bit.edu.cn")
        var device = cookies.cookies(for: base)?.first { $0.name == "device" }?.value
        if device == nil {
            let generated = Self.riskFingerprint(UUID().uuidString)
            device = generated
            if let cookie = HTTPCookie(properties: [.domain: "sso.bit.edu.cn", .path: "/", .name: "device", .value: generated, .secure: "TRUE"]) {
                cookies.setCookie(cookie)
            }
        }
        // 摘要字段属于学校风控认证协议，与代码及产物校验相互独立。
        let values = ["[\"Arial\",\"Helvetica Neue\",\"PingFang SC\",\"Times New Roman\"]", "16", "10",
            "\"Asia/Shanghai\"", "\"not available\"", "\"MacIntel\"", "\"zh-CN\"", "[956,1470]"]
        let group = cookies.cookies(for: base)?.first { $0.name == "riskSystemGroupId" }?.value ?? ""
        let profile = ["fonts": Self.riskFingerprint(values[0]), "deviceMemory": Self.riskFingerprint(values[1]),
            "hardwareConcurrency": Self.riskFingerprint(values[2]), "localgroupId": group, "timezone": values[3],
            "cpuClass": Self.riskFingerprint(values[4]), "platform": values[5], "language": values[6],
            "screenResolution": values[7], "fingerprint": Self.riskFingerprint(values.joined()), "cookieValue": device ?? "",
            "userAgent": Self.browserUserAgent, "platformAuthenticator": "support"]
        var request = URLRequest(url: base.appending(path: "ustc-rba-front/fp"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: profile)
        let (data, response) = try await sendRequest(request, followRedirects: false)
        guard (200 ..< 300).contains(response.statusCode),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (payload["responsetoken"] as? String) ?? ((payload["data"] as? [String: Any])?["responsetoken"] as? String),
              !token.isEmpty else { throw NativeSchoolAuthenticationError.invalidResponse }
        return token
    }

    private nonisolated static func riskFingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func casField(_ id: String, in html: String) -> String? {
        let pattern = #"<[^>]*\bid\s*=\s*["']"# + NSRegularExpression.escapedPattern(for: id) + #"["'][^>]*>\s*([^<]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
