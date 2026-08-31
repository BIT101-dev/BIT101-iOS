//
//  ScheduleServiceTransport.swift
//  BIT101-iOS
//
//  Shared HTTPS transport and response classification.
//

import Foundation

extension ScheduleService {
    /// 发送教务/乐学 JSON 请求并自动解码响应。
    ///
    /// 学校接口大量使用表单 POST + JSON 返回，因此这里统一封装。
    func sendJSONRequest<Response: Decodable>(
        baseURL: URL? = nil,
        path: String,
        method: String = "GET",
        body: [(String, String)] = []
    ) async throws -> Response {
        var request = URLRequest(url: buildURL(baseURL: baseURL ?? activeSchoolBaseURL, path: path))
        request.httpMethod = method
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        if method == "POST" {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(body)
        }

        let (data, response) = try await sendRequest(request)
        if isTeachingCenterAuthenticationFailure(data: data, response: response) {
            throw ScheduleServiceError.teachingCenterSessionExpired
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw httpError(response.statusCode)
        }

        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            // 登录页 HTML 已在上方按内容特征识别。其余无法解码的 2xx 响应可能只是学校
            // 网关故障或接口改版，不能误导用户说“登录失效”。
            throw ScheduleServiceError.invalidResponse
        }
    }

    /// 发送返回字符串正文的请求，主要用于 HTML 页和 ICS 文件。
    func sendStringRequest(
        baseURL: URL? = nil,
        path: String,
        method: String = "GET",
        body: [(String, String)] = [],
        requiresTeachingCenterSession: Bool = true
    ) async throws -> String {
        var request = URLRequest(url: buildURL(baseURL: baseURL ?? activeSchoolBaseURL, path: path))
        request.httpMethod = method

        if method == "POST" {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(body)
        }

        let (data, response) = try await sendRequest(request)
        if requiresTeachingCenterSession,
           isTeachingCenterAuthenticationFailure(data: data, response: response)
        {
            throw ScheduleServiceError.teachingCenterSessionExpired
        }
        guard (200 ..< 400).contains(response.statusCode) else {
            throw httpError(response.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func sendStringRequest(_ request: URLRequest) async throws -> String {
        let (data, response) = try await sendRequest(request)
        guard (200 ..< 400).contains(response.statusCode) else {
            throw httpError(response.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 统一底层请求入口，并在发起前做 HTTPS 升级。
    func sendRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let secureRequest: URLRequest
        if let url = request.url, let upgradedURL = ScheduleURLUpgrade.upgradedURL(from: url), upgradedURL != url {
            var upgradedRequest = request
            upgradedRequest.url = upgradedURL
            secureRequest = upgradedRequest
        } else {
            secureRequest = request
        }
        do {
            let result = try await HTTPClient(transport: session).send(
                secureRequest,
                accepting: 100 ..< 600
            )
            return (result.data, result.response)
        } catch is HTTPClientError {
            throw ScheduleServiceError.invalidResponse
        }
    }

    /// 组装最终请求 URL，兼容绝对路径与相对路径。
    private func buildURL(baseURL: URL, path: String) -> URL {
        if baseURL.host == "webvpn.bit.edu.cn", path.hasPrefix("/") {
            return URL(string: baseURL.absoluteString + path) ?? baseURL
        }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL.appending(path: path)
    }

    private var activeSchoolBaseURL: URL {
        let studentID = storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return teachingCenterState.hasUsableSession(for: studentID) ? webVPNSchoolBaseURL : schoolBaseURL
    }

    private func isTeachingCenterAuthenticationFailure(
        data: Data,
        response: HTTPURLResponse
    ) -> Bool {
        if response.statusCode == 401 || response.statusCode == 403 {
            return true
        }

        if let url = response.url {
            let host = url.host?.lowercased() ?? ""
            let path = url.path.lowercased()
            if host == "sso.bit.edu.cn"
                || path.contains("/cas/login")
                || path.contains("/auth-protocol-core/login")
            {
                return true
            }
        }
        if let location = response.value(forHTTPHeaderField: "Location")?.lowercased(),
           location.contains("login") || location.contains("/cas/")
        {
            return true
        }
        return looksLikeLoginHTML(data)
    }

    private func looksLikeLoginHTML(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let prefix = String(decoding: data.prefix(16_384), as: UTF8.self).lowercased()
        guard prefix.contains("<html") || prefix.contains("<!doctype html") else { return false }
        return prefix.contains("统一身份认证")
            || prefix.contains("用户名密码")
            || prefix.contains("cas/login")
            || prefix.contains("login-page-flowkey")
    }

    /// 把字段组装成 `application/x-www-form-urlencoded` 表单体。
    private func formBody(_ fields: [(String, String)]) -> Data {
        let encoded = fields.map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }
        .joined(separator: "&")

        return Data(encoded.utf8)
    }

    /// 表单值专用 URL 编码。
    func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 把 HTTP 状态码包装成统一错误。
    private func httpError(_ statusCode: Int) -> NSError {
        NSError(
            domain: "BIT101.Schedule",
            code: statusCode,
            userInfo: [NSLocalizedDescriptionKey: "请求失败，HTTP 状态码 \(statusCode)。"]
        )
    }
}
