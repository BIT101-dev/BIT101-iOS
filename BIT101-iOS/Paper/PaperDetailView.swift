//
//  PaperDetailView.swift
//  BIT101-iOS
//
//  Split from PaperRootView.swift.
//

import SwiftUI
import UIKit

struct PaperDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var settings = AppSettingsStore.shared
    let initialPaper: PaperSummary

    @StateObject private var viewModel: PaperDetailViewModel
    @StateObject private var networkObserver = PaperNetworkObserver()
    @State private var composerTarget: PaperCommentComposerTarget?
    @State private var imageViewer: GalleryImageViewerState?

    init(initialPaper: PaperSummary) {
        self.initialPaper = initialPaper
        _viewModel = StateObject(wrappedValue: PaperDetailViewModel(initialPaper: initialPaper))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(viewModel.paper?.title ?? initialPaper.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        PaperHeaderSummary(paper: viewModel.paper, fallback: initialPaper)

                        Spacer()

                        HStack(spacing: 10) {
                            Button {
                                composerTarget = .paper(paperID: initialPaper.id)
                            } label: {
                                Image(systemName: "bubble.right")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .frame(width: 34, height: 34)
                                    .background(Color.orange.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task { await viewModel.likePaper() }
                            } label: {
                                Group {
                                    if viewModel.isLikingPaper {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: (viewModel.paper?.like ?? false) ? "hand.thumbsup.fill" : "hand.thumbsup")
                                            .font(.headline)
                                    }
                                }
                                .foregroundStyle((viewModel.paper?.like ?? false) ? Color.orange : Color.primary)
                                .frame(width: 34, height: 34)
                                .background(Color.orange.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLikingPaper)
                        }
                    }
                }

                if !contentBlocks.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(contentBlocks) { block in
                            PaperContentBlockView(
                                block: block,
                                onOpenImage: { image in
                                    guard let initialIndex = inlineImages.firstIndex(of: image) else { return }
                                    imageViewer = GalleryImageViewerState(
                                        images: inlineImages.map(\.asGalleryImage),
                                        initialIndex: initialIndex
                                    )
                                }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Spacer()
                    Button {
                        Task { await viewModel.likePaper() }
                    } label: {
                        HStack(spacing: 8) {
                            if viewModel.isLikingPaper {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: isPaperLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            }

                            Text(isPaperLiked ? "已点赞" : "看完了，点个赞")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(isPaperLiked ? Color.white : Color.orange)
                        .padding(.horizontal, 22)
                        .frame(minHeight: 44)
                        .background(
                            isPaperLiked ? Color.orange : Color.orange.opacity(0.12),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLikingPaper)
                    .accessibilityLabel(isPaperLiked ? "取消点赞" : "点赞文章")
                    Spacer()
                }
                .padding(.top, 6)

                HStack(spacing: 18) {
                    Text("\(paperLikeCount)赞")
                    Text("\(viewModel.paper?.commentNum ?? initialPaper.commentNum)评论")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Divider()

                PaperCommentsSection(
                    comments: filteredComments,
                    totalCommentCount: viewModel.paper?.commentNum ?? initialPaper.commentNum,
                    status: viewModel.commentState.status,
                    isLoadingMore: viewModel.commentState.isLoadingMore,
                    selectedOrder: viewModel.commentOrder,
                    likingCommentIDs: viewModel.likingCommentIDs,
                    onSelectOrder: { order in
                        Task { await viewModel.setCommentOrder(order) }
                    },
                    onReply: { target in
                        composerTarget = .comment(mainComment: target.mainComment, targetComment: target.targetComment)
                    },
                    onLikeComment: { comment in
                        Task { await viewModel.toggleCommentLike(comment) }
                    },
                    onLoadMore: { comment in
                        Task {
                            await viewModel.loadMoreCommentsIfNeeded(currentComment: comment)
                        }
                    },
                    onRetry: {
                        Task {
                            await viewModel.refreshComments()
                        }
                    }
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await viewModel.refreshAll()
        }
        .navigationTitle("文章详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PaperArticleActionMenu {
                    settings.hidePaper(id: initialPaper.id)
                    dismiss()
                }
            }
        }
        .sheet(item: $composerTarget) { target in
            NavigationStack {
                PaperCommentComposerSheet(
                    target: target,
                    isSubmitting: viewModel.isSubmittingComment
                ) { text, anonymous in
                    Task {
                        let submitted = await viewModel.submitComment(text: text, anonymous: anonymous, target: target)
                        if submitted {
                            composerTarget = nil
                        }
                    }
                }
            }
            .presentationDragIndicator(.visible)
        }
        .gallerySystemImagePreview(item: $imageViewer)
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .onChange(of: networkObserver.isReachable) { oldValue, newValue in
            guard newValue, !oldValue else { return }
            Task {
                await retryDetailIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            Task {
                await retryDetailIfNeeded()
            }
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var contentBlocks: [PaperContentBlock] {
        let blocks = viewModel.contentBlocks
        if blocks.isEmpty, case .loaded = viewModel.paperStatus, let paper = viewModel.paper {
            return PaperContentRenderer.blocks(from: paper.content)
        }
        return blocks
    }

    private var isPaperLiked: Bool {
        viewModel.paper?.like ?? false
    }

    private var paperLikeCount: Int {
        viewModel.paper?.likeNum ?? initialPaper.likeNum
    }

    private var filteredComments: [GalleryComment] {
        CommunityModeration.filterVisibleComments(viewModel.commentState.items, snapshot: AppSettingsStore.shared.snapshot)
    }

    private var inlineImages: [PaperInlineImage] {
        contentBlocks.compactMap { block in
            if case let .image(_, image) = block {
                return image
            }
            return nil
        }
    }

    /// 文章正文或评论停在失败态时，在网络恢复或回前台后自动补拉。
    private func retryDetailIfNeeded() async {
        guard networkObserver.isReachable else { return }

        let shouldRetryPaper: Bool
        if case .failed = viewModel.paperStatus {
            shouldRetryPaper = true
        } else {
            shouldRetryPaper = false
        }

        let shouldRetryComments: Bool
        if case .failed = viewModel.commentState.status {
            shouldRetryComments = true
        } else {
            shouldRetryComments = false
        }

        guard shouldRetryPaper || shouldRetryComments else { return }

        if shouldRetryPaper {
            await viewModel.refreshAll()
        } else if shouldRetryComments {
            await viewModel.refreshComments()
        }
    }
}

private struct PaperHeaderSummary: View {
    let paper: PaperDetail?
    let fallback: PaperSummary

    var body: some View {
        HStack(spacing: 10) {
            CachedRemoteImage(url: paper?.updateUser.avatar.preferredRemoteURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(authorName)
                    .font(.subheadline.weight(.semibold))
                Text(PaperDateText.timestampString(from: paper?.updateTime ?? fallback.updateTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var authorName: String {
        guard let paper else { return "加载中" }
        return paper.anonymous ? "匿名者" : paper.updateUser.nickname
    }
}

private struct PaperContentBlockView: View {
    let block: PaperContentBlock
    let onOpenImage: (PaperInlineImage) -> Void

    var body: some View {
        switch block {
        case let .header(_, text, level):
            PaperRichTextView(
                text: text,
                textStyle: headerTextStyle(for: level),
                textColor: .label
            )
        case let .paragraph(_, text):
            PaperRichTextView(text: text, textStyle: .body, textColor: .label)
        case let .quote(_, text, caption):
            VStack(alignment: .leading, spacing: 8) {
                PaperRichTextView(text: text, textStyle: .body, textColor: .label)
                if let caption, !String(caption.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PaperRichTextView(text: caption, textStyle: .caption1, textColor: .secondaryLabel)
                }
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.orange)
                    .frame(width: 4)
            }
        case let .list(_, items, ordered):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                        PaperRichTextView(text: item, textStyle: .body, textColor: .label)
                    }
                }
            }
        case let .image(_, image):
            Button {
                onOpenImage(image)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    GalleryCachedStillImage(url: image.preferredRemoteURL)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if let caption = image.caption, !String(caption.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        PaperRichTextView(text: caption, textStyle: .caption1, textColor: .secondaryLabel)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func headerTextStyle(for level: Int) -> UIFont.TextStyle {
        switch level {
        case 1:
            return .title2
        case 2:
            return .headline
        case 3:
            return .subheadline
        default:
            return .body
        }
    }
}

/// 用系统原生 `UITextView` 展示文章富文本。
///
/// 这样可以保留 HTML 导入后的粗体、斜体、链接等格式，同时把颜色和默认字体族
/// 重新映射到系统动态颜色与系统字体，避免深色模式下出现固定黑字。
private struct PaperRichTextView: UIViewRepresentable {
    let text: AttributedString
    let textStyle: UIFont.TextStyle
    let textColor: UIColor

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.isUserInteractionEnabled = true
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [.foregroundColor: UIColor.systemOrange]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.attributedText = normalizedAttributedText()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let fittingSize = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fittingSize.height)
    }

    private func normalizedAttributedText() -> NSAttributedString {
        let source = NSAttributedString(text)
        let mutable = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let baseFont = UIFont.preferredFont(forTextStyle: textStyle)

        mutable.removeAttribute(.foregroundColor, range: fullRange)
        mutable.removeAttribute(.backgroundColor, range: fullRange)

        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let normalizedFont: UIFont
            if let existingFont = value as? UIFont {
                normalizedFont = normalizedSystemFont(from: existingFont, baseFont: baseFont)
            } else {
                normalizedFont = baseFont
            }

            mutable.addAttribute(.font, value: normalizedFont, range: range)
            mutable.addAttribute(.foregroundColor, value: textColor, range: range)
        }

        if mutable.length == 0 {
            mutable.addAttribute(.font, value: baseFont, range: fullRange)
            mutable.addAttribute(.foregroundColor, value: textColor, range: fullRange)
        }

        return mutable
    }

    private func normalizedSystemFont(from existingFont: UIFont, baseFont: UIFont) -> UIFont {
        let traits = existingFont.fontDescriptor.symbolicTraits
        let wantedTraits = traits.intersection([.traitBold, .traitItalic])
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(wantedTraits) ?? baseFont.fontDescriptor
        return UIFont(descriptor: descriptor, size: baseFont.pointSize)
    }
}
