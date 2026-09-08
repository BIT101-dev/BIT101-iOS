import Foundation
import Combine
import Network
import SwiftUI
import UIKit

private enum DiagnosticAlertRules {
    static let diagnosticTitleMarkers = ["失败", "错误", "异常", "无法", "超时", "未找到", "验证已失效", "加载"]

    static func allowsDiagnostics(for title: String) -> Bool {
        diagnosticTitleMarkers.contains { title.contains($0) }
    }
}

protocol DiagnosticAlertPresentable: Identifiable {
    var title: String { get }
    var message: String { get }
    var allowsDiagnostics: Bool { get }
}

extension DiagnosticAlertPresentable {
    var allowsDiagnostics: Bool {
        DiagnosticAlertRules.allowsDiagnostics(for: title)
    }
}

extension AppAlert: DiagnosticAlertPresentable {}
extension ScheduleNotice: DiagnosticAlertPresentable {
    var allowsDiagnostics: Bool {
        guard !message.contains("课表未发布"), !message.contains("课表尚未发布") else { return false }
        guard !title.contains("需要短信验证"), !message.contains("短信二次验证") else { return false }
        return DiagnosticAlertRules.allowsDiagnostics(for: title)
    }
}
extension MapNotice: DiagnosticAlertPresentable {}

/// 反馈载荷标记本地 Debug 安装或正式 Release 构建，用户身份字段保持空缺。
enum AppBuildEnvironment {
#if DEBUG
    static let isDevelopment = true
#else
    static let isDevelopment = false
#endif
}

private nonisolated final class NetworkConnectionDescription: @unchecked Sendable {
    static let shared = NetworkConnectionDescription()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var value = "检测中"

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let description: String
            if path.status != .satisfied { description = "未连接" }
            else if path.usesInterfaceType(.wifi) { description = "Wi-Fi" }
            else if path.usesInterfaceType(.cellular) { description = "蜂窝网络" }
            else { description = "已连接" }
            self?.lock.lock(); self?.value = description; self?.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "dev.aihelpme.bit101.network-report"))
    }

    var current: String {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

struct NetworkDiagnosticRecord: Codable, Identifiable {
    let id: UUID
    let occurredAt: Date
    let method: String
    let url: String
    let statusCode: Int?
    let elapsedMilliseconds: Int
    let error: String?
    let responseHeaders: [String: String]
    let responseBody: String?
}

actor NetworkDiagnosticStore {
    static let shared = NetworkDiagnosticStore()
    private var records: [NetworkDiagnosticRecord] = []

    func record(request: URLRequest, data: Data?, response: URLResponse?, error: Error?, elapsed: TimeInterval) {
        _ = NetworkConnectionDescription.shared.current
        guard request.url?.host?.lowercased() != "feedback.aihelpme.dev" else { return }
        let http = response as? HTTPURLResponse
        let headers = http?.allHeaderFields.reduce(into: [String: String]()) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        } ?? [:]
        let body = data.flatMap { data -> String? in
            let limited = data.prefix(256 * 1024)
            return String(data: limited, encoding: .utf8) ?? "[非文本响应，\(data.count) 字节]"
        }
        records.append(NetworkDiagnosticRecord(
            id: UUID(), occurredAt: Date(), method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "", statusCode: http?.statusCode,
            elapsedMilliseconds: Int(elapsed * 1_000), error: error?.localizedDescription,
            responseHeaders: headers, responseBody: body
        ))
        records = Array(records.suffix(20))
    }

    func recent() -> [NetworkDiagnosticRecord] { Array(records.suffix(10)) }

    /// 返回最近一次学校网页请求的安全外链；URL 移除 query 和 fragment，ticket、token
    /// 等一次性认证参数留在诊断记录中。网页入口限定为学校网页请求。
    func latestSchoolServicePageURL() -> URL? {
        let schoolHosts = Set([
            "sso.bit.edu.cn",
            "webvpn.bit.edu.cn",
            "jxzxehall.bit.edu.cn",
            "jxzxehallapp.bit.edu.cn"
        ])

        for record in records.reversed() {
            let bodyIndicatesFailure = record.responseBody?.localizedCaseInsensitiveContains("error") == true
                || record.responseBody?.localizedCaseInsensitiveContains("certificate") == true
            let failed = record.error != nil || (record.statusCode ?? 200) >= 400 || bodyIndicatesFailure
            guard failed else { continue }
            guard let url = URL(string: record.url),
                  let host = url.host?.lowercased(),
                  schoolHosts.contains(host)
            else { continue }

            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            components?.fragment = nil
            if let pageURL = components?.url {
                return HTTPSURLUpgrade.upgradedURL(from: pageURL)
            }
        }
        return nil
    }
}

enum ErrorReportRedactor {
    private static let protectedNames = [
        "password", "passwd", "pwd", "cookie", "set-cookie", "authorization", "token",
        "access_token", "refresh_token", "challenge_token", "fake-cookie",
        "accessToken", "refreshToken", "challengeToken", "fakeCookie", "session", "sessionID", "ticket"
    ]

