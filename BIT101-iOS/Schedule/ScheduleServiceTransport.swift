//
//  ScheduleServiceTransport.swift
//  BIT101-iOS
//
//  Shared HTTPS transport and response classification.
//

import Foundation

private nonisolated enum ScheduleJSONResponseResult<Value: Sendable>: Sendable {
    case decoded(Value)
    case businessError(String)
    case invalidResponse
}

extension ScheduleService {
    /// 发送教务/乐学 JSON 请求并自动解码响应。
    ///
    /// 学校接口大量使用表单 POST + JSON 返回，因此这里统一封装。
    func sendJSONRequest<Response: Decodable & Sendable>(
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
#if RELEASE_NETWORK_SMOKE
        if path.contains("cxxszhxqkb.do") {
            ReleaseNetworkSmokeReportStore.writeRawCourseResponse(data)
        }
#endif
        if isTeachingCenterAuthenticationFailure(data: data, response: response) {
            throw ScheduleServiceError.teachingCenterSessionExpired
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw httpError(response.statusCode)
        }
        let result = await Self.decodeJSONResponse(Response.self, from: data)
        try Task.checkCancellation()
        switch result {
        case let .decoded(response):
            return response
        case let .businessError(message):
            throw ScheduleServiceError.schoolResponse(message)
        case .invalidResponse:
            // 登录页 HTML 已在上方按内容特征识别。其余无法解码的 2xx 响应可能只是学校
            // 网关故障或接口改版，不能误导用户说“登录失效”。
            throw ScheduleServiceError.invalidResponse
        }
    }

    /// 业务分类和解码共用后台解析任务，集中处理完整课表与空教室响应。
    private nonisolated static func decodeJSONResponse<Response: Decodable & Sendable>(
        _ type: Response.Type,
        from data: Data
    ) async -> ScheduleJSONResponseResult<Response> {
        let parsingTask = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
            } catch {
                return ScheduleJSONResponseResult<Response>.invalidResponse
            }
            let businessMessage = Self.schoolBusinessErrorMessage(from: data)
            do {
                try Task.checkCancellation()
            } catch {
                return ScheduleJSONResponseResult<Response>.invalidResponse
            }
            if let businessMessage {
                return ScheduleJSONResponseResult<Response>.businessError(businessMessage)
            }
            do {
                return .decoded(try JSONDecoder().decode(type, from: data))
            } catch {
                return .invalidResponse
            }
        }
        return await withTaskCancellationHandler {
            await parsingTask.value
        } onCancel: {
            parsingTask.cancel()
        }
    }

    /// 学校接口会在外层成功响应中嵌入业务状态，例如课表 `extParams`。
    nonisolated static func schoolBusinessErrorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let successCodes: Set<Int> = [0, 1, 200]
        let envelopeKeys: Set<String> = ["data", "datas", "result", "results", "response", "payload", "extparams", "error", "errors"]
        let recordKeys: Set<String> = ["rows", "items", "records", "courses", "list"]
        var candidates: [(priority: Int, depth: Int, path: String, message: String)] = []

        func inspect(_ value: Any, path: [String]) {
            guard !Task.isCancelled else { return }
            if let dictionary = value as? [String: Any] {
                let explicitError = (dictionary["error"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let explicitErrorMessage = explicitError?.isEmpty == false ? explicitError : nil
                let message = explicitErrorMessage
                    ?? (dictionary["msg"] as? String)
                    ?? (dictionary["message"] as? String)
                let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let normalizedPath = path.map { $0.lowercased() }
                let isRecord = normalizedPath.contains(where: recordKeys.contains)
                if !trimmed.isEmpty, !isRecord {
                    let code = normalizedBusinessCode(dictionary["code"])
                    let success = dictionary["success"] as? Bool
                    let reportsSuccess = success == true || businessMessageIndicatesSuccess(trimmed)
                    let isEnvelope = path.isEmpty
                        || normalizedPath.contains(where: envelopeKeys.contains)
                    let priority: Int?
                    if explicitErrorMessage != nil {
                        priority = 0
                    } else if success == false {
                        priority = 1
                    } else if isEnvelope,
                              success != true,
                              businessMessageIndicatesFailure(trimmed)
                    {
                        priority = 2
                    } else if let code, !successCodes.contains(code), !reportsSuccess {
                        priority = 3
                    } else {
                        priority = nil
                    }
                    if let priority {
                        candidates.append((
                            priority: priority,
                            depth: path.count,
                            path: path.joined(separator: "."),
                            message: trimmed
                        ))
                    }
                }
                for key in dictionary.keys.sorted() {
                    if let child = dictionary[key] {
                        inspect(child, path: path + [key])
                    }
                }
            } else if let array = value as? [Any] {
                for (index, child) in array.enumerated() {
                    inspect(child, path: path + [String(index)])
                }
            }
        }

        inspect(root, path: [])
        return candidates.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.message < $1.message
        }.first?.message
    }

    private nonisolated static func businessMessageIndicatesFailure(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let failureMarkers = ["失败", "不成功", "错误", "异常", "未发布", "尚未发布", "无效", "不可用"]
        return failureMarkers.contains(where: normalized.contains)
    }

    private nonisolated static func businessMessageIndicatesSuccess(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !businessMessageIndicatesFailure(normalized) else { return false }
        return normalized.contains("成功") || normalized == "success" || normalized == "ok"
    }

    private nonisolated static func normalizedBusinessCode(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
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

        return try await sendStringResponse(
            request,
            requiresTeachingCenterSession: requiresTeachingCenterSession
        )
    }

    func sendStringRequest(_ request: URLRequest) async throws -> String {
        try await sendStringResponse(request, requiresTeachingCenterSession: false)
    }

    private func sendStringResponse(
        _ request: URLRequest,
        requiresTeachingCenterSession: Bool
    ) async throws -> String {
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

    /// 统一底层请求入口，并在发起前做 HTTPS 升级。
    func sendRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let secureRequest: URLRequest
        if let url = request.url {
            let upgradedURL = HTTPSURLUpgrade.upgradedURL(from: url)
            var upgradedRequest = request
            upgradedRequest.url = upgradedURL
            secureRequest = upgradedRequest
        } else {
            secureRequest = request
        }
        do {
            let result = try await HTTPClient(transport: transportOverride ?? session).send(
                secureRequest,
                accepting: 100 ..< 600
            )
            return (result.data, result.response)
        } catch {
            if isCertificateValidationError(error) {
                throw ScheduleServiceError.schoolTransportFailure
            }
            if error is HTTPClientError {
                throw ScheduleServiceError.invalidResponse
            }
            throw error
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
        if teachingCenterState.shouldPreferDirect(for: studentID) {
            return schoolBaseURL
        }
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
    func formBody(_ fields: [(String, String)]) -> Data {
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
