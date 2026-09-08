import SwiftUI

/// 评论和开发者建议输入区共用内容段；组件承载匿名选项和选择触感。
struct AppCommentComposerContentSection<Content: View>: View {
    private let title: String
    private let anonymousLabel: String
    @Binding private var anonymous: Bool
    private let content: Content

    init(
        title: String = "内容",
        anonymous: Binding<Bool>,
        anonymousLabel: String = "匿名评论",
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.anonymousLabel = anonymousLabel
        _anonymous = anonymous
        self.content = content()
    }

    var body: some View {
        Section(title) {
            content
            Toggle(anonymousLabel, isOn: $anonymous)
                .appSelectionFeedback(trigger: anonymous)
        }
    }
}

/// 评论和建议编辑页共用工具栏；工具栏提供取消和提交入口。
struct AppComposerToolbar: ToolbarContent {
    let isSubmitting: Bool
    let submitTitle: String
    var submittingTitle = "发送中…"
    var isSubmitDisabled = false
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消", action: onCancel)
        }

        ToolbarItem(placement: .confirmationAction) {
            Button(isSubmitting ? submittingTitle : submitTitle, action: onSubmit)
                .disabled(isSubmitting || isSubmitDisabled)
        }
    }
}
