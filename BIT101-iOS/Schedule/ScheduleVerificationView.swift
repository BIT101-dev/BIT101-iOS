import SwiftUI

/// 课表同步使用的短信验证码面板。
struct ScheduleSMSVerificationSheet: View {
    let challenge: BITLoginAuthenticationChallenge
    let isSubmitting: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onSubmit: (String) async -> Void

    @State private var code = ""
    @FocusState private var isCodeFieldFocused: Bool

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
                            .foregroundStyle(.red)
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
                                    .padding(.trailing, 6)
                                Text("正在验证")
                            } else {
                                Text("验证并同步课表")
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
