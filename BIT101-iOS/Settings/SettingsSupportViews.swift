import SwiftUI

/// 昵称和个性签名复用的文本编辑弹层。
struct SettingsTextEditSheet: View {
    let title: String
    @Binding var text: String
    var axis: Axis = .horizontal
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(title, text: $text, axis: axis)
                    .lineLimit(axis == .vertical ? 4 : 1, reservesSpace: axis == .vertical)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定", action: onSubmit)
                }
            }
        }
    }
}
