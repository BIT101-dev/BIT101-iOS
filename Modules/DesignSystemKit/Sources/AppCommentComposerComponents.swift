#if os(iOS)
import SwiftUI

/// 评论和开发者建议输入区共用内容段；组件承载匿名选项和选择触感。
public struct AppCommentComposerContentSection<Content: View>: View {
    private let title: String
    private let anonymousLabel: String
    @Binding private var anonymous: Bool
    private let content: Content

    public init(
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

    public var body: some View {
        Section(title) {
            content
            Toggle(anonymousLabel, isOn: $anonymous)
                .appSelectionFeedback(trigger: anonymous)
            .appInteractiveListRow()
                .accessibilityIdentifier("ui.app-comment-composer-content-section.anonymous")
        }
    }
}

/// 评论和建议编辑页共用工具栏；工具栏提供取消和提交入口。
public struct AppComposerToolbar: ToolbarContent {
    let isSubmitting: Bool
    let submitTitle: String
    let submittingTitle: String
    let isSubmitDisabled: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    public init(
        isSubmitting: Bool,
        submitTitle: String,
        submittingTitle: String = "发送中…",
        isSubmitDisabled: Bool = false,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping () -> Void
    ) {
        self.isSubmitting = isSubmitting
        self.submitTitle = submitTitle
        self.submittingTitle = submittingTitle
        self.isSubmitDisabled = isSubmitDisabled
        self.onCancel = onCancel
        self.onSubmit = onSubmit
    }

    public var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消", action: onCancel)
                .accessibilityIdentifier("ui.app-composer-toolbar.cancel")
        }

        ToolbarItem(placement: .confirmationAction) {
            Button(isSubmitting ? submittingTitle : submitTitle, action: onSubmit)
                .disabled(isSubmitting || isSubmitDisabled)
                .accessibilityIdentifier("ui.app-composer-toolbar.submit")
        }
    }
}
#endif
