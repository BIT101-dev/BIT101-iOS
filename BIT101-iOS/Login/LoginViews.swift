import DesignSystemKit
//
//  LoginViews.swift
//  BIT101-iOS
//

import SwiftUI
import UIKit

/// 学校凭据在当前页面上方通过系统安全输入框收集。
@MainActor
final class SchoolPasswordPrompt {
    static let shared = SchoolPasswordPrompt()
    private let presenter: @MainActor () -> UIViewController?
    private var active: (id: UUID, alert: UIAlertController, continuation: CheckedContinuation<String, Error>)?

    init(presenter: @escaping @MainActor () -> UIViewController? = AppErrorPresenter.topViewController) {
        self.presenter = presenter
    }

    func requestPassword(studentID: String) async throws -> String {
        try Task.checkCancellation()
        let controller = try await AppErrorPresenter.availableViewController(using: presenter)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard active == nil, let controller else {
                    continuation.resume(throwing: LoginServiceError.schoolCredentialsRequired)
                    return
                }
                let alert = UIAlertController(title: "学校统一身份认证",
                    message: "学号：\(studentID)\n课表、空教室、DDL 和成绩使用学校密码。密码保存在本机钥匙串，保存后继续当前操作。",
                    preferredStyle: .alert)
                alert.addTextField { field in
                    field.placeholder = "学校统一身份认证密码"
                    field.isSecureTextEntry = true
                    field.textContentType = .password
                    field.autocapitalizationType = .none
                    field.autocorrectionType = .no
                    field.accessibilityIdentifier = "school.credentials.password"
                }
                alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
                    self?.finish(id, result: .failure(CancellationError()))
                })
                let save = UIAlertAction(title: "保存并继续", style: .default) { [weak self, weak alert] _ in
                    guard let password = alert?.textFields?.first?.text, !password.isEmpty else { return }
                    self?.finish(id, result: .success(password))
                }
                save.isEnabled = false
                alert.addAction(save)
                alert.preferredAction = save
                if let field = alert.textFields?.first {
                    field.addAction(UIAction { [weak field, weak save] _ in
                        save?.isEnabled = field?.text?.isEmpty == false
                    }, for: .editingChanged)
                }
                active = (id, alert, continuation)
                controller.present(alert, animated: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, result: .failure(CancellationError())) }
        }
    }

    private func finish(_ id: UUID, result: Result<String, Error>) {
        guard let current = active, current.id == id else { return }
        active = nil
        current.alert.textFields?.first?.text = ""
        current.alert.dismiss(animated: true) { current.continuation.resume(with: result) }
    }
}

// MARK: - Login Root

/// 登录模块根视图。
///
/// 展示应用根容器提供的登录状态与表单。
struct LoginRootView: View {
    @ObservedObject var viewModel: LoginViewModel

    /// 登录模块根视图主体。
    ///
    /// 应用根容器管理登录成功后的页面切换。
    var body: some View {
        NavigationStack {
            LoginFormView(viewModel: viewModel)
        }
    }
}

/// BIT101 账号表单。
///
/// 表单采用 SwiftUI 原生组件，沿用系统输入、焦点和辅助功能行为。
private struct LoginFormView: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    @ObservedObject var viewModel: LoginViewModel
    /// 学号和密码输入框共享焦点路由。
    @FocusState private var focusedField: LoginField?
    @State private var loginRequested = false

    /// 登录表单主体。
    var body: some View {
        Form {
            Section {
                // 学号输入完成后将焦点移到密码框，减少一次手动点按。
                TextField("", text: $viewModel.studentID, prompt: AppInputPrompt.text("学号"))
                    // 学号输入框使用可显示 QuickType 的键盘；聚焦学号框时系统提供凭据建议。
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(loginContentType(.username))
                    .submitLabel(.next)
                    .focused($focusedField, equals: .studentID)
                    .accessibilityLabel("学号")
                    .accessibilityHint("输入 BIT101 账号的学号")
                    .accessibilityIdentifier("login.student-id")
                    .onSubmit {
                    interactionEvidence?("interaction.LoginFormView.onSubmit.student-id", "submit")

                        focusedField = .password
                    }

                SecureField("", text: $viewModel.password, prompt: AppInputPrompt.text("BIT101 密码"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(loginContentType(.password))
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .accessibilityLabel("密码")
                    .accessibilityHint("输入 BIT101 密码，学校服务按需使用独立的学校密码")
                    .accessibilityIdentifier("login.password")
                    .onSubmit {
                    interactionEvidence?("interaction.LoginFormView.onSubmit.password", "submit")

                        submitLogin()
                    }
            }

            Section {
                // 登录按钮和键盘回车共用 `submitLogin()`，统一调用 `viewModel.login()`；
                // 校验、错误提示和提交态保持一致。
                Button {
                    focusedField = nil
                    submitLogin()
                } label: {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Spacer()
                        if viewModel.isSubmitting {
                            ProgressView()
                                .accessibilityHidden(true)
                        } else {
                            Text("登录")
                                .font(AppDesignSystem.Typography.bodyEmphasis)
                        }
                        Spacer()
                    }
                }
                .accessibilityLabel(viewModel.isSubmitting ? "正在登录" : "登录")
                .accessibilityHint(viewModel.isSubmitting ? "请稍候" : "使用 BIT101 账号密码登录")
                .accessibilityIdentifier("login.submit")
                .disabled(!viewModel.canSubmit)
                .appInteractiveListRow()
            }

            Section {
                NavigationLink {
                    AccountRegistrationView(studentID: viewModel.studentID)
                } label: {
                    Text("注册或重置密码")
                }
                .accessibilityIdentifier("login.register")
                .appInteractiveListRow()
            }
        }
        .navigationTitle("登录")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .task(id: loginRequested) {
            guard loginRequested else { return }
            defer { loginRequested = false }
            await viewModel.login()
        }
        .onDisappear { loginRequested = false }
    }

    private func submitLogin() {
        loginRequested = true
    }
}

