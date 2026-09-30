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

/// 统一身份认证登录表单。
///
/// 表单采用 SwiftUI 原生组件，沿用系统输入、焦点和辅助功能行为。
private struct LoginFormView: View {
    @ObservedObject var viewModel: LoginViewModel
    /// 学号和密码输入框共享焦点路由。
    @FocusState private var focusedField: LoginField?

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
#if BIT101_UI_TESTING
                    .textContentType(AppFileDirectories.isRunningUITest ? .oneTimeCode : .username)
#else
                    .textContentType(.username)
#endif
                    .submitLabel(.next)
                    .focused($focusedField, equals: .studentID)
                    .accessibilityLabel("学号")
                    .accessibilityHint("输入学校统一身份认证学号")
                    .accessibilityIdentifier("login.student-id")
                    .onSubmit {
                        focusedField = .password
                    }

                SecureField("", text: $viewModel.password, prompt: AppInputPrompt.text("密码"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
#if BIT101_UI_TESTING
                    .textContentType(AppFileDirectories.isRunningUITest ? .oneTimeCode : .password)
#else
                    .textContentType(.password)
#endif
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .accessibilityLabel("密码")
                    .accessibilityHint("输入学校统一身份认证密码")
                    .accessibilityIdentifier("login.password")
                    .onSubmit {
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
                .accessibilityHint(viewModel.isSubmitting ? "请稍候" : "提交学校统一身份认证账号密码")
                .accessibilityIdentifier("login.submit")
                .disabled(!viewModel.canSubmit)
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
        }
    }

    private func submitLogin() {
        Task { await viewModel.login() }
    }
}

/// 登录表单里的焦点路由枚举。
///
/// 焦点路由包含学号和密码两项，枚举让焦点切换逻辑保持明确并支持扩展。
private enum LoginField: Hashable {
    case studentID
    case password
}
