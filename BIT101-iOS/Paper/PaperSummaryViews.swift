//
//  PaperSummaryViews.swift
//  BIT101-iOS
//
//  Split from PaperRootView.swift.
//

import SwiftUI

struct PaperSummaryCard: View {
    let paper: PaperSummary
    let previewMetadata: PaperPreviewMetadata?
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(paper.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 10) {
                AppAvatarView(
                    imageURL: previewMetadata?.avatarURL,
                    tint: AppDesignSystem.Palette.neutral
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(previewMetadata?.authorName ?? "加载中")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(PaperDateText.timestampString(from: paper.updateTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
            }

            if !paper.intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(paper.intro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 12) {
                Label("\(paper.likeNum)", systemImage: "hand.thumbsup")
                Label("\(paper.commentNum)", systemImage: "text.bubble")
                Spacer(minLength: 12)
                Text(PaperDateText.dayString(from: paper.updateTime))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .appFeedCardStyle()
        .onTapGesture(perform: onOpen)
    }
}
