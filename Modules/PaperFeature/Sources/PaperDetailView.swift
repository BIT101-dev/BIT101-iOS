#if os(iOS)
import CommunityUI
import TransportCore
import MediaKit
import CommunityCore
import DesignSystemKit
import Combine
//
//  PaperDetailView.swift
//  BIT101-iOS
import SwiftUI

struct PaperDetailView: View {
    private let scene: PaperDetailViewScene
    private let identity: [ObjectIdentifier]
    private let resourceID: Int

    init(
        dependencies: PaperDependencies, media: MediaEnvironment, initialPaper: PaperSummary,
        onDeleted: (() -> Void)? = nil, onChanged: @escaping () -> Void
    ) {
        scene = PaperDetailViewScene(
            dependencies: dependencies, media: media, initialPaper: initialPaper,
            onDeleted: onDeleted, onChanged: onChanged)
        identity = [ObjectIdentifier(dependencies), ObjectIdentifier(media)]
        resourceID = initialPaper.id
    }

    var body: some View {
        scene.id(identity)
            .id(resourceID)
    }
}

private struct PaperDetailViewScene: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    private let dependencies: PaperDependencies
    private let media: MediaEnvironment
    private let onChanged: () -> Void
    private let onDeleted: (() -> Void)?
    let initialPaper: PaperSummary

    @State private var viewModel: PaperDetailViewModel
    private var networkObserver: NetworkPathState { dependencies.networkPath }
    @State private var composerTarget: CommunityCommentComposerTarget?
    @State private var editingPaper: PaperDetail?
    @State private var imageViewer: ImagePreviewRequest?
    @State private var isShowingDeleteConfirmation = false
    @State private var authenticationRevision = 0
    @Environment(\.dismiss) private var dismiss

    init(
        dependencies: PaperDependencies, media: MediaEnvironment, initialPaper: PaperSummary,
        onDeleted: (() -> Void)? = nil, onChanged: @escaping () -> Void
    ) {
        self.dependencies = dependencies
        self.media = media
        self.initialPaper = initialPaper
        self.onChanged = onChanged
        self.onDeleted = onDeleted
        _viewModel = State(
            initialValue: PaperDetailViewModel(
                initialPaper: initialPaper, service: dependencies.detail))
    }

    var body: some View {
        content.environment(dependencies).environment(media).appReadableContent(
            fillsAvailableWidth: true)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.section) {
                headerSection

                articleContent

                bottomLikeSection

                HStack(spacing: AppDesignSystem.Spacing.section) {
                    Text("\(paperLikeCount)赞")
                    Text("\(viewModel.paper?.commentNum ?? initialPaper.commentNum)评论")
                }
                .font(AppDesignSystem.Typography.subheadline)
                .foregroundStyle(AppDesignSystem.Foreground.secondary)

                Divider()

                PaperCommentsSection(
                    comments: viewModel.commentState.items,
                    totalCommentCount: viewModel.paper?.commentNum ?? initialPaper.commentNum,
                    status: viewModel.commentState.status,
                    isLoadingMore: viewModel.commentState.isLoadingMore,
                    paginationError: viewModel.commentState.paginationError,
                    selectedOrder: viewModel.commentOrder,
                    likingCommentIDs: viewModel.likingCommentIDs,
                    onSelectOrder: { order in
                        viewModel.pendingOperations.enqueue {
                            await viewModel.setCommentOrder(order)
                        }
                    },
                    onReply: { target in
                        composerTarget = target
                    },
                    onLikeComment: { comment in
                        viewModel.pendingOperations.enqueue {
                            await viewModel.toggleCommentLike(comment)
                        }
                    },
                    onOpenImage: { index, images in
                        imageViewer = ImagePreviewRequest(
                            remoteImages: images.map(\.previewImage), initialIndex: index)
                    },
                    onLoadMore: { comment in
                        viewModel.pendingOperations.enqueue {
                            await viewModel.loadMoreCommentsIfNeeded(currentComment: comment)
                        }
                    },
                    onRetry: {
                        viewModel.pendingOperations.enqueue {
                            await viewModel.refreshComments()
                        }
                    }
                )
            }
            .padding(.horizontal, AppDesignSystem.Spacing.section)
            .padding(.vertical, AppDesignSystem.Spacing.section)
        }
        .accessibilityIdentifier("interaction.PaperDetailViewScene.scroll")
        .background(AppDesignSystem.Palette.Background.grouped)
        .refreshable {
            interactionEvidence?("interaction.PaperDetailViewScene.refreshable", "refresh")

            media.retryFailedImages()
            await viewModel.refreshAll()
        }
        .navigationTitle("文章详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            detailToolbar
        }
        .sheet(item: $composerTarget) { target in
            NavigationStack {
                PaperCommentComposerSheet(
                    target: target,
                    isSubmitting: viewModel.isSubmittingComment,
                    review: viewModel.commentReview
                ) { text, anonymous in
                    await viewModel.submitComment(
                        text: text, anonymous: anonymous, target: target)
                }
                .id(target.id)
            }
            .environment(dependencies)
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(item: $editingPaper) { paper in
            PaperComposerView(
                editingPaper: paper,
                initialContent: PaperEditorContentBuilder.plainText(
                    from: viewModel.contentBlocks),
                currentIdentity: dependencies.currentIdentity
            ) {
                onChanged()
                viewModel.pendingOperations.enqueue { await viewModel.refreshAll() }
            }
            .environment(dependencies)
        }
        .systemImagePreview(item: $imageViewer)
        .alert("删除文章", isPresented: $isShowingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                viewModel.pendingOperations.enqueue {
                    if await viewModel.deletePaper() {
                        onChanged()
                        onDeleted?()
                        dismiss()
                    }
                }
            }
            .accessibilityIdentifier("ui.paper-detail-view-scene.delete")
            .disabled(viewModel.isDeletingPaper)
            Button("取消", role: .cancel) {}
                .accessibilityIdentifier("ui.paper-detail-view-scene.cancel")
        } message: {
            Text("删除后文章将从列表中移除。")
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .onReceive(dependencies.authenticationChanges.receive(on: DispatchQueue.main)) { _ in
            authenticationRevision &+= 1
        }
        .onChange(of: viewModel.hasPublicContent) { _, isPublic in
            if isPublic, authenticationRevision != 0,
                dependencies.hasAuthenticationCredentials()
            {
                authenticationRevision &+= 1
            }
        }
        .communityReadRecovery(
            networkPath: networkObserver, retryRevision: authenticationRevision
        ) { await retryDetailIfNeeded() }
        .onDisappear { viewModel.cancelPendingOperations() }
        .diagnosticAlert(item: $viewModel.alert)
    }

    private var contentBlocks: [PaperContentBlock] {
        let blocks = viewModel.contentBlocks
        if blocks.isEmpty, case .loaded = viewModel.paperStatus, let paper = viewModel.paper {
            return PaperContentRenderer.blocks(from: paper.content)
        }
        return blocks
    }

    private var headerLikeAccessibilityLabel: String {
        if viewModel.hasKnownLikeState {
            return viewModel.isPaperLiked ? "取消文章点赞" : "点赞文章"
        }
        return viewModel.likeStateMessage
    }

    private var headerLikeIconName: String {
        viewModel.isPaperLiked ? "hand.thumbsup.fill" : "hand.thumbsup"
    }

    private var isHeaderLikeLoading: Bool {
        viewModel.isLikingPaper
            || (!viewModel.hasKnownLikeState
                && (viewModel.paperStatus == .idle || viewModel.paperStatus == .loading))
    }

    @ViewBuilder
    private var headerLikeButton: some View {
        AppDetailCircleButton(accessibilityLabel: headerLikeAccessibilityLabel) {
            likePaper()
        } label: {
            Group {
                if isHeaderLikeLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: headerLikeIconName)
                        .font(AppDesignSystem.Typography.title)
                }
            }
            .foregroundStyle(
                viewModel.isPaperLiked
                    ? AppDesignSystem.Palette.Accent.primary
                    : AppDesignSystem.Foreground.primaryColor)
        }
        .disabled(viewModel.isLikingPaper || !viewModel.hasKnownLikeState)
        .accessibilityIdentifier("paper.detail.header-like")
    }

    @ViewBuilder
    private var headerActionButtons: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            AppDetailCircleButton(accessibilityLabel: "评论文章") {
                composerTarget = .paper(paperID: initialPaper.id)
            } label: {
                Image(systemName: "bubble.right")
                    .font(AppDesignSystem.Typography.title)
                    .foregroundStyle(AppDesignSystem.Foreground.primary)
            }

            headerLikeButton
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
            Text(viewModel.paper?.title ?? initialPaper.title)
                .font(AppDesignSystem.Typography.titleEmphasis)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            if !paperIntro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(paperIntro)
                    .font(AppDesignSystem.Typography.body)
                    .foregroundStyle(AppDesignSystem.Foreground.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: AppDesignSystem.Spacing.content) {
                PaperHeaderSummary(paper: viewModel.paper, fallback: initialPaper)

                Spacer()

                headerActionButtons
            }
        }
    }

    private var bottomLikeAccessibilityLabel: String {
        if viewModel.hasKnownLikeState {
            return isPaperLiked ? "取消点赞" : "点赞文章"
        }
        return viewModel.likeStateMessage
    }

    private var bottomLikeText: String {
        if viewModel.hasKnownLikeState {
            return isPaperLiked ? "已点赞" : "看完了，点个赞"
        }
        return viewModel.likeStateMessage
    }

    private var bottomLikeIconName: String {
        isPaperLiked ? "hand.thumbsup.fill" : "hand.thumbsup"
    }

    @ViewBuilder
    private var bottomLikeButton: some View {
        Button {
            likePaper()
        } label: {
            HStack(spacing: AppDesignSystem.Spacing.regular) {
                if viewModel.isLikingPaper {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: bottomLikeIconName)
                }

                Text(bottomLikeText)
                    .font(AppDesignSystem.Typography.bodyEmphasis)
            }
            .foregroundStyle(
                isPaperLiked
                    ? AppDesignSystem.Palette.Highlight.foreground
                    : AppDesignSystem.Palette.Accent.primary
            )
            .padding(.horizontal, AppDesignSystem.Spacing.section)
            .frame(minHeight: AppDesignSystem.Size.Control.touchTarget)
            .background(
                isPaperLiked
                    ? AppDesignSystem.Palette.Accent.primary
                    : AppDesignSystem.Palette.Accent.surface,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLikingPaper || !viewModel.hasKnownLikeState)
        .accessibilityLabel(bottomLikeAccessibilityLabel)
        .accessibilityIdentifier("paper.detail.footer-like")
    }

    @ViewBuilder
    private var bottomLikeSection: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            Spacer()
            bottomLikeButton
            Spacer()
        }
        .padding(.top, AppDesignSystem.Spacing.tiny)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            detailMenu
        }
    }

    @ViewBuilder
    private var detailMenu: some View {
        Menu {
            AppDetailShareLink(
                item: paperShareURL,
                subject: viewModel.paper?.title ?? initialPaper.title,
                accessibilityLabel: "分享文章"
            )
            if viewModel.paper?.own == true {
                Button {
                    editingPaper = viewModel.paper
                } label: {
                    Label("编辑文章", systemImage: "pencil")
                }
                .accessibilityLabel("编辑文章")
                .accessibilityIdentifier("paper.detail.edit")
                Button("删除文章", systemImage: "trash", role: .destructive) {
                    isShowingDeleteConfirmation = true
                }
                .accessibilityIdentifier("paper.detail.delete")
                .disabled(viewModel.isDeletingPaper)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("更多操作")
    }

    private var paperIntro: String {
        viewModel.paper?.intro ?? initialPaper.intro
    }

    private var hasOriginalLink: Bool {
        contentBlocks.contains {
            if case .requiresOriginal = $0 { return true }
            return false
        }
    }

    private func openImage(_ image: PaperInlineImage) {
        guard let initialIndex = inlineImages.firstIndex(of: image) else {
            return
        }
        imageViewer = ImagePreviewRequest(
            remoteImages: inlineImages.map {
                $0.asCommunityImage.previewImage
            }, initialIndex: initialIndex
        )
    }

    @ViewBuilder
    private var contentBlockList: some View {
        LazyVStack(alignment: .leading, spacing: AppDesignSystem.Spacing.section) {
            ForEach(contentBlocks) { block in
                PaperContentBlockView(
                    block: block,
                    onOpenImage: openImage
                )
            }
            if hasOriginalLink {
                Link(
                    "阅读完整原文",
                    destination: AppEndpoints.bit101Web.appendingPathComponent(
                        "paper/\(initialPaper.id)")
                )
                .font(AppDesignSystem.Typography.body)
                .accessibilityIdentifier("ui.paper-content.original")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        viewModel.pendingOperations.enqueue { await viewModel.refreshAll() }
                    }
                )
            case .loaded:
                Text("文章正文为空")
                    .font(AppDesignSystem.Typography.body)
                    .foregroundStyle(AppDesignSystem.Foreground.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppDesignSystem.Spacing.section)
            case .idle, .loading:
                AppInlineLoadingState("正在加载文章")
            }
        } else {
            contentBlockList
        }
    }

    private var isPaperLiked: Bool {
        viewModel.isPaperLiked
    }

    private var paperLikeCount: Int {
        viewModel.resolvedLikeNum
    }

    private var paperShareURL: URL {
        AppEndpoints.openLink("paper/\(initialPaper.id)")
    }

    private var inlineImages: [PaperInlineImage] {
        contentBlocks.compactMap { block in
            if case .image(_, let image) = block {
                return image
            }
            return nil
        }
    }

    /// 文章、评论与认证交互状态沿连接和凭据恢复重新读取。
    private func retryDetailIfNeeded() async {
        guard networkObserver.isReachable else { return }
        if dependencies.hasAuthenticationCredentials(), viewModel.hasPublicContent {
            await viewModel.refreshAll()
            return
        }

        if case .failed = viewModel.paperStatus {
            await viewModel.refreshAll()
        } else {
            await viewModel.retryCommentsIfNeeded()
        }
    }

    private func likePaper() {
        viewModel.pendingOperations.enqueue { await viewModel.likePaper() }
    }
}

