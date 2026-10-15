import DesignSystemKit
//
//  LoginViews.swift
//  BIT101-iOS
//

import SwiftUI

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

/// 登录方式与账号表单。
///
/// 表单采用 SwiftUI 原生组件，沿用系统输入、焦点和辅助功能行为。
private struct LoginFormView: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    @ObservedObject var viewModel: LoginViewModel
    /// 学号和密码输入框共享焦点路由。
    @FocusState private var focusedField: LoginField?

    /// 登录表单主体。
    var body: some View {
        Form {
            Section {
                Picker("登录方式", selection: $viewModel.method) {
                    ForEach(LoginMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .accessibilityIdentifier("login.method")
                .appSelectionFeedback(trigger: viewModel.method)
                .appInteractiveListRow()
                .onChange(of: viewModel.method) { _, _ in viewModel.password = "" }
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
                    .accessibilityHint("输入学校统一身份认证学号")
                    .accessibilityIdentifier("login.student-id")
                    .onSubmit {
                    interactionEvidence?("interaction.LoginFormView.onSubmit.student-id", "submit")

                        focusedField = .password
                    }

                SecureField("", text: $viewModel.password, prompt: AppInputPrompt.text("密码"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(loginContentType(.password))
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .accessibilityLabel("密码")
                    .accessibilityHint(viewModel.method == .school ? "输入学校统一身份认证密码" : "输入 BIT101 账号密码")
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
                .accessibilityHint(viewModel.isSubmitting ? "请稍候" : (viewModel.method == .school ? "提交学校统一身份认证账号密码" : "提交 BIT101 账号密码"))
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
        .safeAreaInset(edge: .bottom, spacing: AppDesignSystem.Spacing.none) {
            Link(destination: AppLegalInfo.icpPublicNoticeURL) {
                Text(AppLegalInfo.icpDisplayText)
                    .font(AppDesignSystem.Typography.footnote)
                    .foregroundStyle(AppDesignSystem.Palette.Status.neutral)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AppDesignSystem.Spacing.section)
                    .padding(.top, AppDesignSystem.Spacing.tiny)
                    .padding(.bottom, AppDesignSystem.Spacing.regular)
                    .background(.regularMaterial)
            }
                .accessibilityIdentifier("ui.login-form-view.icp")
        }
    }

    private func submitLogin() {
        Task { await viewModel.login() }
    }
}

private struct AccountRegistrationView: View {
    @StateObject private var viewModel: AccountRegistrationViewModel
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case studentID, password, confirmation, schoolPassword, code }

    init(studentID: String) {
        _viewModel = StateObject(wrappedValue: AccountRegistrationViewModel(studentID: studentID))
    }

    var body: some View {
        Form {
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
            } footer: {
                Text("设置至少 8 位的 BIT101 密码，用于 App 和网页端登录。已有账号完成验证后将重置密码。")
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
            } footer: {
                if viewModel.method == .email {
                    Text("验证码将发送至 \(viewModel.account)@bit.edu.cn。课表等学校服务需使用统一身份认证登录。")
                }
            }

            Section {
                Button {
                    focusedField = nil
                    Task { await viewModel.submit() }
                } label: {
                    if viewModel.isSubmitting { AppInlineLoadingState("正在提交") }
                    else { Text("注册或重置并登录") }
                }
                .disabled(!viewModel.canSubmit)
                .appInteractiveListRow()
                .accessibilityIdentifier("registration.submit")
            }
        }
        .disabled(viewModel.isBusy)
        .navigationTitle("注册或重置密码")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .diagnosticAlert(item: $viewModel.alert)
    }

    private func verify() {
        focusedField = nil
        Task { await viewModel.verify() }
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
