import TransportCore
import DesignSystemKit
import Foundation
import Combine
import UIKit



/// 反馈载荷标记本地 Debug 安装或正式 Release 构建，用户身份字段保持空缺。
enum AppBuildEnvironment {
#if DEBUG
    static let isDevelopment = true
#else
    static let isDevelopment = false
#endif
}

enum ErrorReportRedactor {
    private static let protectedNames = [
        "password", "passwd", "pwd", "cookie", "set-cookie", "authorization", "proxy-authorization", "token",
        "access_token", "refresh_token", "challenge_token", "fake-cookie",
        "accessToken", "refreshToken", "challengeToken", "fakeCookie", "session", "sessionID",
        "session_id", "sessionid", "ticket", "api-key", "api_key", "apikey", "client_secret",
        "secret", "captcha", "captcha_payload", "croypto", "execution", "salt"
    ]

    private static func redactObject(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = protectedNames.contains { entry.key.localizedCaseInsensitiveContains($0) }
                    ? "[REDACTED]" : redactObject(entry.value)
            }
        }
        if let array = value as? [Any] { return array.map(redactObject) }
        if let text = value as? String { return forced(text) }
        return value
    }

    private static func redactHTML(_ value: String) -> String {
        guard let tags = try? NSRegularExpression(pattern: #"<input\b(?:[^>"']|"[^"]*(?:"|$)|'[^']*(?:'|$))*(?:>|$)|<textarea\b(?:[^>"']|"[^"]*"|'[^']*')*>[\s\S]*?(?:</textarea\s*>|$)"#, options: .caseInsensitive),
              let fields = try? NSRegularExpression(pattern: #"\b(?:id|name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#, options: .caseInsensitive)
        else { return value }
        var output = value
        for tag in tags.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let range = Range(tag.range, in: output) else { continue }
            let text = String(output[range])
            let identifiers = fields.matches(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { match in
                (1...3).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
            }
            guard identifiers.contains(where: { field in
                ["login-page-flowkey", "login-croypto"].contains(field.lowercased())
                    || protectedNames.contains { field.localizedCaseInsensitiveContains($0) }
            }) else { continue }
            var masked = text.replacingOccurrences(of: #"(?i)(\bvalue\s*=\s*)(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|[^\s"'=<>`]+)"#,
                with: "$1\"[REDACTED]\"", options: .regularExpression)
            if text.lowercased().hasPrefix("<textarea") {
                masked = masked.replacingOccurrences(of: #"(?i)(>)[\s\S]*(</textarea\s*>|$)"#, with: "$1[REDACTED]$2", options: .regularExpression)
            }
            output.replaceSubrange(range, with: masked)
        }
        return output
    }

    private static func decodedPercent(_ value: String) -> String {
        var output = value
        while let decoded = output.removingPercentEncoding, decoded != output { output = decoded }
        return output
    }

    private static func redactURLs(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: .caseInsensitive) else { return value }
        var output = value
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            guard var url = URLComponents(string: String(output[range])) else {
                output.replaceSubrange(range, with: "[REDACTED]"); continue
            }
            if url.user != nil || url.password != nil { url.user = "[REDACTED]"; url.password = nil }
            if url.percentEncodedFragment != nil {
                var fragmentFields = URLComponents()
                fragmentFields.query = url.fragment ?? ""
                let candidates = [decodedPercent(url.fragment ?? "")] + (fragmentFields.queryItems ?? []).map { decodedPercent($0.name) }
                if url.fragment == nil || candidates.contains(where: { value in
                    protectedNames.contains { value.localizedCaseInsensitiveContains($0) }
                }) { url.fragment = "[REDACTED]" }
            }
            url.queryItems = url.queryItems?.map { item in
                let name = decodedPercent(item.name)
                if protectedNames.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                    return URLQueryItem(name: item.name, value: "[REDACTED]")
                }
                let decoded = item.value.map(decodedPercent)
                let nested = decoded.flatMap { $0.range(of: #"https?://"#, options: [.regularExpression, .caseInsensitive]) == nil ? nil : redactURLs($0) }
                return URLQueryItem(name: item.name, value: nested ?? item.value)
            }
            output.replaceSubrange(range, with: url.string ?? "[REDACTED]")
        }
        return output
    }

    static func forced(_ value: String) -> String {
        var structured = value
        if let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)),
           let bytes = try? JSONSerialization.data(withJSONObject: redactObject(object)),
           let json = String(data: bytes, encoding: .utf8) {
            structured = json
        } else {
            // 截断 JSON 的凭据范围按完整响应遮盖。
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { structured = "[REDACTED]" }
        }
        var output = redactHTML(redactURLs(structured)).replacingOccurrences(
            of: "(?i)((?:authorization|proxy-authorization|cookie|set-cookie)\\s*[=:]\\s*)[^&\\r\\n]+",
            with: "$1[REDACTED]", options: .regularExpression
        )
        for name in protectedNames {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let jsonPattern = "(?i)(\"\(escaped)\"\\s*:\\s*\")(?:\\\\.|[^\"\\\\])*(\")"
            let keyValuePattern = "(?i)(\\b\(escaped)\\s*[=:]\\s*)[^&\\r\\n,;]+"
            output = output.replacingOccurrences(of: jsonPattern, with: "$1[REDACTED]$2", options: .regularExpression)
            output = output.replacingOccurrences(of: keyValuePattern, with: "$1[REDACTED]", options: .regularExpression)
        }
        let credentials = [AppAccountSession.storage.currentPassword, AppAccountSession.storage.fakeCookie]
            .filter { !$0.isEmpty }
        for credential in credentials { output = output.replacingOccurrences(of: credential, with: "[REDACTED]") }
        return output
    }

    static func sanitized(_ value: String) -> String {
        var output = forced(value)
        let studentID = AppAccountSession.storage.currentStudentID
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
}

