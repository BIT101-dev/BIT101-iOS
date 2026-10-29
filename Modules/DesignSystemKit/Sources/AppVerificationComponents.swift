import Foundation

public nonisolated enum AppVerificationCode {
    static let minimumLength = 4
    static let maximumLength = 8
    private static let captchaMaximumLength = 16

    public static func normalize(_ value: String, isCaptcha: Bool = false) -> String {
        if isCaptcha { return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(captchaMaximumLength)) }
        return String(decimalDigits(value).prefix(maximumLength))
    }

    public static func isValid(_ value: String, isCaptcha: Bool = false) -> Bool {
        if isCaptcha { return !value.isEmpty && value.count <= captchaMaximumLength && value.allSatisfy { !$0.isWhitespace } }
        return (minimumLength ... maximumLength).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    public static func validationMessage(isCaptcha: Bool) -> String {
        isCaptcha ? "请输入图形验证码。" : "请输入短信中的 4 至 8 位验证码。"
    }

    private static func decimalDigits(_ value: String) -> String {
        String(value.compactMap { character -> Character? in
            guard character.unicodeScalars.count == 1,
                  character.unicodeScalars.first?.properties.generalCategory == .decimalNumber,
                  let digit = character.wholeNumberValue else { return nil }
            return Character(String(digit))
        })
    }

    static func shouldSubmitAutomatically(insertedText: String, code: String, isCaptcha: Bool = false) -> Bool {
        if isCaptcha { return false }
        let insertedCode = decimalDigits(insertedText)
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
    let isCaptcha: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CodeTextField {
        let field = CodeTextField()
        field.delegate = context.coordinator
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.textChanged),
                                               name: UITextField.textDidChangeNotification, object: field)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.textAlignment = .center
        field.adjustsFontForContentSizeCategory = true
        field.accessibilityIdentifier = "verification.code"
        return field
    }

    func updateUIView(_ field: CodeTextField, context: Context) {
        context.coordinator.parent = self
        let isEnabled = context.environment.isEnabled
        let keyboard: UIKeyboardType = isCaptcha ? .asciiCapable : .numberPad
        if field.keyboardType != keyboard { field.keyboardType = keyboard; field.reloadInputViews() }
        field.textContentType = isCaptcha ? nil : .oneTimeCode
        let label = isCaptcha ? "图形验证码" : "短信验证码"
        field.accessibilityLabel = label
        if field.text != code { field.text = code }
        field.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .headline, compatibleWith: field.traitCollection).pointSize,
            weight: .semibold
        )
        field.attributedPlaceholder = NSAttributedString(string: label, attributes: [
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
        field.shouldFocus = false
        field.resignFirstResponder()
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
            guard let field = notification.object as? CodeTextField else { return }
            let insertion = insertedText
            insertedText = ""
            let digits = AppVerificationCode.normalize(field.text ?? "", isCaptcha: parent.isCaptcha)
            if field.text != digits { field.text = digits }
            parent.code = digits
            if AppVerificationCode.shouldSubmitAutomatically(insertedText: insertion, code: digits, isCaptcha: parent.isCaptcha) {
                field.shouldFocus = false
                parent.isFocused = false
                field.resignFirstResponder()
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

/// 课表、成绩和可信成绩单共用的图形与短信验证码面板。
///
/// 验证码输入、清洗、焦点、错误展示和提交状态采用统一实现；业务传入掩码手机号、
/// 提交文案、取消操作和提交操作。
public struct AppVerificationSheet: View {
    @Environment(\.appDiagnosticModalActivity) private var modalActivity
    let maskedPhone: String?
    let isSubmitting: Bool
    let errorMessage: String?
    let submitTitle: String
    let onCancel: () -> Void
    let onSubmit: (String) async -> Void
    let isCaptcha: Bool
    let captchaImage: Data?

    @State private var code = ""
    @State private var isCodeFieldFocused = false
    @State private var isSubmitInFlight = false
    @State private var presentationID = UUID()

    public init(
        maskedPhone: String?,
        isSubmitting: Bool,
        errorMessage: String?,
        submitTitle: String,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (String) async -> Void,
        isCaptcha: Bool = false,
        captchaImage: Data? = nil
    ) {
        self.maskedPhone = maskedPhone
        self.isSubmitting = isSubmitting
        self.errorMessage = errorMessage
        self.submitTitle = submitTitle
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        self.isCaptcha = isCaptcha
        self.captchaImage = captchaImage
    }

    public var body: some View {
        let image = captchaImage.flatMap { UIImage(data: $0) }
        NavigationStack {
            Form {
                Section {
                    if isCaptcha {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFit()
                                .accessibilityLabel("学校图形验证码")
                                .accessibilityIdentifier("verification.captcha")
                        } else {
                            Text("验证码图片加载失败，请取消后重试。")
                                .foregroundStyle(AppDesignSystem.Palette.Status.danger)
                        }
                    }
                    if let maskedPhone, !maskedPhone.isEmpty {
                        LabeledContent("手机号", value: maskedPhone)
                    }
                    VerificationCodeField(
                        code: $code,
                        isFocused: $isCodeFieldFocused,
                        onAutomaticSubmit: submitCode,
                        isCaptcha: isCaptcha
                    )
                    .disabled(submissionInProgress)
                } header: {
                    AppListSectionHeader("输入验证码")
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
                    .disabled(submissionInProgress || !AppVerificationCode.isValid(code, isCaptcha: isCaptcha) || isCaptcha && image == nil)
                    .appInteractiveListRow()
                }
            }
            .navigationTitle(isCaptcha ? "图形验证" : "短信验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .disabled(submissionInProgress)
                        .accessibilityIdentifier("ui.appsms-verification-sheet.cancel")
                }
            }
            .interactiveDismissDisabled(submissionInProgress)
            .onAppear { modalActivity?(presentationID, true); isCodeFieldFocused = true }
            .onDisappear { modalActivity?(presentationID, false) }
            .onChange(of: isCaptcha) { _, _ in resetInput() }
            .onChange(of: captchaImage) { _, _ in resetInput() }
        }
        .presentationDetents(isCaptcha ? [.large] : [.medium])
    }

    private var submissionInProgress: Bool { isSubmitting || isSubmitInFlight }

    private func resetInput() { code = ""; isCodeFieldFocused = true }

    private func submitCode(_ submittedCode: String) {
        guard !submissionInProgress, AppVerificationCode.isValid(submittedCode, isCaptcha: isCaptcha) else { return }
        isSubmitInFlight = true
        isCodeFieldFocused = false
        Task {
            defer { isSubmitInFlight = false }
            await onSubmit(submittedCode)
        }
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
        AppVerificationSheet(
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
