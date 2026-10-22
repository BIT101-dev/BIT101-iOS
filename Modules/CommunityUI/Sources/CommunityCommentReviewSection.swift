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
#endif
