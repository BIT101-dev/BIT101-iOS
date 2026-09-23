//
//  LoginViews.swift
//  BIT101-iOS
//

import SwiftUI

// MARK: - Login Root

/// 登录模块根视图。
///
/// 根据 `LoginViewModel` 的状态，在登录表单和主应用壳层之间切换。
/// 有本地会话时立即挂载主壳层，后台静默完成登录校验。
struct LoginRootView: View {
    /// 登录模块唯一状态机。
    @StateObject private var viewModel = LoginViewModel()

    /// 登录模块根视图主体。
    ///
    /// 根视图根据 `screenState` 在“登录表单”和“主壳层”之间切换，复杂路由由对应页面承接。
    var body: some View {
        Group {
            switch viewModel.screenState {
            case .signedOut:
                NavigationStack {
                    LoginFormView(viewModel: viewModel)
                }
            case let .signedIn(studentID):
                AppShellView(studentID: studentID, onLogout: viewModel.logout)
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .diagnosticAlert(item: $viewModel.alert)
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
                    .textContentType(.username)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .studentID)
                    .accessibilityLabel("学号")
                    .accessibilityHint("输入学校统一身份认证学号")
                    .onSubmit {
                        focusedField = .password
                    }

                SecureField("", text: $viewModel.password, prompt: AppInputPrompt.text("密码"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .accessibilityLabel("密码")
                    .accessibilityHint("输入学校统一身份认证密码")
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
                .disabled(!viewModel.canSubmit)
            }
        }
        .navigationTitle("登录")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Link(destination: AppLegalInfo.icpPublicNoticeURL) {
                Text(AppLegalInfo.icpDisplayText)
                    .font(AppDesignSystem.Typography.footnote)
                    .foregroundStyle(AppDesignSystem.Palette.neutral)
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
