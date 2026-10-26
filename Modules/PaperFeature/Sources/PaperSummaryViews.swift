import CommunityCore
#if os(iOS)
import CommunityUI
import MediaKit
import DesignSystemKit
//
//  PaperSummaryViews.swift
//  BIT101-iOS
//
//

import SwiftUI

struct PaperSummaryCard: View {
    let paper: PaperSummary
    let previewMetadata: PaperPreviewMetadata?
    var previewFailed = false
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
                    fallbackImageURL: previewMetadata?.avatarFallbackURL,
                    tint: AppDesignSystem.Palette.Status.neutral,
                    anonymous: previewMetadata?.isAnonymous == true
                )

                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.micro) {
                    Text(previewMetadata?.authorName ?? (previewFailed ? "作者暂不可用" : "加载中"))
                        .font(previewMetadata == nil ? AppDesignSystem.Typography.subheadline : AppDesignSystem.Typography.bodyEmphasis)
                        .foregroundStyle(previewMetadata == nil ? AppDesignSystem.Foreground.secondary : AppDesignSystem.Foreground.primary)
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
        .accessibilityIdentifier("paper.summary.\(paper.id)")
        .accessibilityAction(named: "打开文章") {
            onOpen()
        }
    }
}

#endif
