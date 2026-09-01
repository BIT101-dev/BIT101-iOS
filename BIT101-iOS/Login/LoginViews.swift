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
/// 有本地会话时立即挂载主壳层，登录校验在后台静默完成。
struct LoginRootView: View {
    /// 登录模块唯一状态机。
    @StateObject private var viewModel = LoginViewModel()

    /// 登录模块根视图主体。
    ///
    /// 根视图不自己决定复杂路由，只根据 `screenState` 在“登录表单”和“主壳层”之间切换。
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
/// 内容结构尽量向 Android 版本对齐，但仍然只使用 SwiftUI 原生组件。
private struct LoginFormView: View {
    @ObservedObject var viewModel: LoginViewModel
    /// 用来在学号和密码输入框之间切换焦点。
    @FocusState private var focusedField: LoginField?

    /// 登录表单主体。
    var body: some View {
        Form {
            Section {
                // 学号输入完成后，直接把焦点移到密码框，减少一次手动点按。
                TextField("学号", text: $viewModel.studentID)
                    .keyboardType(.numberPad)
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
                        Task { await viewModel.login() }
                    }
            }

            Section {
                // 登录按钮和键盘回车最终都复用同一个 `viewModel.login()` 入口，
                // 保证校验、错误提示和提交态完全一致。
                Button {
                    focusedField = nil
                    Task { await viewModel.login() }
                } label: {
                    HStack {
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
                // 避免登录表单本体被次要信息挤压。
                VStack(alignment: .leading, spacing: 10) {
                    Text("使用学校统一身份认证账号密码登录。若未注册过 BIT101 账号，将自动完成注册；密码仅会经不可逆加密后传输。")
                    Text("本 App 尚处在开发中，不保证所有功能始终可用；如遇到问题，请联系 systemd@linux.do。开发者不对使用过程中造成的损失负责。")
                    Text("本 App 为了完成 Apple 的合规性审查，加入了一些风味元素，功能与安卓版有所差异。")
                }
            }
        }
        .navigationTitle("登录")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Link(destination: AppLegalInfo.icpPublicNoticeURL) {
                Text(AppLegalInfo.icpDisplayText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
        }
    }
}

/// 登录表单里的焦点路由枚举。
///
/// 当前只有学号和密码两项，但仍然保留枚举，是为了让焦点切换逻辑明确且可扩展。
private enum LoginField: Hashable {
    case studentID
    case password
}
