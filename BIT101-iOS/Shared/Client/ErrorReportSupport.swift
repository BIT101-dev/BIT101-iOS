import TransportCore
import DesignSystemKit
import Foundation
import Combine
import UIKit



/// 反馈载荷标记本地 Debug 安装或正式 Release 构建，用户身份字段保持空缺。
nonisolated enum AppBuildEnvironment {
#if DEBUG
    static let isDevelopment = true
#else
    static let isDevelopment = false
#endif
}

nonisolated enum ErrorReportRedactor {
    private static let protectedNames = [
        "password", "passwd", "pwd", "cookie", "set-cookie", "authorization", "proxy-authorization", "token",
        "access_token", "refresh_token", "challenge_token", "fake-cookie",
        "accessToken", "refreshToken", "challengeToken", "fakeCookie", "session", "sessionID",
        "session_id", "sessionid", "ticket", "api-key", "api_key", "apikey", "client_secret",
        "secret", "captcha", "captcha_payload", "croypto", "execution", "salt", "csrf", "xsrf",
        "www-authenticate", "proxy-authenticate", "authentication-info"
    ]

    private static func isProtectedName(_ name: String) -> Bool {
        protectedNames.contains { name.localizedCaseInsensitiveContains($0) }
    }

    @MainActor
    static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        redactHeaders(headers, credentials: currentCredentials)
    }

    static func redactHeaders(_ headers: [String: String], credentials: [String]) -> [String: String] {
        headers.reduce(into: [:]) { result, pair in
            result[pair.key] = isProtectedName(pair.key) ? "[REDACTED]" : forced(pair.value, credentials: credentials)
        }
    }

    private static func redactObject(_ value: Any, credentials: [String]) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = isProtectedName(entry.key)
                    ? "[REDACTED]" : redactObject(entry.value, credentials: credentials)
            }
        }
        if let array = value as? [Any] { return array.map { redactObject($0, credentials: credentials) } }
        if let text = value as? String { return forced(text, credentials: credentials) }
        return value
    }

    private static func redactHTML(_ value: String) -> String {
        guard let tags = try? NSRegularExpression(pattern: #"<([a-z][a-z0-9:_-]*)\b(?:[^>"']|"[^"]*(?:"|$)|'[^']*(?:'|$))*(?:>|$)"#, options: .caseInsensitive),
              let fields = try? NSRegularExpression(pattern: #"\b(?:id|name|type|property|http-equiv)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#, options: .caseInsensitive)
        else { return value }
        let voidTags = Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"])
        var output = "", cursor = value.startIndex
        for tag in tags.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let range = Range(tag.range, in: value), range.lowerBound >= cursor,
                  let nameRange = Range(tag.range(at: 1), in: value) else { continue }
            let text = String(value[range]), name = String(value[nameRange]).lowercased()
            let identifiers = fields.matches(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { match in
                (1...3).compactMap { Range(match.range(at: $0), in: text).map { decodedHTMLAttribute(String(text[$0])) } }
            }
            guard identifiers.contains(where: { ["login-page-flowkey", "login-croypto"].contains($0.lowercased()) || isProtectedName($0) }) else { continue }
            output += value[cursor..<range.lowerBound]
            output += text.replacingOccurrences(of: #"(?i)(\b(?:value|content)\s*=\s*)(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|[^\s"'=<>`]+)"#,
                with: "$1\"[REDACTED]\"", options: .regularExpression)
            cursor = range.upperBound
            guard text.hasSuffix(">"), !text.hasSuffix("/>"), !voidTags.contains(name) else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let boundaries = try? NSRegularExpression(pattern: "</?" + escaped + #"\b(?:[^>"']|"[^"]*"|'[^']*')*>"#, options: .caseInsensitive)
            var depth = 1, closing: Range<String.Index>?
            for boundary in boundaries?.matches(in: value, range: NSRange(cursor..., in: value)) ?? [] {
                guard let candidate = Range(boundary.range, in: value) else { continue }
                let token = value[candidate]
                if token.hasPrefix("</") { depth -= 1 }
                else if !token.hasSuffix("/>") { depth += 1 }
                if depth == 0 { closing = candidate; break }
            }
            output += "[REDACTED]"
            if let closing { output += value[closing]; cursor = closing.upperBound }
            else { cursor = value.endIndex }
        }
        return output + value[cursor...]
    }

    private static func decodedHTMLAttribute(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"&#(?:[xX]([0-9a-fA-F]+)|([0-9]+));?"#) else { return value }
        var output = value
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            let hexadecimal = match.range(at: 1).location != NSNotFound
            guard let digits = Range(match.range(at: hexadecimal ? 1 : 2), in: value),
                  let number = UInt32(value[digits], radix: hexadecimal ? 16 : 10), let scalar = Unicode.Scalar(number),
                  let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: String(scalar))
        }
        for (entity, replacement) in [("&lowbar;", "_"), ("&UnderBar;", "_"), ("&hyphen;", "-"), ("&amp;", "&")] {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        return output
    }

    private enum PercentDecodingError: Error { case budgetExceeded }

    private static func redactCredentials(_ value: String, credentials: [String]) -> String {
        credentials.filter { !$0.isEmpty }.reduce(value) {
            $0.replacingOccurrences(of: $1, with: "[REDACTED]")
        }
    }

    private static func decodedPercent(_ value: String) throws -> String {
        var output = value
        for _ in 0..<8 {
            guard let decoded = output.removingPercentEncoding, decoded != output else { return output }
            output = decoded
        }
        throw PercentDecodingError.budgetExceeded
    }

    private static func redactURLs(_ value: String, credentials: [String] = [], studentID: String? = nil, depth: Int = 0) -> String {
        guard depth < 8, !Task.isCancelled else { return "[REDACTED]" }
        guard let expression = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: .caseInsensitive) else { return value }
        var output = value
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            guard var url = URLComponents(string: String(output[range])) else {
                output.replaceSubrange(range, with: "[REDACTED]"); continue
            }
            do {
                let decodedPath = try decodedPercent(url.percentEncodedPath)
                var safePath = redactCredentials(decodedPath, credentials: credentials)
                if let studentID { safePath = redactIdentities(safePath, studentID: studentID) }
                if safePath != decodedPath { url.path = safePath }
                if url.user != nil || url.password != nil { url.user = "[REDACTED]"; url.password = nil }
                if studentID != nil { url.fragment = nil }
                if url.percentEncodedFragment != nil {
                    let decodedFragment = try decodedPercent(url.percentEncodedFragment ?? "")
                    var fragmentFields = URLComponents()
                    fragmentFields.query = url.fragment ?? ""
                    let candidates = try [decodedFragment] + (fragmentFields.queryItems ?? []).map { try decodedPercent($0.name) }
                    if url.fragment == nil || candidates.contains(where: isProtectedName) { url.fragment = "[REDACTED]" }
                    else {
                        let safeFragment = redactCredentials(decodedFragment, credentials: credentials)
                        if safeFragment != decodedFragment { url.fragment = safeFragment }
                    }
                }
                url.queryItems = try url.queryItems?.map { item in
                    let name = try decodedPercent(item.name)
                    let safeName = redactCredentials(name, credentials: credentials)
                    let outputName = safeName == name ? item.name : safeName
                    if studentID != nil || isProtectedName(name) {
                        return URLQueryItem(name: outputName, value: "[REDACTED]")
                    }
                    let decoded = try item.value.map(decodedPercent)
                    let nested = decoded.flatMap { $0.range(of: #"https?://"#, options: [.regularExpression, .caseInsensitive]) == nil ? nil : redactURLs($0, credentials: credentials, studentID: studentID, depth: depth + 1) }
                    let safeValue = (nested ?? decoded).map { redactCredentials($0, credentials: credentials) }
                    return URLQueryItem(name: outputName,
                        value: safeValue == decoded ? item.value : safeValue)
                }
                output.replaceSubrange(range, with: url.string ?? "[REDACTED]")
            } catch {
                output.replaceSubrange(range, with: "[REDACTED]")
            }
        }
        return output
    }

    @MainActor
    static func forced(_ value: String) -> String { forced(value, credentials: currentCredentials) }

    static func forced(_ value: String, credentials: [String]) -> String {
        var structured = value
        if let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)),
           let bytes = try? JSONSerialization.data(withJSONObject: redactObject(object, credentials: credentials)),
           let json = String(data: bytes, encoding: .utf8) {
            structured = json
        } else {
            // 截断 JSON 的凭据范围按完整响应遮盖。
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { structured = "[REDACTED]" }
        }
        var output = redactHTML(redactURLs(structured, credentials: credentials)).replacingOccurrences(
            of: "(?i)((?:authorization|proxy-authorization|cookie|set-cookie)\\s*[=:]\\s*)[^&\\r\\n]+",
            with: "$1[REDACTED]", options: .regularExpression
        )
        for name in protectedNames {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let jsonPattern = "(?i)(\"\(escaped)\"\\s*:\\s*\")(?:\\\\.|[^\"\\\\])*(\")"
            let keyValuePattern = #"(?i)(\b[\w$-]*\#(escaped)[\w$-]*(?:["']\]?)?\s*[=:]\s*)(?:"(?:\\.|[^"\\])*(?:"|$)|'(?:\\.|[^'\\])*(?:'|$)|[^&\r\n,;]+)"#
            output = output.replacingOccurrences(of: jsonPattern, with: "$1[REDACTED]$2", options: .regularExpression)
            output = output.replacingOccurrences(of: keyValuePattern, with: "$1[REDACTED]", options: .regularExpression)
        }
        return redactCredentials(output, credentials: credentials)
    }

    @MainActor
    static func sanitized(_ value: String) -> String {
        sanitized(value, credentials: currentCredentials, studentID: AppAccountSession.storage.currentStudentID)
    }

    @MainActor private static var currentCredentials: [String] {
        [AppAccountSession.storage.currentPassword, AppAccountSession.storage.fakeCookie]
    }

    static func sanitized(_ value: String, credentials: [String], studentID: String) -> String {
        redactIdentities(redactURLs(forced(value, credentials: credentials), credentials: credentials, studentID: studentID), studentID: studentID)
    }

    private static func redactIdentities(_ value: String, studentID: String) -> String {
        var output = value
        if !studentID.isEmpty { output = output.replacingOccurrences(of: studentID, with: "[REDACTED]") }
        let patterns: [(pattern: String, replacement: String)] = [
            ("(?i)(\\b(?:student_?id|username|name|phone|mobile)\\s*[=:：]\\s*)[^&\\s,;]+", "$1[REDACTED]"),
            ("(?i)(\"(?:student_?id|username|name|phone|mobile)\"\\s*:\\s*\")[^\"]*(\")", "$1[REDACTED]$2"),
            ("(?<!\\d)\\d{8,12}(?!\\d)", "[REDACTED]")
        ]
        for pattern in patterns {
            output = output.replacingOccurrences(of: pattern.pattern, with: pattern.replacement, options: .regularExpression)
        }
        return output
    }

    static func sanitizedURL(_ string: String, credentials: [String], studentID: String) -> String {
        guard var components = URLComponents(string: string) else { return sanitized(string, credentials: credentials, studentID: studentID) }
        components.path = sanitized(components.path, credentials: credentials, studentID: studentID)
        components.query = components.queryItems?.map { "\($0.name)=[REDACTED]" }.joined(separator: "&")
        components.fragment = nil
        return sanitized(components.string ?? string, credentials: credentials, studentID: studentID)
    }
}

