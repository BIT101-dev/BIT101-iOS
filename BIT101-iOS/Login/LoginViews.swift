//
//  LoginViews.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
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
/// 内容结构参考 Android 版本，组件使用 SwiftUI 原生组件。
private struct LoginFormView: View {
    @ObservedObject var viewModel: LoginViewModel
    /// 学号和密码输入框共享焦点路由。
    @FocusState private var focusedField: LoginField?

    /// 登录表单主体。
    var body: some View {
        ZStack(alignment: .bottom) {
            Form {
                Section {
                    // 学号输入完成后将焦点移到密码框，减少一次手动点按。
                    TextField("学号", text: $viewModel.studentID)
                        // 学号输入框使用可显示 QuickType 的键盘；聚焦学号框时系统提供凭据建议。
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .studentID)
                        .onSubmit {
                            focusedField = .password
                        }

                    SecureField("密码", text: $viewModel.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
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
                        HStack(spacing: AppDesignSystem.Spacing.control) {
                            Spacer()
                            if viewModel.isSubmitting {
                                ProgressView()
                            } else {
                                Text("登录")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!viewModel.canSubmit)
                } footer: {
                    // 页脚集中承载账号说明、风险提示和当前版本差异说明，
                    // 登录表单主体保留主要输入和操作。
                    VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.control) {
                        Text("使用学校统一身份认证账号密码登录。若未注册过 BIT101 账号，将自动完成注册；密码仅会经不可逆加密后传输。")
                        Text("本 App 尚处在开发中，不保证所有功能始终可用；如遇到问题，请联系 systemd@linux.do。开发者不对使用过程中造成的损失负责。")
                        Text("本 App 为了完成 Apple 的合规性审查，加入了一些风味元素，功能与安卓版有所差异。")
                    }
                }
            }

            Link(destination: AppLegalInfo.icpPublicNoticeURL) {
                Text(AppLegalInfo.icpDisplayText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AppDesignSystem.Spacing.section)
                    .padding(.top, AppDesignSystem.Spacing.tight)
                    .padding(.bottom, AppDesignSystem.Spacing.control)
                    .background(.regularMaterial)
            }
        }
        .navigationTitle("登录")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        // 备案号固定在容器底部，键盘出现时沿用容器底部布局并由系统覆盖底部区域。
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