    static func forced(_ value: String) -> String {
        var output = value
        for name in protectedNames {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let jsonPattern = "(?i)(\"\(escaped)\"\\s*:\\s*\")[^\"]*(\")"
            let keyValuePattern = "(?i)(\\b\(escaped)\\s*[=:]\\s*)[^&\\s,;]+"
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
            networkStatus: Self.networkStatus,
            diagnostics: selected
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
        headers.mapValues(ErrorReportRedactor.forced)
            .reduce(into: [:]) { result, pair in
                let key = pair.key
                result[key] = ["authorization", "cookie", "set-cookie"].contains(key.lowercased()) ? "[REDACTED]" : pair.value
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

private struct AppErrorPresentation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let allowsDiagnostics: Bool
    let schoolServiceURL: URL?

    var allowsSchoolServiceLink: Bool { allowsDiagnostics && schoolServiceURL != nil }

    static var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

extension AppErrorPresentation: DiagnosticAlertPresentable {}

/// 统一从当前最顶层 UIViewController 呈现原生 Alert，让 Alert 在 Sheet 之上显示。
@MainActor
final class AppErrorPresenter {
    static let shared = AppErrorPresenter()
    private var queue: [AppErrorPresentation] = []
    private var isPresenting = false
    private var reportDelegate: ReportPresentationDelegate?
    private weak var reportController: UIViewController?
    private var presentationGeneration = 0

    private init() {}

    /// 账号切换后清空旧账号错误，让登录页保持当前账号状态。
    func reset() {
        presentationGeneration += 1
        queue.removeAll()
        reportController?.dismiss(animated: false)
        reportController = nil
        reportDelegate = nil
        isPresenting = false

        if let presenter = Self.topViewController(), let alert = presenter as? UIAlertController {
            alert.dismiss(animated: false)
        }
    }

    func present(_ alert: any DiagnosticAlertPresentable) {
        let generation = presentationGeneration
        Task { @MainActor [weak self] in
            let schoolServiceURL = await NetworkDiagnosticStore.shared.latestSchoolServicePageURL()
            guard let self, self.presentationGeneration == generation else { return }
            queue.append(AppErrorPresentation(
                title: alert.title,
                message: alert.message,
                allowsDiagnostics: alert.allowsDiagnostics,
                schoolServiceURL: schoolServiceURL
            ))
            presentNextIfPossible()
        }
    }

    private func presentNextIfPossible() {
        guard !isPresenting, !queue.isEmpty else { return }
        guard let presenter = Self.topViewController(), !presenter.isBeingDismissed else {
            retryPresentation(); return
        }
        if presenter is UIAlertController {
            retryPresentation(); return
        }

        isPresenting = true
        let item = queue.removeFirst()
        let message = item.allowsDiagnostics
            ? "\(item.message)\n\n版本 \(AppErrorPresentation.versionText)"
            : item.message
        let controller = UIAlertController(title: item.title, message: message, preferredStyle: .alert)

        if item.allowsDiagnostics {
            controller.addAction(UIAlertAction(title: "查看是否有更新", style: .default) { [weak self] _ in
                UIApplication.shared.open(BIT101AppStore.url)
                self?.finishAlert()
            })
            controller.addAction(UIAlertAction(title: "向开发者分享错误信息", style: .default) { [weak self] _ in
                self?.presentReportSheet(for: item)
            })
            if item.allowsSchoolServiceLink {
                controller.addAction(UIAlertAction(title: "万一学校服务 g 了？", style: .default) { [weak self] _ in
                    if let schoolServiceURL = item.schoolServiceURL {
                        UIApplication.shared.open(schoolServiceURL)
                    }
                    self?.finishAlert()
                })
            }
        }
        let dismissAction = UIAlertAction(title: "知道了", style: .cancel) { [weak self] _ in
            self?.finishAlert()
        }
        controller.addAction(dismissAction)
        controller.preferredAction = dismissAction
        presenter.present(controller, animated: true)
    }

    private func presentReportSheet(for item: AppErrorPresentation) {
        presentReportSheet(for: item, generation: presentationGeneration)
    }

    private func presentReportSheet(for item: AppErrorPresentation, generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.presentationGeneration == generation else { return }
            guard let presenter = Self.topViewController(), !(presenter is UIAlertController) else {
                retryReportSheet(for: item, generation: generation)
                return
            }
            let controller = UIHostingController(rootView: ErrorReportSheet(alert: item) { [weak self] in
                self?.finishReportSheet()
            })
            controller.modalPresentationStyle = .pageSheet
            let delegate = ReportPresentationDelegate { [weak self] in self?.finishReportSheet() }
            reportDelegate = delegate
            reportController = controller
            controller.presentationController?.delegate = delegate
            presenter.present(controller, animated: true)
        }
    }

    private func retryReportSheet(for item: AppErrorPresentation, generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.presentationGeneration == generation else { return }
            self.presentReportSheet(for: item, generation: generation)
        }
    }

    private func finishAlert() {
        isPresenting = false
        presentNextIfPossible()
    }

    private func finishReportSheet() {
        guard isPresenting else { return }
        isPresenting = false
        reportController = nil
        reportDelegate = nil
        let generation = presentationGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.presentationGeneration == generation else { return }
            self.presentNextIfPossible()
        }
    }

    private func retryPresentation() {
        let generation = presentationGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.presentationGeneration == generation else { return }
            self.presentNextIfPossible()
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return nil }

        func descend(_ controller: UIViewController) -> UIViewController {
            if let presented = controller.presentedViewController, !presented.isBeingDismissed {
                return descend(presented)
            }
            if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController {
                return descend(visible)
            }
            if let tab = controller as? UITabBarController, let selected = tab.selectedViewController {
                return descend(selected)
            }
            return controller
        }
        return descend(root)
    }
}