nonisolated struct FeedbackDeviceContext: Codable, Sendable {
    let locale: String
    let timeZone: String
    let interfaceStyle: String
    let orientation: String
    let networkStatus: String

    @MainActor
    static var current: FeedbackDeviceContext {
        let style: String
        switch UITraitCollection.current.userInterfaceStyle {
        case .dark: style = "dark"
        case .light: style = "light"
        default: style = "unspecified"
        }

        let orientation = String(describing: UIDevice.current.orientation)

        return FeedbackDeviceContext(
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier,
            interfaceStyle: style,
            orientation: orientation,
            networkStatus: NetworkConnectionDescription.shared.current
        )
    }
}

nonisolated struct FeedbackDiagnosticSummary: Codable, Sendable {
    let total: Int
    let failed: Int
    let statusCodes: [String: Int]
    let latestOccurredAt: Date?
    let latestFailure: String?

    static let empty = FeedbackDiagnosticSummary(
        total: 0,
        failed: 0,
        statusCodes: [:],
        latestOccurredAt: nil,
        latestFailure: nil
    )

    init(diagnostics: [NetworkDiagnosticRecord]) {
        total = diagnostics.count
        failed = diagnostics.reduce(into: 0) { count, record in
            if record.error != nil || record.statusCode.map({ $0 >= 400 }) == true {
                count += 1
            }
        }
        statusCodes = diagnostics.reduce(into: [String: Int]()) { counts, record in
            guard let statusCode = record.statusCode else { return }
            counts[String(statusCode), default: 0] += 1
        }
        latestOccurredAt = diagnostics.map(\.occurredAt).max()
        latestFailure = diagnostics.last(where: { $0.error != nil })?.error
    }

    private init(
        total: Int,
        failed: Int,
        statusCodes: [String: Int],
        latestOccurredAt: Date?,
        latestFailure: String?
    ) {
        self.total = total
        self.failed = failed
        self.statusCodes = statusCodes
        self.latestOccurredAt = latestOccurredAt
        self.latestFailure = latestFailure
    }
}

