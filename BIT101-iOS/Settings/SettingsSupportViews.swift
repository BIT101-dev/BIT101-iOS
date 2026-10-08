import DesignSystemKit
import SwiftUI

/// SettingsTextEditSheet 提供昵称和个性签名共用的文本编辑弹层。
struct SettingsTextEditSheet: View {
    let title: String
    @Binding var text: String
    var axis: Axis = .horizontal
    let isSubmitting: Bool
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("", text: $text, prompt: AppInputPrompt.text(title), axis: axis)
                    .lineLimit(axis == .vertical ? 4 : 1, reservesSpace: axis == .vertical)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("ui.settings-text-edit-sheet.input")
                    .disabled(isSubmitting)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("ui.settings-text-edit-sheet.cancel")
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定", action: onSubmit)
                        .accessibilityIdentifier("ui.settings-text-edit-sheet.confirm")
                        .disabled(isSubmitting)
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
    }
}
