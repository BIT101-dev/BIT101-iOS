import SwiftUI

/// 编辑页的公共内容段，统一 section 标题和内容容器。
struct AppComposerContentSection<Content: View>: View {
    let title: String
    private let content: Content

    init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section(title) {
            content
        }
    }
}

/// 评论输入区的公共内容段，统一匿名开关和选择触感。
struct AppCommentComposerContentSection<Content: View>: View {
    private let title: String
    @Binding private var anonymous: Bool
    private let content: Content

    init(
        title: String = "内容",
        anonymous: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _anonymous = anonymous
        self.content = content()
    }

    var body: some View {
        AppComposerContentSection(title: title) {
            content
            Toggle("匿名评论", isOn: $anonymous)
                .appSelectionFeedback(trigger: anonymous)
        }
    }
}

/// 编辑页的公共工具栏，统一取消和提交入口。
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