private final class ReportPresentationDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
    let onDismiss: () -> Void
    init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onDismiss() }
}

private struct DiagnosticAlertModifier<Item: DiagnosticAlertPresentable>: ViewModifier {
    @Binding var item: Item?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: forwardIfNeeded)
            .onChange(of: item?.id) { _, _ in forwardIfNeeded() }
    }

    private func forwardIfNeeded() {
        guard let alert = item else { return }
        item = nil
        AppErrorPresenter.shared.present(alert)
    }
}

extension View {
    func diagnosticAlert<Item: DiagnosticAlertPresentable>(item: Binding<Item?>) -> some View {
        modifier(DiagnosticAlertModifier(item: item))
    }
}

struct DiagnosticRecoveryActions: View {
    let title: String
    let message: String
    @State private var reportAlert: AppAlert?
    @State private var schoolServiceURL: URL?

    var body: some View {
        VStack(spacing: AppDesignSystem.Spacing.control) {
            Link("查看是否有更新", destination: BIT101AppStore.url)
            if let schoolServiceURL {
                Link("万一学校服务 g 了？", destination: schoolServiceURL)
                    .foregroundStyle(.secondary)
            }
            Button("向开发者分享错误信息") {
                reportAlert = AppAlert(title: title, message: message)
            }
        }
        .task {
            schoolServiceURL = await NetworkDiagnosticStore.shared.latestSchoolServicePageURL()
        }
        .sheet(item: $reportAlert) { ErrorReportSheet(alert: $0) }
    }
}

private struct ErrorReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ErrorReportViewModel
    @State private var confirmsRaw = false
    let onClose: (() -> Void)?

    init(alert: any DiagnosticAlertPresentable, onClose: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: ErrorReportViewModel(alert: alert))
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("内容", selection: $viewModel.mode) {
                        ForEach(ErrorReportViewModel.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .appSelectionFeedback(trigger: viewModel.mode)
                    modeExplanation
                } header: {
                    Text("选择提交内容")
                } footer: {
                    VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                        Text("本次错误")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .textCase(nil)
                        Text(viewModel.alert.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(viewModel.alert.message)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("包含最近 \(viewModel.diagnostics.count) 条网络记录")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)

                        if let message = viewModel.resultMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, AppDesignSystem.Spacing.content)
                }
                Section("留言（可选）") {
                    TextField("可补充问题现象或复现步骤", text: $viewModel.comment, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("分享错误信息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { close() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.isSubmitting ? "提交中" : "提交") {
                        if viewModel.mode == .raw { confirmsRaw = true }
                        else { Task { if await viewModel.submit() { close() } } }
                    }.disabled(viewModel.isSubmitting)
                }
            }
            .task { await viewModel.load() }
            .alert("确认提交原始网络响应？", isPresented: $confirmsRaw) {
                Button("确认提交") {
                    Task { if await viewModel.submit() { close() } }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("你选择了原始网络响应，其中可能包含你的学号、姓名、课程、成绩等个人信息。\n\n密码、Cookie、Token 等认证信息会强制脱敏。\n\n提交后，开发者仅将这些信息用于排查本 App 的故障，不用于其他用途，不会公开传播，并会在排查完成后删除。如需了解信息利用情况，可通过 systemd@linux.do 联系开发者。")
            }
        }
    }

    private func close() {
        dismiss()
        onClose?()
    }

    @ViewBuilder
    private var modeExplanation: some View {
        if viewModel.mode == .sanitized {
            (
                Text("仅包含 App 版本、设备与系统信息、网络状态、请求接口、状态码等；")
                    .foregroundColor(.secondary)
                + Text("系统会自动隐藏密码、Cookie、Token、姓名、学号等敏感字段。")
                    .bold()
                    .foregroundStyle(AppDesignSystem.Palette.accent)
            )
            .font(.footnote)
        } else {
            (
                Text("包含接口返回的原始内容，")
                    .foregroundColor(.secondary)
                + Text("可能包含学号、姓名、课程、成绩等个人信息。")
                    .bold()
                    .foregroundStyle(AppDesignSystem.Palette.accent)
                + Text("密码、Cookie、Token 等认证信息仍会强制脱敏。")
                    .bold()
                    .foregroundColor(.secondary)
            )
            .font(.footnote)
        }
    }

}