struct FeedbackDeviceContext: Encodable {
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

struct FeedbackDiagnosticSummary: Encodable {
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

private struct ErrorReportPayload: Encodable {
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
    let diagnostics: [NetworkDiagnosticRecord]
    let submittedAt: Date
    let context: FeedbackDeviceContext
    let diagnosticSummary: FeedbackDiagnosticSummary
}

private enum FeedbackSubmissionError: LocalizedError {
    case server(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
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
    let temporaryRecordRemoved: Bool
    let quotaReserved: Bool
}
#endif

/// 错误报告与开发者建议共用的反馈提交入口。
struct FeedbackSubmissionClient {
    static func submit<Payload: Encodable>(_ payload: Payload) async throws {
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
    }

#if DEBUG || RELEASE_NETWORK_SMOKE
    static func submitNetworkSmoke(runID: String) async throws {
        var request = URLRequest(url: AppURL.required("https://feedback.aihelpme.dev/api/error-reports"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
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
        let result = try JSONDecoder().decode(NetworkSmokeResponse.self, from: data)
        guard result.ok, result.temporaryRecordRemoved, result.quotaReserved else {
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

    init(alert: any DiagnosticAlertPresentable) {
        self.alert = alert
        accountSubscription = AppAccountSession.storage.changes.sink { [weak self] _ in
            guard let self, AppAccountSession.storage.schoolSessionIdentity != self.identity else { return }
            self.diagnostics = []
            self.resultMessage = "账号已更新，请重新打开反馈页面。"
        }
    }

    func load() async {
        let current = await NetworkDiagnosticStore.shared.recent()
        diagnostics = AppAccountSession.storage.schoolSessionIdentity == identity ? current : []
    }

    func submit() async -> Bool {
        guard AppAccountSession.storage.schoolSessionIdentity == identity else {
            diagnostics = []
            resultMessage = "账号已更新，请重新打开反馈页面。"
            return false
        }
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        let selected = diagnostics.map { record in
            NetworkDiagnosticRecord(
                id: record.id, occurredAt: record.occurredAt, method: record.method,
                url: mode == .sanitized ? sanitizedURL(record.url) : ErrorReportRedactor.forced(record.url),
                statusCode: record.statusCode, elapsedMilliseconds: record.elapsedMilliseconds,
                error: record.error.map(viewModelRedactor),
                responseHeaders: mode == .raw ? redactHeaders(record.responseHeaders) : [:],
                responseBody: mode == .raw ? record.responseBody.map(ErrorReportRedactor.forced) : nil
            )
        }
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = FeedbackDeviceContext.current
        let payload = ErrorReportPayload(
            mode: mode.rawValue,
            isDevelopmentBuild: AppBuildEnvironment.isDevelopment,
            comment: trimmedComment.isEmpty ? nil : viewModelRedactor(trimmedComment),
            contact: trimmedContact.isEmpty ? nil : ErrorReportRedactor.forced(trimmedContact),
            errorTitle: viewModelRedactor(alert.title),
            errorMessage: viewModelRedactor(alert.message),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: Self.deviceModel,
            networkStatus: context.networkStatus,
            diagnostics: selected,
            submittedAt: Date(),
            context: context,
            diagnosticSummary: FeedbackDiagnosticSummary(diagnostics: selected)
        )
        do {
            try await FeedbackSubmissionClient.submit(payload)
            resultMessage = "错误信息已提交，感谢你的帮助。"
            return true
        } catch {
            resultMessage = "提交失败：\(error.localizedDescription)"
            return false
        }
    }

    private func viewModelRedactor(_ value: String) -> String {
        mode == .sanitized ? ErrorReportRedactor.sanitized(value) : ErrorReportRedactor.forced(value)
    }

    private func sanitizedURL(_ string: String) -> String {
        guard var components = URLComponents(string: string) else { return ErrorReportRedactor.forced(string) }
        components.query = components.queryItems?.map { "\($0.name)=[REDACTED]" }.joined(separator: "&")
        components.fragment = nil
        return ErrorReportRedactor.forced(components.string ?? string)
    }

    private func redactHeaders(_ headers: [String: String]) -> [String: String] {
        let sensitiveNames: Set<String> = [
            "authorization", "proxy-authorization", "cookie", "set-cookie",
            "x-api-key", "x-auth-token", "x-access-token"
        ]
        return headers.mapValues(ErrorReportRedactor.forced)
            .reduce(into: [:]) { result, pair in
                let key = pair.key
                result[key] = sensitiveNames.contains(key.lowercased()) ? "[REDACTED]" : pair.value
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