nonisolated protocol FeedbackSubmissionPayload: Encodable, Sendable {
    var requestID: UUID { get }
    func hasSameContent(as other: Self) -> Bool
}

/// 同一内容重试复用完整载荷，用户编辑后形成新的提交。
@MainActor
final class FeedbackSubmissionAttempt<Payload: FeedbackSubmissionPayload> {
    private(set) var pending: Payload?
    func restore(_ payload: Payload?) { pending = payload }
    func prepare(_ candidate: Payload) -> Payload {
        if let pending, pending.hasSameContent(as: candidate) { return pending }
        pending = candidate
        return candidate
    }
    func finish(_ payload: Payload) {
        if pending?.requestID == payload.requestID { pending = nil }
    }
}

nonisolated struct ErrorReportPayload: FeedbackSubmissionPayload {
    var requestID = UUID()
    let mode: String
    let isDevelopmentBuild: Bool
    let comment: String?
    let contact: String?
    let errorTitle: String
    let errorMessage: String
    let appVersion: String
    let build: String
    let systemVersion: String
    let deviceModel: String
    let networkStatus: String
    var diagnostics: [NetworkDiagnosticRecord]
    let submittedAt: Date
    let context: FeedbackDeviceContext
    let diagnosticSummary: FeedbackDiagnosticSummary
    var scheduleCacheReadFailure: String?

    func hasSameContent(as other: Self) -> Bool {
        mode == other.mode && comment == other.comment && contact == other.contact
            && errorTitle == other.errorTitle && errorMessage == other.errorMessage && diagnostics == other.diagnostics
    }

    func fittingMetadataBudget() throws -> Self {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var bounded = self
        var bodyLimit = diagnostics.compactMap { $0.responseBody?.count }.max() ?? 0
        while try encoder.encode(bounded).count > FeedbackSubmissionClient.maximumMetadataBytes {
            try Task.checkCancellation()
            guard bodyLimit > 0 else { throw FeedbackSubmissionError.metadataTooLarge }
            bodyLimit /= 2
            bounded.diagnostics = diagnostics.map { record in
                let body = record.responseBody.map { text in
                    text.count > bodyLimit ? String(text.prefix(bodyLimit)) + "\n[响应正文已按反馈大小限制截取]" : text
                }
                return NetworkDiagnosticRecord(id: record.id, occurredAt: record.occurredAt, method: record.method,
                    url: record.url, statusCode: record.statusCode, elapsedMilliseconds: record.elapsedMilliseconds,
                    error: record.error, responseHeaders: record.responseHeaders, responseBody: body,
                    finalURL: record.finalURL, finalMethod: record.finalMethod)
            }
        }
        return bounded
    }

    @concurrent
    func preparedForSubmission(credentials: [String], studentID: String) async throws -> Self {
        let sanitized = mode == "sanitized"
        let redact: (String) -> String = { value in
            sanitized ? ErrorReportRedactor.sanitized(value, credentials: credentials, studentID: studentID)
                : ErrorReportRedactor.forced(value, credentials: credentials)
        }
        let selected = try diagnostics.map { record in
            try Task.checkCancellation()
            return NetworkDiagnosticRecord(id: record.id, occurredAt: record.occurredAt, method: record.method,
                url: sanitized ? ErrorReportRedactor.sanitizedURL(record.url, credentials: credentials, studentID: studentID)
                    : ErrorReportRedactor.forced(record.url, credentials: credentials),
                statusCode: record.statusCode, elapsedMilliseconds: record.elapsedMilliseconds,
                error: record.error.map(redact), responseHeaders: sanitized ? [:] : ErrorReportRedactor.redactHeaders(record.responseHeaders, credentials: credentials),
                responseBody: sanitized ? nil : record.responseBody.map { ErrorReportRedactor.forced($0, credentials: credentials) },
                finalURL: record.finalURL.map { sanitized
                    ? ErrorReportRedactor.sanitizedURL($0, credentials: credentials, studentID: studentID)
                    : ErrorReportRedactor.forced($0, credentials: credentials) }, finalMethod: record.finalMethod)
        }
        return try Self(requestID: requestID, mode: mode, isDevelopmentBuild: isDevelopmentBuild,
            comment: comment.map(redact), contact: contact.map { ErrorReportRedactor.forced($0, credentials: credentials) },
            errorTitle: redact(errorTitle), errorMessage: redact(errorMessage), appVersion: appVersion, build: build,
            systemVersion: systemVersion, deviceModel: deviceModel, networkStatus: networkStatus, diagnostics: selected,
            submittedAt: submittedAt, context: context, diagnosticSummary: FeedbackDiagnosticSummary(diagnostics: selected),
            scheduleCacheReadFailure: scheduleCacheReadFailure.map(redact))
            .fittingMetadataBudget()
    }
}

