nonisolated enum AppVerificationCode {
    static let minimumLength = 4
    static let maximumLength = 8

    static func normalize(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(maximumLength))
    }

    static func isValid(_ value: String) -> Bool {
        (minimumLength ... maximumLength).contains(value.count) && value.allSatisfy(\.isNumber)
    }
}

#if os(iOS)
import SwiftUI

/// 课表、成绩和可信成绩单共用的短信验证码面板。
///
/// 验证码输入、清洗、焦点、错误展示和提交状态采用统一实现；业务传入掩码手机号、
/// 提交文案、取消操作和提交操作。
public struct AppSMSVerificationSheet: View {
    let maskedPhone: String?
    let isSubmitting: Bool
    let errorMessage: String?
    let submitTitle: String
    let onCancel: () -> Void
    let onSubmit: (String) async -> Void

    @State private var code = ""
    @FocusState private var isCodeFieldFocused: Bool

    public init(
        maskedPhone: String?,
        isSubmitting: Bool,
        errorMessage: String?,
        submitTitle: String,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (String) async -> Void
    ) {
        self.maskedPhone = maskedPhone
        self.isSubmitting = isSubmitting
        self.errorMessage = errorMessage
        self.submitTitle = submitTitle
        self.onCancel = onCancel
        self.onSubmit = onSubmit
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("", text: $code, prompt: AppInputPrompt.text("短信验证码"))
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .font(AppDesignSystem.Typography.title.monospacedDigit())
                        .focused($isCodeFieldFocused)
                        .accessibilityLabel("短信验证码")
                        .accessibilityIdentifier("verification.code")
                        .disabled(isSubmitting)
                        .onChange(of: code) { _, newValue in
                            let digits = AppVerificationCode.normalize(newValue)
                            if digits != newValue {
                                code = digits
                            }
                        }
                } header: {
                    AppListSectionHeader("输入验证码")
                } footer: {
                    Text(verificationHint)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(AppDesignSystem.Palette.Status.danger)
                    }
                }

                Section {
                    Button {
                        isCodeFieldFocused = false
                        Task { await onSubmit(code) }
                    } label: {
                        HStack(spacing: AppDesignSystem.Spacing.regular) {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                                    .padding(.trailing, AppDesignSystem.Spacing.tiny)
                                Text("正在验证")
                            } else {
                                Text(submitTitle)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting || !AppVerificationCode.isValid(code))
                    .appInteractiveListRow()
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
        if let maskedPhone, !maskedPhone.isEmpty {
            return "学校统一身份认证要求二次验证，验证码已发送至 \(maskedPhone)。可点击键盘上方建议自动填充。"
        }
        return "学校统一身份认证要求二次验证，验证码已发送至绑定手机。可点击键盘上方建议自动填充。"
    }
}

/// 学校 SSO 网页短信二次验证面板。
public struct AppSchoolSMSVerificationSheet: View {
    let maskedPhone: String
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    public init(
        maskedPhone: String,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (String) -> Void
    ) {
        self.maskedPhone = maskedPhone
        self.onCancel = onCancel
        self.onSubmit = onSubmit
    }

    public var body: some View {
        AppSMSVerificationSheet(
            maskedPhone: maskedPhone,
            isSubmitting: false,
            errorMessage: nil,
            submitTitle: "验证并继续",
            onCancel: onCancel,
            onSubmit: { code in onSubmit(code) }
        )
    }
}

#endif
