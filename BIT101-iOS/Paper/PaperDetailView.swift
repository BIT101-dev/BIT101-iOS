//
//  PaperDetailView.swift
//  BIT101-iOS
import SwiftUI
import UIKit

struct PaperDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    let initialPaper: PaperSummary

    @StateObject private var viewModel: PaperDetailViewModel
    @StateObject private var networkObserver = PaperNetworkObserver()
    @State private var composerTarget: PaperCommentComposerTarget?
    @State private var imageViewer: GalleryImageViewerState?
    @State private var isShowingEditor = false
    @State private var isShowingDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(initialPaper: PaperSummary) {
        self.initialPaper = initialPaper
        _viewModel = StateObject(wrappedValue: PaperDetailViewModel(initialPaper: initialPaper))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.prominent) {
                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.control) {
                    Text(viewModel.paper?.title ?? initialPaper.title)
                        .font(AppDesignSystem.Typography.title2Emphasis)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)

                    if !paperIntro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(paperIntro)
                            .font(AppDesignSystem.Typography.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: AppDesignSystem.Spacing.content) {
                        PaperHeaderSummary(paper: viewModel.paper, fallback: initialPaper)

                        Spacer()

                        HStack(spacing: AppDesignSystem.Spacing.control) {
                            AppDetailCircleButton(accessibilityLabel: "评论文章") {
                                composerTarget = .paper(paperID: initialPaper.id)
                            } label: {
                                Image(systemName: "bubble.right")
                                    .font(AppDesignSystem.Typography.headline)
                                    .foregroundStyle(.primary)
                            }

                            AppDetailCircleButton(
                                accessibilityLabel: (viewModel.paper?.like ?? false) ? "取消文章点赞" : "点赞文章"
                            ) {
                                likePaper()
                            } label: {
                                Group {
                                    if viewModel.isLikingPaper {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: (viewModel.paper?.like ?? false) ? "hand.thumbsup.fill" : "hand.thumbsup")
                                            .font(AppDesignSystem.Typography.headline)
                                    }
                                }
                                .foregroundStyle((viewModel.paper?.like ?? false) ? AppDesignSystem.Palette.highlight : Color.primary)
                            }
                            .disabled(viewModel.isLikingPaper)
                        }
                    }
                }

                articleContent

                HStack(spacing: AppDesignSystem.Spacing.control) {
                    Spacer()
                    Button {
                        likePaper()
                    } label: {
                        HStack(spacing: AppDesignSystem.Spacing.regular) {
                            if viewModel.isLikingPaper {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: isPaperLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            }

                            Text(isPaperLiked ? "已点赞" : "看完了，点个赞")
                                .font(AppDesignSystem.Typography.bodyEmphasis)
                        }
                        .foregroundStyle(isPaperLiked ? AppDesignSystem.Palette.highlightForeground : AppDesignSystem.Palette.highlight)
                        .padding(.horizontal, AppDesignSystem.Spacing.prominent)
                        .frame(minHeight: AppDesignSystem.Size.control.touchTarget)
                        .background(
                            isPaperLiked ? AppDesignSystem.Palette.highlight : AppDesignSystem.Palette.highlightSurface,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLikingPaper)
                    .accessibilityLabel(isPaperLiked ? "取消点赞" : "点赞文章")
                    Spacer()
                }
                .padding(.top, AppDesignSystem.Spacing.tight)

                HStack(spacing: AppDesignSystem.Spacing.prominent) {
                    Text("\(paperLikeCount)赞")
                    Text("\(viewModel.paper?.commentNum ?? initialPaper.commentNum)评论")
                }
                .font(AppDesignSystem.Typography.subheadline)
                .foregroundStyle(.secondary)

                Divider()

                PaperCommentsSection(
                    comments: viewModel.commentState.items,
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
            .padding(.horizontal, AppDesignSystem.Spacing.prominent)
            .padding(.vertical, AppDesignSystem.Spacing.prominent)
        }
        .background(AppDesignSystem.Palette.groupedBackground)
        .refreshable {
            await viewModel.refreshAll()
        }
        .navigationTitle("文章详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    AppDetailShareLink(
                        item: paperShareURL,
                        subject: viewModel.paper?.title ?? initialPaper.title,
                        accessibilityLabel: "分享文章"
                    )
                    if viewModel.paper?.own == true {
                        Button("编辑文章", systemImage: "pencil") {
                            isShowingEditor = true
                        }
                        Button("删除文章", systemImage: "trash", role: .destructive) {
                            isShowingDeleteConfirmation = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多操作")
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
        .sheet(isPresented: $isShowingEditor) {
            NavigationStack {
                if let paper = viewModel.paper {
                    PaperComposerView(editingPaper: paper) {
                        isShowingEditor = false
                        Task { await viewModel.refreshAll() }
                    }
                }
            }
        }
        .alert("删除文章", isPresented: $isShowingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                Task {
                    if await viewModel.deletePaper() {
                        dismiss()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后文章将从列表中移除。")
        }
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
        .diagnosticAlert(item: $viewModel.alert)
    }

    private var contentBlocks: [PaperContentBlock] {
        let blocks = viewModel.contentBlocks
        if blocks.isEmpty, case .loaded = viewModel.paperStatus, let paper = viewModel.paper {
            return PaperContentRenderer.blocks(from: paper.content)
        }
        return blocks
    }

    private var paperIntro: String {
        viewModel.paper?.intro ?? initialPaper.intro
    }

    @ViewBuilder
    private var articleContent: some View {
        if contentBlocks.isEmpty {
            switch viewModel.paperStatus {
            case .failed(let message):
                AppFailureState(
                    title: "加载文章失败",
                    systemImage: "doc.text.magnifyingglass",
                    message: message,
                    onRetry: {
                        Task { await viewModel.refreshAll() }
                    }
                )
            case .loaded:
                Text("文章正文为空")
                    .font(AppDesignSystem.Typography.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppDesignSystem.Spacing.section)
            case .idle, .loading:
                AppInlineLoadingState("正在加载文章")
            }
        } else {
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.section) {
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
    }

    private var isPaperLiked: Bool {
        viewModel.paper?.like ?? false
    }

    private var paperLikeCount: Int {
        viewModel.paper?.likeNum ?? initialPaper.likeNum
    }

    private var paperShareURL: URL {
        AppURL.required("https://open.aihelpme.dev/paper/\(initialPaper.id)")
    }

    private var inlineImages: [PaperInlineImage] {
        contentBlocks.compactMap { block in
            if case let .image(_, image) = block {
                return image
            }
            return nil
        }
    }

    /// 文章正文或评论处于失败态时，在网络恢复或回到前台后重新请求。
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
        } else {
            await viewModel.refreshComments()
        }
    }

    private func likePaper() {
        Task { await viewModel.likePaper() }
    }
}

private struct PaperHeaderSummary: View {
    let paper: PaperDetail?
    let fallback: PaperSummary

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.control) {
            AppAvatarView(
                imageURL: paper?.anonymous == true ? nil : paper?.updateUser.avatar.preferredRemoteURL,
                size: AppDesignSystem.Size.avatar.articleDetail,
                tint: AppDesignSystem.Palette.neutral
            )

            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.micro) {
                Text(authorName)
                    .font(AppDesignSystem.Typography.bodyEmphasis)
                Text(AppDateText.timestampText(from: paper?.updateTime ?? fallback.updateTime))
                    .font(AppDesignSystem.Typography.caption)
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
            .accessibilityAddTraits(.isHeader)
        case let .paragraph(_, text):
            PaperRichTextView(text: text, textStyle: AppDesignSystem.Typography.uiBody, textColor: .label)
        case let .quote(_, text, caption):
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                    PaperRichTextView(text: text, textStyle: AppDesignSystem.Typography.uiBody, textColor: .label)
                if let caption, containsVisibleText(caption) {
                    PaperRichTextView(text: caption, textStyle: AppDesignSystem.Typography.uiCaption1, textColor: .secondaryLabel)
                }
            }
            .padding(.leading, AppDesignSystem.Spacing.container)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(AppDesignSystem.Palette.highlight)
                    .frame(width: AppDesignSystem.Spacing.tiny)
            }
        case let .list(_, items, ordered):
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: AppDesignSystem.Spacing.regular) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(AppDesignSystem.Typography.bodyEmphasis)
                            .foregroundStyle(.secondary)
                        PaperRichTextView(text: item, textStyle: AppDesignSystem.Typography.uiBody, textColor: .label)
                    }
                }
            }
        case let .image(_, image):
            Button {
                onOpenImage(image)
            } label: {
                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                    GalleryCachedStillImage(url: image.preferredRemoteURL)
                    .frame(maxWidth: .infinity, minHeight: AppDesignSystem.Size.content.imageDraft)
                    .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))

                    if let caption = image.caption, containsVisibleText(caption) {
                        PaperRichTextView(text: caption, textStyle: AppDesignSystem.Typography.uiCaption1, textColor: .secondaryLabel)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(imageAccessibilityLabel(for: image))
            .accessibilityHint("打开图片预览")
        }
    }

    private func imageAccessibilityLabel(for image: PaperInlineImage) -> String {
        guard let caption = image.caption else { return "查看文章图片" }
        let text = String(caption.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "查看文章图片" : "文章图片：\(text)"
    }

    private func headerTextStyle(for level: Int) -> UIFont.TextStyle {
        switch level {
        case 1:
            return AppDesignSystem.Typography.uiTitle2
        case 2:
            return AppDesignSystem.Typography.uiHeadline
        case 3:
            return AppDesignSystem.Typography.uiSubheadline
        default:
            return AppDesignSystem.Typography.uiBody
        }
    }

    private func containsVisibleText(_ text: AttributedString) -> Bool {
        !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 用系统原生 `UITextView` 展示文章富文本。
///
/// `UITextView` 保留 HTML 导入后的粗体、斜体、链接等格式。组件将颜色和默认字体族
/// 映射为系统动态颜色与系统字体，适配深色模式。
private struct PaperRichTextView: UIViewRepresentable {
    let text: AttributedString
    let textStyle: UIFont.TextStyle
    let textColor: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [.foregroundColor: UIColor(AppDesignSystem.Palette.highlight)]
        textView.delegate = context.coordinator
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

        return mutable
    }

    private func normalizedSystemFont(from existingFont: UIFont, baseFont: UIFont) -> UIFont {
        let traits = existingFont.fontDescriptor.symbolicTraits
        let wantedTraits = traits.intersection([.traitBold, .traitItalic])
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(wantedTraits) ?? baseFont.fontDescriptor
        return UIFont(descriptor: descriptor, size: baseFont.pointSize)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            guard let scheme = URL.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
    }
}
