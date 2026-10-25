#if os(iOS)
import CommunityCore
import DesignSystemKit
import SwiftUI

public struct CommunityCommentReviewSection: View {
    private let submission: CommunityCommentSubmission
    private let actions: CommunityCommentReviewActions
    private let onSend: () -> Void

    public init(submission: CommunityCommentSubmission, actions: CommunityCommentReviewActions, onSend: @escaping () -> Void) {
        self.submission = submission
        self.actions = actions
        self.onSend = onSend
    }

    public var body: some View {
        if actions.needsReview(submission) {
            Section("核对发送结果") {
                Text("再次发送可能产生重复评论。请先核对评论列表。")
                    .font(AppDesignSystem.Typography.caption)
                    .foregroundStyle(AppDesignSystem.Foreground.secondary)
                Button("已核对，继续发送") {
                    actions.acknowledge(submission)
                    onSend()
                }
                    .appInteractiveListRow()
                    .accessibilityIdentifier("community.comment.review")
            }
        }
    }
}

public struct CommunityPublicationReviewSection: View {
    private let state: ComposerPublicationReviewState
    private let destination: AnyView
    private let onAcknowledge: () -> Void

    public init(state: ComposerPublicationReviewState, destination: AnyView, onAcknowledge: @escaping () -> Void) {
        self.state = state
        self.destination = destination
        self.onAcknowledge = onAcknowledge
    }

    public var body: some View {
        if state.needsReview {
            Section("核对发布结果") {
                Text(message)
                    .font(AppDesignSystem.Typography.caption)
                    .foregroundStyle(AppDesignSystem.Foreground.secondary)
                NavigationLink("核对已发布内容", destination: destination)
                    .appInteractiveListRow()
                    .accessibilityIdentifier("community.publication.review-content")
                Button("已核对，允许发布", action: onAcknowledge)
                    .appInteractiveListRow()
                    .accessibilityIdentifier("community.publication.review")
            }
        }
    }

    private var message: String {
        switch state {
        case .ready: ""
        case .pending(let attempt): "《\(attempt.content.title)》的发布结果待确认。请打开搜索，核对作者与内容后再决定是否继续发布。当前编辑内容会保留。"
        case .requiresRecovery: "本机发布记录读取遇到问题。请先搜索并核对当前账号已发布的内容，确认后重建发布记录。编辑内容和草稿会保留。"
        }
    }
}
#endif
