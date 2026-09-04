import SwiftUI

/// 课表、成绩和可信成绩单共用的短信验证码面板。
///
/// 验证码输入、清洗、焦点、错误展示和提交状态必须保持一致；业务只提供挑战对象、
/// 提交文案和继续操作，不得在页面内复制这套表单。
struct AppSMSVerificationSheet: View {
    let challenge: BITLoginAuthenticationChallenge
    let isSubmitting: Bool
    let errorMessage: String?
    let submitTitle: String
    let onCancel: () -> Void
    let onSubmit: (String) async -> Void

    @State private var code = ""
    @FocusState private var isCodeFieldFocused: Bool

    init(
        challenge: BITLoginAuthenticationChallenge,
        isSubmitting: Bool,
        errorMessage: String?,
        submitTitle: String,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (String) async -> Void
    ) {
        self.challenge = challenge
        self.isSubmitting = isSubmitting
        self.errorMessage = errorMessage
        self.submitTitle = submitTitle
        self.onCancel = onCancel
        self.onSubmit = onSubmit
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("短信验证码", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .font(.title2.monospacedDigit())
                        .focused($isCodeFieldFocused)
                        .disabled(isSubmitting)
                        .onChange(of: code) { _, newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(8))
                            if digits != newValue {
                                code = digits
                            }
                        }
                } header: {
                    Text("输入验证码")
                } footer: {
                    Text(verificationHint)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppDesignSystem.Palette.danger)
                    }
                }

                Section {
                    Button {
                        Task { await onSubmit(code) }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                                    .padding(.trailing, AppDesignSystem.Verification.progressTrailingPadding)
                                Text("正在验证")
                            } else {
                                Text(submitTitle)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting || !(4 ... 8).contains(code.count))
                }
            }
            .navigationTitle("短信验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .disabled(isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .onAppear { isCodeFieldFocused = true }
        }
        .presentationDetents([.medium])
    }

    private var verificationHint: String {
        if let maskedPhone = challenge.maskedPhone, !maskedPhone.isEmpty {
            return "学校统一身份认证要求二次验证，验证码已发送至 \(maskedPhone)。可点击键盘上方建议自动填充。"
        }
        return "学校统一身份认证要求二次验证，验证码已发送至绑定手机。可点击键盘上方建议自动填充。"
    }
}