private enum FeedbackSubmissionError: LocalizedError {
    case server(statusCode: Int, message: String?)
    case metadataTooLarge

    var errorDescription: String? {
        switch self {
        case .metadataTooLarge: return "反馈内容过长，请精简描述后重试。"
        case let .server(statusCode, message):
            if let message, !message.isEmpty {
                return "服务器响应异常（HTTP \(statusCode)）：\(message)"
            }
            return "服务器响应异常（HTTP \(statusCode)）。"
        }
    }
}

#if DEBUG || RELEASE_NETWORK_SMOKE
private struct NetworkSmokePayload: Encodable {
    let mode = "network-smoke"
    let runID: String
}

private struct NetworkSmokeResponse: Decodable {
    let ok: Bool
    let recordVerified: Bool
    let temporaryRecordRemoved: Bool
    let quotaReserved: Bool
}
#endif

/// 错误报告与开发者建议共用的反馈提交入口。
struct FeedbackSubmissionClient {
    nonisolated static let maximumMetadataBytes = 1024 * 1024
    static func validateSubmissionResponse(_ response: HTTPResponse, request: URLRequest, expectedReportID: UUID? = nil) throws {
        struct Receipt: Decodable { let id: String }
        try validateResponseOwnership(response, request: request)
        guard response.statusCode == 201, let receipt = try? JSONDecoder().decode(Receipt.self, from: response.data),
              let reportID = UUID(uuidString: receipt.id), expectedReportID == nil || reportID == expectedReportID
        else { throw URLError(.badServerResponse) }
    }

