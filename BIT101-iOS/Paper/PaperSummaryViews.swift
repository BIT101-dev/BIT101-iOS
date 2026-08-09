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
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(paper.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)

            HStack(spacing: 10) {
                PaperSummaryAvatar(previewMetadata: previewMetadata)

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

                PaperArticleActionMenu(onHide: onHide)
                    .contentShape(Rectangle())
                    .onTapGesture { }
            }

            if !paper.intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(paper.intro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

/// 文章列表项作者头像。
private struct PaperSummaryAvatar: View {
    let previewMetadata: PaperPreviewMetadata?

    var body: some View {
        Group {
            if let avatarURL = previewMetadata?.avatarURL {
                CachedRemoteImage(url: avatarURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                }
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }
}

struct PaperEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    let onRetry: (() -> Void)?

    init(systemImage: String, title: String, message: String, onRetry: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.onRetry = onRetry
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let onRetry {
                Button("重试", action: onRetry)
            }
        }
    }
}