private struct AccountRegistrationView: View {
    @StateObject private var viewModel: AccountRegistrationViewModel
    @FocusState private var focusedField: Field?
    @State private var requestedOperation: Operation?
    private enum Field: Hashable { case studentID, password, confirmation, schoolPassword, code }
    private enum Operation: Hashable, Sendable { case verify, submit }

    init(studentID: String) {
        _viewModel = StateObject(wrappedValue: AccountRegistrationViewModel(studentID: studentID))
    }

    var body: some View {
        Form {
            Group {
                Section {
                    TextField("", text: $viewModel.studentID, prompt: AppInputPrompt.text("学号"))
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(loginContentType(.username))
                        .focused($focusedField, equals: .studentID)
                        .accessibilityLabel("学号")
                        .accessibilityIdentifier("registration.student-id")
                    SecureField("", text: $viewModel.password, prompt: AppInputPrompt.text("BIT101 新密码"))
                        .textContentType(loginContentType(.newPassword))
                        .focused($focusedField, equals: .password)
                        .accessibilityLabel("BIT101 新密码")
                        .accessibilityIdentifier("registration.password")
                    SecureField("", text: $viewModel.confirmation, prompt: AppInputPrompt.text("确认密码"))
                        .textContentType(loginContentType(.newPassword))
                        .focused($focusedField, equals: .confirmation)
                        .accessibilityLabel("确认密码")
                        .accessibilityIdentifier("registration.confirmation")
                }

                Section {
                    Picker("验证方式", selection: $viewModel.method) {
                        ForEach(RegistrationVerificationMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .accessibilityIdentifier("registration.method")
                    .appSelectionFeedback(trigger: viewModel.method)
                    .appInteractiveListRow()
                    if viewModel.method == .school {
                        SecureField("", text: $viewModel.schoolPassword, prompt: AppInputPrompt.text("学校统一身份认证密码"))
                            .textContentType(loginContentType(.password))
                            .focused($focusedField, equals: .schoolPassword)
                            .accessibilityLabel("学校统一身份认证密码")
                            .accessibilityIdentifier("registration.school-password")
                        if viewModel.verified {
                            Label("身份验证成功", systemImage: "checkmark.circle")
                                .foregroundStyle(AppDesignSystem.Palette.Status.success)
                        }
                        Button("验证身份") { verify() }
                            .disabled(!viewModel.canVerify || viewModel.verified)
                            .accessibilityIdentifier("registration.verify")
                            .appInteractiveListRow()
                    } else {
                        TextField("", text: $viewModel.code, prompt: AppInputPrompt.text("6 位验证码"))
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($focusedField, equals: .code)
                            .accessibilityLabel("6 位验证码")
                            .accessibilityIdentifier("registration.code")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(ceil(viewModel.resendAt.timeIntervalSince(context.date))))
                            Button(remaining > 0 ? "\(remaining) 秒后重新发送" : "发送验证码") { verify() }
                                .disabled(!viewModel.canVerify || remaining > 0)
                                .accessibilityIdentifier("registration.send-code")
                                .appInteractiveListRow()
                        }
                    }
                    if viewModel.isVerifying { AppInlineLoadingState("正在验证") }
                }

                Section {
                    Button {
                        focusedField = nil
                        requestedOperation = .submit
                    } label: {
                        if viewModel.isSubmitting { AppInlineLoadingState("正在提交") }
                        else { Text("注册或重置并登录") }
                    }
                    .disabled(!viewModel.canSubmit)
                    .appInteractiveListRow()
                    .accessibilityIdentifier("registration.submit")
                }
            }
            .disabled(viewModel.isBusy || requestedOperation != nil)
        }
        .navigationTitle("注册或重置密码")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .diagnosticAlert(item: $viewModel.alert)
        .task(id: requestedOperation) {
            guard let requestedOperation else { return }
            defer { self.requestedOperation = nil }
            switch requestedOperation {
            case .verify: await viewModel.verify()
            case .submit: await viewModel.submit()
            }
        }
        .onDisappear { requestedOperation = nil }
    }

    private func verify() {
        focusedField = nil
        requestedOperation = .verify
    }
}

/// 登录表单里的焦点路由枚举。
///
/// 焦点路由包含学号和密码两项，枚举让焦点切换逻辑保持明确并支持扩展。
private enum LoginField: Hashable {
    case studentID
    case password
}


private func loginContentType(_ type: UITextContentType) -> UITextContentType {
#if BIT101_UI_TESTING
    return AppFileDirectories.isRunningUITest ? .oneTimeCode : type
#else
    return type
#endif
}
