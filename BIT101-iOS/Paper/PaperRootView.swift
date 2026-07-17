//
//  PaperRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-01.
//

import SwiftUI
import UIKit
import Network
import Combine

/// 文章模块根视图。
///
/// 这里承接底部栏里的“文章”入口，负责文章列表、搜索和详情跳转。
struct PaperRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = PaperListViewModel()
    @StateObject private var networkObserver = PaperNetworkObserver()
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var isShowingComposer = false
    @State private var isShowingSearch = false
    @State private var selectedPaper: PaperSummary?
    @Binding var requestedPaperID: Int?
    @Binding private var selectedGallerySurfaceRawValue: String
    @State private var deepLinkedPaper: PaperSummary?

    init(
        requestedPaperID: Binding<Int?> = .constant(nil),
        selectedGallerySurfaceRawValue: Binding<String> = .constant("paper")
    ) {
        _requestedPaperID = requestedPaperID
        _selectedGallerySurfaceRawValue = selectedGallerySurfaceRawValue
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(.systemGroupedBackground)
                .ignoresSafeArea(edges: .bottom)

            ScrollView {
                LazyVStack(spacing: 0) {
                    switch viewModel.state.status {
                    case .idle where viewModel.state.items.isEmpty:
                        ProgressView("正在加载文章")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    case .loading where viewModel.state.items.isEmpty:
                        ProgressView("正在加载文章")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    case let .failed(message) where viewModel.state.items.isEmpty:
                        PaperEmptyState(
                            systemImage: "doc.text.magnifyingglass",
                            title: "加载文章失败",
                            message: message,
                            onRetry: {
                                Task {
                                    await viewModel.refresh()
                                }
                            }
                        )
                        .padding(.top, 48)
                    default:
                        if visiblePapers.isEmpty {
                            PaperEmptyState(
                                systemImage: "doc.text",
                                title: "暂无文章",
                                message: "还没有可展示的文章。"
                            )
                            .padding(.top, 48)
                        } else {
                            ForEach(Array(visiblePapers.enumerated()), id: \.element.id) { index, paper in
                                VStack(spacing: 0) {
                                    PaperSummaryCard(
                                        paper: paper,
                                        previewMetadata: viewModel.previewMetadata(for: paper.id),
                                        onOpen: {
                                            selectedPaper = paper
                                        },
                                        onHide: {
                                            settings.hidePaper(id: paper.id)
                                        }
                                    )

                                    if index != visiblePapers.count - 1 {
                                        Divider()
                                            .padding(.leading, 14)
                                    }
                                }
                                .task {
                                    await viewModel.loadPreviewMetadataIfNeeded(for: paper)
                                    await viewModel.loadMoreIfNeeded(currentPaper: paginationProbePaper(currentPaper: paper))
                                }
                            }

                            if viewModel.state.isLoadingMore {
                                ProgressView("正在加载更多")
                                    .padding(.vertical, 12)
                            }
                        }
                }
            }
            .padding(.bottom, 84)
            }
            .refreshable {
                await viewModel.refresh()
            }
            .simultaneousGesture(sortSwitchGesture)

            VStack(spacing: 10) {
                PaperFloatingActionButton(systemImage: "square.and.pencil") {
                    isShowingComposer = true
                }

                PaperFloatingActionButton(systemImage: "magnifyingglass") {
                    isShowingSearch = true
                }
            }
            .padding(.trailing, 10)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .top) {
            Picker("文章排序", selection: $viewModel.selectedOrder) {
                ForEach(PaperSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Color(.systemGroupedBackground))
        }
        .navigationDestination(item: $selectedPaper) { paper in
            PaperDetailView(initialPaper: paper)
        }
        .navigationDestination(item: $deepLinkedPaper) { paper in
            PaperDetailView(initialPaper: paper)
        }
        .sheet(isPresented: $isShowingComposer) {
            NavigationStack {
                PaperComposerView {
                    Task {
                        await handleComposerCreated()
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingSearch) {
            NavigationStack {
                PaperSearchView()
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .task(id: requestedPaperID) {
            consumeDeepLinkedPaperIfNeeded(requestedPaperID)
        }
        .onChange(of: requestedPaperID) { _, newValue in
            consumeDeepLinkedPaperIfNeeded(newValue)
        }
        .onChange(of: viewModel.selectedOrder) { oldValue, newValue in
            guard oldValue != newValue else { return }
            Task {
                await viewModel.refresh()
            }
        }
        .onChange(of: networkObserver.isReachable) { oldValue, newValue in
            guard newValue, !oldValue else { return }
            Task {
                await retryListIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            Task {
                await retryListIfNeeded()
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

    private func consumeDeepLinkedPaperIfNeeded(_ paperID: Int?) {
        guard let paperID else { return }
        deepLinkedPaper = PaperSummary(
            id: paperID,
            title: "文章",
            intro: "",
            likeNum: 0,
            commentNum: 0,
            updateTime: ""
        )
        requestedPaperID = nil
    }

    /// 文章列表停在失败空态时，在网络恢复或回前台后自动补拉一次。
    private func retryListIfNeeded() async {
        guard networkObserver.isReachable else { return }
        let state = viewModel.state
        guard case .failed = state.status, state.items.isEmpty else { return }
        await viewModel.refresh()
    }

    /// 当前真正应显示在文章首页的列表。
    ///
    /// 文章本地屏蔽优先级最高；如果作者预览信息已经补齐，则顺手复用画廊现有的“隐藏匿名/隐藏用户”规则。
    private var visiblePapers: [PaperSummary] {
        viewModel.state.items.filter { paper in
            guard !settings.paperHiddenIDs.contains(paper.id) else { return false }
            guard let metadata = viewModel.previewMetadata(for: paper.id) else { return true }
            if metadata.anonymous, settings.galleryHiddenUserIDs.first == -1 {
                return false
            }
            if let authorID = metadata.authorID, settings.galleryHiddenUserIDs.contains(authorID) {
                return false
            }
            return true
        }
    }

    /// 当尾部若干篇文章被本地隐藏后，分页触发应继续参考原始数据尾部，而不是只看过滤后的结果。
    private func paginationProbePaper(currentPaper: PaperSummary) -> PaperSummary {
        guard currentPaper.id == visiblePapers.last?.id else { return currentPaper }
        return viewModel.state.items.last ?? currentPaper
    }

    /// 发文成功后统一切回默认列表条件，并重新拉文章列表。
    @MainActor
    private func handleComposerCreated() async {
        viewModel.searchText = ""
        viewModel.selectedOrder = .newest
        await viewModel.refresh()
    }

    /// 文章排序左右轻扫切换手势。
    ///
    /// 当已经位于最左或最右的排序分区时，继续向外轻扫会切回“话题”页。
    private var sortSwitchGesture: some Gesture {
        makeHorizontalSwitchGesture(onStep: switchSortOrder)
    }

    private func switchSortOrder(step: Int) {
        let allOrders = PaperSortOrder.allCases
        guard let currentIndex = allOrders.firstIndex(of: viewModel.selectedOrder) else { return }
        let lastIndex = allOrders.index(before: allOrders.endIndex)

        if (currentIndex == 0 && step == -1) || (currentIndex == lastIndex && step == 1) {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedGallerySurfaceRawValue = "gallery"
            }
            return
        }

        let nextIndex = currentIndex + step
        guard allOrders.indices.contains(nextIndex) else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.selectedOrder = allOrders[nextIndex]
        }
    }
}

private struct PaperSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = PaperSearchViewModel()
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var selectedPaper: PaperSummary?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PaperEmptyState(
                        systemImage: "magnifyingglass",
                        title: "搜索文章",
                        message: "输入关键词后再搜索文章。"
                    )
                    .padding(.top, 48)
                } else {
                    switch viewModel.state.status {
                    case .idle where viewModel.state.items.isEmpty,
                         .loading where viewModel.state.items.isEmpty:
                        ProgressView("正在搜索文章")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    case let .failed(message) where viewModel.state.items.isEmpty:
                        PaperEmptyState(
                            systemImage: "doc.text.magnifyingglass",
                            title: "搜索失败",
                            message: message,
                            onRetry: {
                                Task {
                                    await viewModel.performSearch()
                                }
                            }
                        )
                        .padding(.top, 48)
                    default:
                        if visiblePapers.isEmpty {
                            PaperEmptyState(
                                systemImage: "doc.text.magnifyingglass",
                                title: "没有找到相关文章",
                                message: "换个关键词试试。"
                            )
                            .padding(.top, 48)
                        } else {
                            ForEach(Array(visiblePapers.enumerated()), id: \.element.id) { index, paper in
                                VStack(spacing: 0) {
                                    PaperSummaryCard(
                                        paper: paper,
                                        previewMetadata: viewModel.previewMetadata(for: paper.id),
                                        onOpen: {
                                            selectedPaper = paper
                                        },
                                        onHide: {
                                            settings.hidePaper(id: paper.id)
                                        }
                                    )

                                    if index != visiblePapers.count - 1 {
                                        Divider()
                                            .padding(.leading, 14)
                                    }
                                }
                                .task {
                                    await viewModel.loadPreviewMetadataIfNeeded(for: paper)
                                    await viewModel.loadMoreIfNeeded(currentPaper: paginationProbePaper(currentPaper: paper))
                                }
                            }

                            if viewModel.state.isLoadingMore {
                                ProgressView("正在加载更多")
                                    .padding(.vertical, 12)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await viewModel.performSearch()
        }
        .safeAreaInset(edge: .top) {
            PaperSearchBar(
                searchText: $viewModel.searchText,
                selectedOrder: $viewModel.selectedOrder,
                onSubmit: {
                    Task {
                        await viewModel.performSearch()
                    }
                },
                onClear: {
                    viewModel.searchText = ""
                    viewModel.reset()
                }
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.thinMaterial)
        }
        .onChange(of: viewModel.searchText) { _, newValue in
            guard newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            viewModel.reset()
        }
        .onChange(of: viewModel.selectedOrder) { oldValue, newValue in
            guard oldValue != newValue else { return }
            guard !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task {
                await viewModel.performSearch()
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedPaper) { paper in
            PaperDetailView(initialPaper: paper)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
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

    private var visiblePapers: [PaperSummary] {
        viewModel.state.items.filter { paper in
            guard !settings.paperHiddenIDs.contains(paper.id) else { return false }
            guard let metadata = viewModel.previewMetadata(for: paper.id) else { return true }
            if metadata.anonymous, settings.galleryHiddenUserIDs.first == -1 {
                return false
            }
            if let authorID = metadata.authorID, settings.galleryHiddenUserIDs.contains(authorID) {
                return false
            }
            return true
        }
    }

    private func paginationProbePaper(currentPaper: PaperSummary) -> PaperSummary {
        guard currentPaper.id == visiblePapers.last?.id else { return currentPaper }
        return viewModel.state.items.last ?? currentPaper
    }
}

/// 文章搜索栏。
///
/// 这里直接对齐话廊搜索栏的结构：左侧排序菜单，中间搜索输入，右侧清空按钮。
/// 这样文章与话廊两个内容模块的搜索入口会更统一。
private struct PaperSearchBar: View {
    @Binding var searchText: String
    @Binding var selectedOrder: PaperSortOrder
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker(
                selection: Binding(
                    get: { selectedOrder },
                    set: { newValue in
                        selectedOrder = newValue
                        onSubmit()
                    }
                )
            ) {
                ForEach(PaperSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            } label: {
                Label(selectedOrder.title, systemImage: "arrow.up.arrow.down.circle")
            }
            .pickerStyle(.menu)

            TextField("在这里搜索哦", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)

            Button {
                searchText = ""
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(searchText.isEmpty ? Color.secondary.opacity(0.35) : Color.orange)
            }
            .buttonStyle(.plain)
            .disabled(searchText.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 文章摘要行。
///
/// 视觉上和话廊信息流对齐：使用整行白底，而不是独立圆角卡片。
/// 这样文章、话题两个内容流在同一层级切换时不会显得割裂。
private struct PaperSummaryCard: View {
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

private struct PaperEmptyState: View {
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

private struct PaperDetailView: View {
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

                HStack(spacing: 18) {
                    Text("\(viewModel.paper?.likeNum ?? initialPaper.likeNum)赞")
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
        .fullScreenCover(item: $imageViewer) { viewer in
            GalleryImageViewer(viewer: viewer)
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
                    CachedRemoteImage(url: image.preferredRemoteURL) { renderedImage in
                        renderedImage
                            .resizable()
                            .scaledToFit()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.orange)
                            }
                    }
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

private struct PaperCommentsSection: View {
    let comments: [GalleryComment]
    let totalCommentCount: Int
    let status: GalleryFeedStatus
    let isLoadingMore: Bool
    let selectedOrder: GalleryCommentOrder
    let likingCommentIDs: Set<Int>
    let onSelectOrder: (GalleryCommentOrder) -> Void
    let onReply: (PaperCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onLoadMore: (GalleryComment?) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("评论")
                    .font(.headline)
                Text("\(totalCommentCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("排序", selection: Binding(get: { selectedOrder }, set: onSelectOrder)) {
                    ForEach(GalleryCommentOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.menu)
            }

            switch status {
            case .idle where comments.isEmpty, .loading where comments.isEmpty:
                ProgressView("正在加载评论")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            case let .failed(message):
                PaperEmptyState(
                    systemImage: "text.bubble",
                    title: "加载评论失败",
                    message: message,
                    onRetry: onRetry
                )
            case .loaded:
                if comments.isEmpty {
                    Text(totalCommentCount == 0 ? "还没有评论" : "评论已根据社区规范隐藏")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                            VStack(spacing: 0) {
                                PaperCommentRow(
                                    comment: comment,
                                    likingCommentIDs: likingCommentIDs,
                                    onReply: onReply,
                                    onLikeComment: onLikeComment
                                )

                                if index != comments.count - 1 {
                                    Divider()
                                        .padding(.leading, 46)
                                }
                            }
                            .onAppear {
                                onLoadMore(comment)
                            }
                        }

                        if isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        }
                    }
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    }
                }
            default:
                EmptyView()
            }
        }
    }
}

/// 文章模块的轻量网络可达性观察器。
///
/// 这里只服务“失败后自动再试”的体验兜底，不承担全局联网状态管理。
@MainActor
private final class PaperNetworkObserver: ObservableObject {
    @Published private(set) var isReachable = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "BIT101.PaperNetworkObserver")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isReachable = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isReachable = isReachable
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

private struct PaperCommentReplyTarget {
    let mainComment: GalleryComment
    let targetComment: GalleryComment
}

private struct PaperCommentRow: View {
    let comment: GalleryComment
    let likingCommentIDs: Set<Int>
    let onReply: (PaperCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaperCommentBubble(
                comment: comment,
                isSubComment: false,
                isLiking: likingCommentIDs.contains(comment.id),
                onReply: {
                    onReply(.init(mainComment: comment, targetComment: comment))
                },
                onLikeComment: {
                    onLikeComment(comment)
                }
            )

            if !comment.sub.isEmpty {
                VStack(spacing: 0) {
                    ForEach(comment.sub) { subComment in
                        VStack(spacing: 0) {
                            PaperCommentBubble(
                                comment: subComment,
                                isSubComment: true,
                                isLiking: likingCommentIDs.contains(subComment.id),
                                onReply: {
                                    onReply(.init(mainComment: comment, targetComment: subComment))
                                },
                                onLikeComment: {
                                    onLikeComment(subComment)
                                }
                            )

                            if subComment.id != comment.sub.last?.id {
                                Divider()
                                    .padding(.leading, 42)
                            }
                        }
                    }
                }
                .padding(.leading, 42)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

private struct PaperCommentBubble: View {
    let comment: GalleryComment
    let isSubComment: Bool
    let isLiking: Bool
    let onReply: () -> Void
    let onLikeComment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                CachedRemoteImage(url: comment.user.avatar.preferredRemoteURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                }
                .frame(width: isSubComment ? 28 : 34, height: isSubComment ? 28 : 34)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(comment.user.nickname)
                            .font(isSubComment ? .subheadline.weight(.semibold) : .headline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(PaperDateText.timestampString(from: comment.updateTime))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    if !comment.replyObj.isEmpty, comment.replyUser.id > 0 {
                        Text("回复 @\(comment.replyUser.nickname)：")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Text(comment.text)
                        .font(isSubComment ? .subheadline : .body)
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 14) {
                Button(action: onReply) {
                    Label("回复", systemImage: "arrowshape.turn.up.left")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                    .buttonStyle(.plain)
                Button {
                    onLikeComment()
                } label: {
                    Label {
                        Text("\(comment.likeNum)")
                            .font(.caption)
                    } icon: {
                        Image(systemName: comment.like ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLiking)
            }
            .padding(.leading, isSubComment ? 38 : 44)
        }
    }
}

/// 文章列表和详情复用的文章操作菜单。
///
/// 当前先提供最小能力：本地隐藏本文。
private struct PaperArticleActionMenu: View {
    let onHide: () -> Void
    @State private var isPresentingFallbackActions = false

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                Menu {
                    Button("屏蔽本文", systemImage: "eye.slash") {
                        onHide()
                    }
                } label: {
                    menuLabel
                }
            } else {
                Button {
                    isPresentingFallbackActions = true
                } label: {
                    menuLabel
                }
                .confirmationDialog("", isPresented: $isPresentingFallbackActions, titleVisibility: .hidden) {
                    Button("屏蔽本文", systemImage: "eye.slash") {
                        onHide()
                    }
                    Button("取消", role: .cancel) {}
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var menuLabel: some View {
        Image(systemName: "ellipsis.circle")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
    }
}

/// 文章右下角悬浮操作按钮。
///
/// 这里直接对齐话廊现有的按钮尺寸和材质，避免两个内容页入口按钮风格割裂。
private struct PaperFloatingActionButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// 文章发布页。
///
/// 当前先提供最小原生编辑器：标题、简介、正文、匿名开关。
/// 正文会在提交前包装成最小 Editor.js JSON，避免和网页端内容格式割裂。
private struct PaperComposerView: View {
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var intro = ""
    @State private var content = ""
    @State private var anonymous = false
    @State private var isSubmitting = false
    @State private var alert: AppAlert?

    private let service = PaperService()

    var body: some View {
        Form {
            Section("内容") {
                TextField("标题", text: $title)
                TextField("简介", text: $intro, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                TextField("正文", text: $content, axis: .vertical)
                    .lineLimit(10, reservesSpace: true)
            }

            Section("发布设置") {
                Toggle("匿名发布", isOn: $anonymous)
            }
        }
        .navigationTitle("发布文章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(isSubmitting ? "发布中…" : "发布") {
                    Task {
                        await submit()
                    }
                }
                .disabled(isSubmitting)
            }
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private func submit() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIntro = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty, !trimmedIntro.isEmpty, !trimmedContent.isEmpty else {
            alert = AppAlert(title: "发布失败", message: "标题、简介和正文都不能为空。")
            return
        }

        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await service.createPaper(
                title: trimmedTitle,
                intro: trimmedIntro,
                content: PaperEditorContentBuilder.editorJSON(from: trimmedContent),
                anonymous: anonymous
            )
            onCreated()
            dismiss()
        } catch {
            alert = AppAlert(title: "发布失败", message: error.localizedDescription)
        }
    }
}

private struct PaperCommentComposerSheet: View {
    let target: PaperCommentComposerTarget
    let isSubmitting: Bool
    let onSubmit: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var anonymous = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                } header: {
                    Text(target.title)
                }

                Section {
                    Toggle("匿名评论", isOn: $anonymous)
                }
            }
        }
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(isSubmitting ? "发送中…" : "发布") {
                    onSubmit(text, anonymous)
                }
                .disabled(isSubmitting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct PaperActionPillButtonStyle: ButtonStyle {
    let accentColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