private struct PaperHeaderSummary: View {
    let paper: PaperDetail?
    let fallback: PaperSummary

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            AppAvatarView(
                imageURL: paper?.anonymous == true
                    ? nil : paper?.updateUser.avatar.thumbnailURL,
                fallbackImageURL: paper?.anonymous == true
                    ? nil : paper?.updateUser.avatar.originalURL,
                size: AppDesignSystem.Size.Avatar.standard,
                tint: AppDesignSystem.Palette.Status.neutral,
                anonymous: paper?.anonymous == true
            )

            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.micro) {
                Text(authorName)
                    .font(AppDesignSystem.Typography.bodyEmphasis)
                Text(AppDateText.timestampText(from: paper?.updateTime ?? fallback.updateTime))
                    .font(AppDesignSystem.Typography.caption)
                    .foregroundStyle(AppDesignSystem.Foreground.secondary)
            }
        }
    }

    private var authorName: String {
        guard let paper else { return "加载中" }
        return paper.anonymous ? AppUserPresentation.anonymousName : paper.updateUser.nickname
    }
}

private struct PaperContentBlockView: View {
    let block: PaperContentBlock
    let onOpenImage: (PaperInlineImage) -> Void

    var body: some View {
        switch block {
        case .header(_, let text, let level):
            PaperRichTextView(
                text: text,
                textStyle: headerTextStyle(for: level),
                textColor: .label
            )
            .accessibilityAddTraits(.isHeader)
        case .paragraph(_, let text):
            PaperRichTextView(
                text: text, textStyle: AppDesignSystem.Typography.uiBody, textColor: .label)
        case .requiresOriginal:
            Text("此段内容请通过完整原文阅读。")
                .font(AppDesignSystem.Typography.body)
                .foregroundStyle(AppDesignSystem.Foreground.secondary)
        case .quote(_, let text, let caption):
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                PaperRichTextView(
                    text: text, textStyle: AppDesignSystem.Typography.uiBody, textColor: .label)
                if let caption, containsVisibleText(caption) {
                    PaperRichTextView(
                        text: caption, textStyle: AppDesignSystem.Typography.uiCaption,
                        textColor: .secondaryLabel)
                }
            }
            .padding(.leading, AppDesignSystem.Spacing.content)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(AppDesignSystem.Palette.Accent.primary)
                    .frame(width: AppDesignSystem.Spacing.tiny)
            }
        case .list(_, let items, let ordered):
            listView(items: items, ordered: ordered)
        case .image(_, let image):
            let resource = image.asCommunityImage
            Button {
                onOpenImage(image)
            } label: {
                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                    RemoteCachedStillImage(
                        url: resource.thumbnailURL, fallbackURL: resource.originalURL
                    )
                    .frame(maxWidth: .infinity, minHeight: AppDesignSystem.Size.Media.draft)
                    .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))

                    if let caption = image.caption, containsVisibleText(caption) {
                        PaperRichTextView(
                            text: caption, textStyle: AppDesignSystem.Typography.uiCaption,
                            textColor: .secondaryLabel)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(imageAccessibilityLabel(for: image))
            .accessibilityHint("打开图片预览")
            .accessibilityIdentifier("ui.paper-content-block-view.image")
        }
    }

    @ViewBuilder
    private func listView(items: [AttributedString], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let prefix = ordered ? "\(index + 1)." : "•"
                HStack(alignment: .top, spacing: AppDesignSystem.Spacing.regular) {
                    Text(prefix)
                        .font(AppDesignSystem.Typography.bodyEmphasis)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                    PaperRichTextView(
                        text: item, textStyle: AppDesignSystem.Typography.uiBody,
                        textColor: .label)
                }
            }
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
            return AppDesignSystem.Typography.uiTitle
        case 2:
            return AppDesignSystem.Typography.uiTitle
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
    @Environment(\.openURL) private var openURL
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    let text: AttributedString
    let textStyle: UIFont.TextStyle
    let textColor: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(openURL: openURL, interactionEvidence: interactionEvidence)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.accessibilityIdentifier = "paper.body.rich-text"
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [
            .foregroundColor: UIColor(AppDesignSystem.Palette.Accent.primary)
        ]
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.openURL = openURL
        context.coordinator.interactionEvidence = interactionEvidence
        let baseFont = UIFont.preferredFont(
            forTextStyle: textStyle, compatibleWith: uiView.traitCollection)
        let coordinator = context.coordinator
        guard
            coordinator.renderedText != text || coordinator.renderedFont != baseFont
                || coordinator.renderedColor != textColor
        else { return }
        coordinator.renderedText = text
        coordinator.renderedFont = baseFont
        coordinator.renderedColor = textColor
        uiView.attributedText = normalizedAttributedText(baseFont: baseFont)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context)
        -> CGSize?
    {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fittingSize.height)
    }

    private func normalizedAttributedText(baseFont: UIFont) -> NSAttributedString {
        let source = NSAttributedString(text)
        let mutable = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: mutable.length)

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
        let descriptor =
            baseFont.fontDescriptor.withSymbolicTraits(wantedTraits) ?? baseFont.fontDescriptor
        return UIFont(descriptor: descriptor, size: baseFont.pointSize)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction
        var interactionEvidence: ((String, String) -> Void)?
        var renderedText: AttributedString?
        var renderedFont: UIFont?
        var renderedColor: UIColor?

        init(openURL: OpenURLAction, interactionEvidence: ((String, String) -> Void)?) {
            self.openURL = openURL
            self.interactionEvidence = interactionEvidence
        }

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { return nil }
            return UIAction(title: defaultAction.title, image: defaultAction.image) {
                [weak self] _ in
                self?.interactionEvidence?("interaction.PaperRichTextView.link", "tap")
                self?.openURL(url)
            }
        }
    }
}

#endif