    private static func validateResponseOwnership(_ response: HTTPResponse, request: URLRequest) throws {
        let evidence = HTTPRequestEvidence(request: request, response: response.response, finalRequest: response.finalRequest)
        guard response.response.url == request.url, evidence.finalMethod == request.httpMethod else { throw URLError(.badServerResponse) }
    }

    static func submit<Payload: FeedbackSubmissionPayload>(_ payload: Payload) async throws {
        var request = URLRequest(url: AppURL.required("https://feedback.aihelpme.dev/api/error-reports"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(payload)
        let response = try await HTTPClient.shared.send(request, accepting: 100 ..< 600)
        let data = response.data
        let http = response.response
        guard (200 ..< 300).contains(http.statusCode) else {
            throw FeedbackSubmissionError.server(
                statusCode: http.statusCode,
                message: HTTPClient.errorMessage(from: data)
            )
        }
        try validateSubmissionResponse(response, request: request, expectedReportID: payload.requestID)
    }

#if DEBUG || RELEASE_NETWORK_SMOKE
    static func submitNetworkSmoke(runID: String) async throws {
        var request = URLRequest(url: AppURL.required("https://feedback.aihelpme.dev/api/error-reports"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60 + 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-BIT101-Network-Smoke")
        request.httpBody = try JSONEncoder().encode(NetworkSmokePayload(runID: runID))

        let response = try await HTTPClient.shared.send(request, accepting: 100 ..< 600)
        let data = response.data
        let http = response.response
        guard (200 ..< 300).contains(http.statusCode) else {
            throw FeedbackSubmissionError.server(
                statusCode: http.statusCode,
                message: HTTPClient.errorMessage(from: data)
            )
        }
        try validateResponseOwnership(response, request: request)
        try validateNetworkSmokeResponse(data)
    }

    static func validateNetworkSmokeResponse(_ data: Data) throws {
        let result: NetworkSmokeResponse
        do { result = try JSONDecoder().decode(NetworkSmokeResponse.self, from: data) }
        catch DecodingError.keyNotFound(let key, _) {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "反馈验收响应需要字段：\(key.stringValue)"])
        }
        guard result.ok, result.recordVerified, result.temporaryRecordRemoved, result.quotaReserved else {
            throw URLError(.dataNotAllowed)
        }
    }
#endif
}

@MainActor
final class ErrorReportViewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case sanitized
        case raw
        var id: String { rawValue }
        var title: String { self == .sanitized ? "脱敏调试信息" : "原始网络响应" }
    }

