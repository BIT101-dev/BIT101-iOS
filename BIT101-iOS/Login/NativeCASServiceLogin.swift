import ClientCore
import CryptoKit
import Foundation
import TransportCore

struct SchoolCASLoginPage {
    let url: URL
    let html: String
    let context: SchoolLoginContext
}

extension BIT101APIClient {
    /// 部分 CAS service 要求重新提交学校密码，并携带本次页面的风控令牌。
    func submitSchoolServiceLogin(url: URL, html: String, credentials: any SchoolCredentialsProviding,
        cookieStorage: () -> HTTPCookieStorage,
        updateCredentials: () async throws -> Void = { throw LoginServiceError.schoolPasswordRejected }) async throws -> URL {
        let owner = credentials.schoolSessionIdentity
        var html = html
        for attempt in 0 ... 1 {
            try Task.checkCancellation()
            guard credentials.schoolSessionIdentity == owner else { throw CancellationError() }
            let (data, response) = try await submitSchoolLoginForm(url: url, html: html,
                credentials: credentials, cookies: cookieStorage())
            guard let action = response.url else { throw NativeSchoolAuthenticationError.invalidResponse }
            if (300 ..< 400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
               let next = HTTPSURLUpgrade.resolvedURL(from: location, relativeTo: action) { return next }
            let responseHTML = String(decoding: data, as: UTF8.self)
            if let failure = SchoolServiceFailure.schoolResponse(responseHTML) { throw failure }
            if let secondFactor = SchoolLoginHTMLParser.parseSecondFactorPage(html: responseHTML,
                baseURL: AppURL.required("https://sso.bit.edu.cn"), documentURL: url) {
                throw LoginServiceError.schoolSMSRequired(secondFactor)
            }
            if SchoolLoginHTMLParser.rejectsPassword(html: responseHTML) {
                guard attempt == 0 else { throw LoginServiceError.schoolPasswordRejected }
                try await updateCredentials()
                let (fresh, _) = try await sendRequest(URLRequest(url: url), followRedirects: false)
                html = String(decoding: fresh, as: UTF8.self)
                continue
            }
            if response.statusCode == 403 || response.statusCode >= 500 {
                throw NativeSchoolAuthenticationError.serviceUnavailable(response.statusCode)
            }
            throw NativeSchoolAuthenticationError.invalidResponse
        }
        throw NativeSchoolAuthenticationError.invalidResponse
    }

    func submitSchoolLoginForm(url: URL, html: String, credentials: any SchoolCredentialsProviding,
        cookies: HTTPCookieStorage) async throws -> (Data, HTTPURLResponse) {
        let owner = credentials.schoolSessionIdentity
        try Task.checkCancellation()
        let context = SchoolLoginHTMLParser.parse(html: html)
        guard let salt = context.salt, let execution = context.execution else { throw LoginServiceError.invalidSchoolLoginPage }
        var fields = [("username", credentials.currentStudentID),
            ("password", try LoginCrypto.encryptPassword(credentials.currentPassword, saltBase64: salt)),
            ("execution", execution), ("croypto", salt), ("captcha_payload", try LoginCrypto.encryptPassword("{}", saltBase64: salt)),
            ("type", "UsernamePassword"), ("geolocation", ""), ("captcha_code", ""), ("_eventId", "submit")]
        if Self.casField("riskSystemSwitch", in: html) == "USTC" {
            let token = try await schoolRiskToken(referer: url, cookies: cookies)
            try Task.checkCancellation()
            guard credentials.schoolSessionIdentity == owner else { throw CancellationError() }
            let group = cookies.cookies(for: AppURL.required("https://sso.bit.edu.cn"))?.first { $0.name == "riskSystemGroupId" }?.value ?? ""
            let risk: [String: Any] = token.map { ["token": $0, "groupId": group] } ?? ["error": true]
            let payload = try JSONSerialization.data(withJSONObject: risk)
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
        guard credentials.schoolSessionIdentity == owner else { throw CancellationError() }
        guard response.url == action else { throw NativeSchoolAuthenticationError.invalidResponse }
        return (data, response)
    }

    private func schoolRiskToken(referer: URL, cookies: HTTPCookieStorage) async throws -> String? {
        let base = AppURL.required("https://sso.bit.edu.cn")
        var device = cookies.cookies(for: base)?.first { $0.name == "device" }?.value
        if device == nil {
            let generated = Self.riskFingerprint(UUID().uuidString)
            device = generated
            if let cookie = HTTPCookie(properties: [.domain: "sso.bit.edu.cn", .path: "/", .name: "device", .value: generated, .secure: "TRUE"]) {
                cookies.setCookie(cookie)
            }
        }
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
        do {
            let (data, response) = try await sendRequest(request, followRedirects: false)
            guard (200 ..< 300).contains(response.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = (payload["responsetoken"] as? String) ?? ((payload["data"] as? [String: Any])?["responsetoken"] as? String),
                  !token.isEmpty else { return nil }
            return token
        } catch {
            if TaskCancellation.matches(error) { throw error }
            return nil
        }
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
