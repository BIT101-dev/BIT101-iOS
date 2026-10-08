nonisolated enum AppVerificationCode {
    static let minimumLength = 4
    static let maximumLength = 8

    static func normalize(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(maximumLength))
    }

    static func isValid(_ value: String) -> Bool {
        (minimumLength ... maximumLength).contains(value.count) && value.allSatisfy(\.isNumber)
    }

    static func shouldSubmitAutomatically(insertedText: String, code: String) -> Bool {
        let insertedCode = insertedText.filter(\.isNumber)
        return isValid(insertedCode) && insertedCode == code
    }
}

#if os(iOS)
import SwiftUI
import UIKit

private struct VerificationCodeField: UIViewRepresentable {
    @Binding var code: String
    @Binding var isFocused: Bool
    let onAutomaticSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CodeTextField {
        let field = CodeTextField()
        field.delegate = context.coordinator
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.textChanged),
                                               name: UITextField.textDidChangeNotification, object: field)
        field.keyboardType = .numberPad
        field.textContentType = .oneTimeCode
        field.textAlignment = .center
        field.adjustsFontForContentSizeCategory = true
        field.accessibilityLabel = "短信验证码"
        field.accessibilityIdentifier = "verification.code"
        return field
    }

    func updateUIView(_ field: CodeTextField, context: Context) {
        context.coordinator.parent = self
        let isEnabled = context.environment.isEnabled
        if field.text != code { field.text = code }
        field.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .headline, compatibleWith: field.traitCollection).pointSize,
            weight: .semibold
        )
        field.attributedPlaceholder = NSAttributedString(string: "短信验证码", attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body, compatibleWith: field.traitCollection),
            .foregroundColor: UIColor.placeholderText,
        ])
        field.isEnabled = isEnabled
        field.shouldFocus = isFocused && isEnabled
        if field.shouldFocus, field.window != nil, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !field.shouldFocus, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CodeTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: uiView.intrinsicContentSize.height)
    }

    static func dismantleUIView(_ field: CodeTextField, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: UITextField.textDidChangeNotification, object: field)
        field.delegate = nil
    }

    final class CodeTextField: UITextField {
        var shouldFocus = false

        override func insertText(_ text: String) {
            (delegate as? Coordinator)?.recordInsertion(text)
            super.insertText(text)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, shouldFocus { becomeFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: VerificationCodeField
        private var insertedText = ""

        init(_ parent: VerificationCodeField) { self.parent = parent }

        func recordInsertion(_ text: String) { insertedText = text }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            recordInsertion(string)
            return true
        }

        @available(iOS 26.0, *)
        func textField(_ textField: UITextField, shouldChangeCharactersInRanges ranges: [NSValue], replacementString string: String) -> Bool {
            recordInsertion(string)
            return true
        }

        @objc func textChanged(_ notification: Notification) {
            guard let field = notification.object as? UITextField else { return }
            let insertion = insertedText
            insertedText = ""
            let digits = AppVerificationCode.normalize(field.text ?? "")
            if field.text != digits { field.text = digits }
            parent.code = digits
            if AppVerificationCode.shouldSubmitAutomatically(insertedText: insertion, code: digits) {
                parent.onAutomaticSubmit(digits)
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

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
    @State private var isCodeFieldFocused = false
    @State private var isSubmitInFlight = false

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
                    VerificationCodeField(
                        code: $code,
                        isFocused: $isCodeFieldFocused,
                        onAutomaticSubmit: submitCode
                    )
                    .disabled(submissionInProgress)
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
                        submitCode(code)
                    } label: {
                        HStack(spacing: AppDesignSystem.Spacing.regular) {
                            Spacer()
                            if submissionInProgress {
                                ProgressView()
                                    .padding(.trailing, AppDesignSystem.Spacing.tiny)
                                Text("正在验证")
                            } else {
                                Text(submitTitle)
                            }
                            Spacer()
                        }
                    }
                    .disabled(submissionInProgress || !AppVerificationCode.isValid(code))
                    .appInteractiveListRow()
                }
            }
            .navigationTitle("短信验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .disabled(submissionInProgress)
                        .accessibilityIdentifier("ui.appsms-verification-sheet.cancel")
                }
            }
            .interactiveDismissDisabled(submissionInProgress)
            .onAppear { isCodeFieldFocused = true }
        }
        .presentationDetents([.medium])
    }

    private var submissionInProgress: Bool { isSubmitting || isSubmitInFlight }

    private func submitCode(_ submittedCode: String) {
        guard !submissionInProgress, AppVerificationCode.isValid(submittedCode) else { return }
        isSubmitInFlight = true
        isCodeFieldFocused = false
        Task {
            defer { isSubmitInFlight = false }
            await onSubmit(submittedCode)
        }
    }

    private var verificationHint: String {
        if let maskedPhone, !maskedPhone.isEmpty {
            return "学校统一身份认证要求二次验证，验证码已发送至 \(maskedPhone)。点击键盘上方建议或粘贴完整验证码后自动验证。"
        }
        return "学校统一身份认证要求二次验证，验证码已发送至绑定手机。点击键盘上方建议或粘贴完整验证码后自动验证。"
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