    @Published var mode: Mode = .sanitized
    @Published var comment = ""
    @Published var contact = ""
    @Published var diagnostics: [NetworkDiagnosticRecord] = []
    @Published var isSubmitting = false
    @Published var resultMessage: String?
    let alert: any DiagnosticAlertPresentable
    private let identity = AppAccountSession.storage.schoolSessionIdentity
    private var accountSubscription: AnyCancellable?
    private let submitReport: @MainActor (ErrorReportPayload) async throws -> Void
    private let submissionAttempt = FeedbackSubmissionAttempt<ErrorReportPayload>()
    var isCurrentAccount: Bool { AppAccountSession.storage.schoolSessionIdentity == identity }
    var allowsSubmission: Bool {
        alert.allowsDiagnostics && SchoolServiceIssue(error: alert.underlyingError) == nil
    }

    init(alert: any DiagnosticAlertPresentable,
         submitReport: @escaping @MainActor (ErrorReportPayload) async throws -> Void = { try await FeedbackSubmissionClient.submit($0) }) {
        self.alert = alert
        self.submitReport = submitReport
        accountSubscription = AppAccountSession.storage.changes.sink { [weak self] _ in
            guard let self, AppAccountSession.storage.schoolSessionIdentity != self.identity else { return }
            self.diagnostics = []
            self.resultMessage = "账号已更新，请重新打开反馈页面。"
        }
    }

    func load() async {
        guard allowsSubmission else { return }
        let current = await NetworkDiagnosticStore.shared.recent()
        diagnostics = AppAccountSession.storage.schoolSessionIdentity == identity ? current : []
    }

    func submit() async -> Bool {
        guard allowsSubmission else {
            resultMessage = SchoolServiceIssue(error: alert.underlyingError)?.message
                ?? "请返回当前页面继续处理。"
            return false
        }
        guard AppAccountSession.storage.schoolSessionIdentity == identity else {
            diagnostics = []
            resultMessage = "账号已更新，请重新打开反馈页面。"
            return false
        }
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = FeedbackDeviceContext.current
        let candidate = ErrorReportPayload(
            mode: mode.rawValue,
            isDevelopmentBuild: AppBuildEnvironment.isDevelopment,
            comment: trimmedComment.isEmpty ? nil : trimmedComment,
            contact: trimmedContact.isEmpty ? nil : trimmedContact,
            errorTitle: alert.title,
            errorMessage: alert.message,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: Self.deviceModel,
            networkStatus: context.networkStatus,
            diagnostics: diagnostics,
            submittedAt: Date(),
            context: context,
            diagnosticSummary: FeedbackDiagnosticSummary(diagnostics: diagnostics),
            scheduleCacheReadFailure: await ScheduleCacheStore.readFailureAsync()
        )
        do {
            try Task.checkCancellation()
            let prepared = try await candidate.preparedForSubmission(
                credentials: [AppAccountSession.storage.currentPassword, AppAccountSession.storage.fakeCookie],
                studentID: AppAccountSession.storage.currentStudentID)
            try Task.checkCancellation()
            guard isCurrentAccount else { return false }
            let payload = submissionAttempt.prepare(prepared)
            try await submitReport(payload)
            try Task.checkCancellation()
            guard isCurrentAccount else { return false }
            submissionAttempt.finish(payload)
            resultMessage = "错误信息已提交，感谢你的帮助。"
            return true
        } catch {
            guard !TaskCancellation.matches(error), isCurrentAccount else { return false }
            resultMessage = "提交失败：\(error.localizedDescription)"
            return false
        }
    }

    private static var networkStatus: String { NetworkConnectionDescription.shared.current }

    private static var deviceModel: String {
        var info = utsname(); uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
