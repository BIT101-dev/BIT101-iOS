//
//  PaperSummaryViews.swift
//  BIT101-iOS
//
//  PaperSummaryCard moved from PaperRootView.swift.
//

import SwiftUI

struct PaperSummaryCard: View {
    let paper: PaperSummary
    let previewMetadata: PaperPreviewMetadata?
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
            Text(paper.title)
                .font(AppDesignSystem.Typography.title)
                .foregroundStyle(AppDesignSystem.Foreground.primary)
                .lineLimit(2)

            HStack(spacing: AppDesignSystem.Spacing.regular) {
                AppAvatarView(
                    imageURL: previewMetadata?.avatarURL,
                    tint: AppDesignSystem.Palette.Status.neutral,
                    anonymous: previewMetadata?.isAnonymous == true
                )

                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.micro) {
                    Text(previewMetadata?.authorName ?? "加载中")
                        .font(AppDesignSystem.Typography.bodyEmphasis)
                        .foregroundStyle(AppDesignSystem.Foreground.primary)
                        .lineLimit(1)

                    Text(AppDateText.timestampText(from: paper.updateTime))
                        .font(AppDesignSystem.Typography.caption)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                }

                Spacer(minLength: AppDesignSystem.Spacing.content)
            }

            if !paper.intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(paper.intro)
                    .font(AppDesignSystem.Typography.body)
                    .foregroundStyle(AppDesignSystem.Foreground.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: AppDesignSystem.Spacing.content) {
                Label("\(paper.likeNum)", systemImage: "hand.thumbsup")
                Label("\(paper.commentNum)", systemImage: "text.bubble")
                Spacer(minLength: AppDesignSystem.Spacing.content)
                Text(AppDateText.dayText(from: paper.updateTime))
            }
            .font(AppDesignSystem.Typography.caption)
            .foregroundStyle(AppDesignSystem.Foreground.secondary)
        }
        .appFeedCardStyle()
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("打开文章详情")
        .accessibilityAction(named: "打开文章") {
            onOpen()
        }
    }
}
