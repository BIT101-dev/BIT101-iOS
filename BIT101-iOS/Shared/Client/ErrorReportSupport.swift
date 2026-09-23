import Foundation
import Combine
import UIKit

protocol DiagnosticAlertPresentable: Identifiable {
    var title: String { get }
    var message: String { get }
    var allowsDiagnostics: Bool { get }
    var showsRecoveryLinks: Bool { get }
}

extension AppAlert: DiagnosticAlertPresentable {}
extension ScheduleNotice: DiagnosticAlertPresentable {}
extension MapNotice: DiagnosticAlertPresentable {}

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
        "password", "passwd", "pwd", "cookie", "set-cookie", "authorization", "token",
        "access_token", "refresh_token", "challenge_token", "fake-cookie",
        "accessToken", "refreshToken", "challengeToken", "fakeCookie", "session", "sessionID",
        "session_id", "sessionid", "ticket", "api-key", "api_key", "apikey", "client_secret",
        "secret", "captcha", "captcha_payload", "croypto", "execution", "salt"
    ]

    static func forced(_ value: String) -> String {
        var output = value
        for name in protectedNames {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let jsonPattern = "(?i)(\"\(escaped)\"\\s*:\\s*\")[^\"]*(\")"
            let keyValuePattern = "(?i)(\\b\(escaped)\\s*[=:]\\s*)[^&\\r\\n,;]+"
            output = output.replacingOccurrences(of: jsonPattern, with: "$1[REDACTED]$2", options: .regularExpression)
            output = output.replacingOccurrences(of: keyValuePattern, with: "$1[REDACTED]", options: .regularExpression)
        }
        let credentials = [LoginStorage.shared.currentPassword, LoginStorage.shared.fakeCookie]
            .filter { !$0.isEmpty }
        for credential in credentials { output = output.replacingOccurrences(of: credential, with: "[REDACTED]") }
        return output
    }

    static func sanitized(_ value: String) -> String {
        var output = forced(value)
        let studentID = LoginStorage.shared.currentStudentID
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
    let restored: Bool
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
        guard result.ok, result.restored else {
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
    @Published var diagnostics: [NetworkDiagnosticRecord] = []
    @Published var isSubmitting = false
    @Published var resultMessage: String?
    let alert: any DiagnosticAlertPresentable

    init(alert: any DiagnosticAlertPresentable) { self.alert = alert }

    func load() async { diagnostics = await NetworkDiagnosticStore.shared.recent() }

    func submit() async -> Bool {
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
        let context = FeedbackDeviceContext.current
        let payload = ErrorReportPayload(
            mode: mode.rawValue,
            isDevelopmentBuild: AppBuildEnvironment.isDevelopment,
            comment: trimmedComment.isEmpty ? nil : viewModelRedactor(trimmedComment),
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

