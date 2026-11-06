#if os(iOS)
import MediaKit
import CommunityUI
import CommunityCore
import TransportCore
import DesignSystemKit
import SwiftUI

/// 文章模块根视图。
///
/// 话廊中的文章场景，负责文章列表、搜索和详情跳转。
public struct PaperRootView: View {
    private let scene: PaperRootViewScene
    private let identity: [ObjectIdentifier]

    public init(
        dependencies: PaperDependencies,
        media: MediaEnvironment,
        requestedPaperID: Binding<Int?> = .constant(nil)
    ) {
        scene = PaperRootViewScene(
            dependencies: dependencies, media: media, requestedPaperID: requestedPaperID)
        identity = [ObjectIdentifier(dependencies), ObjectIdentifier(media)]
    }

    public var body: some View {
        scene.id(identity)
    }
}

private struct PaperRootViewScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let dependencies: PaperDependencies
    private let media: MediaEnvironment
    @State private var feeds: PaperSortFeeds
    @State private var isShowingComposer = false
    @State private var isShowingSearch = false
    @State private var selectedPaper: PaperSummary?
    @Binding var requestedPaperID: Int?
    private var viewModel: PaperListViewModel { feeds.current }

    init(
        dependencies: PaperDependencies,
        media: MediaEnvironment,
        requestedPaperID: Binding<Int?> = .constant(nil)
    ) {
        self.dependencies = dependencies
        self.media = media
        _requestedPaperID = requestedPaperID
        _feeds = State(initialValue: PaperSortFeeds(service: dependencies.list))
    }

    var body: some View {
        AppBrowserLayout(selection: $selectedPaper, title: "选择一篇文章", symbol: "doc.text") {
            content
        } detail: { paper in
            PaperDetailView(
                dependencies: dependencies, media: media, initialPaper: paper,
                onDeleted: { selectedPaper = nil }
            ) {
                viewModel.enqueueRefresh()
            }
        }
        .sheet(isPresented: $isShowingComposer) {
            NavigationStack {
                PaperComposerView(
                    initialContent: "", currentIdentity: dependencies.currentIdentity
                ) {
                    handleComposerCreated()
                }
            }
        }
        .sheet(isPresented: $isShowingSearch) {
            NavigationStack {
                PaperSearchView(dependencies: dependencies, media: media)
            }
        }
        .task(id: viewModel.selectedOrder) {
            let model = viewModel
            if model.needsRefresh { await model.refresh() } else { await model.bootstrapIfNeeded() }
            model.retryFailedPreviews()
        }
        .task(id: requestedPaperID) {
            consumePaperLink(requestedPaperID)
        }
        .communityReadRecovery(
            networkPath: dependencies.networkPath,
            isEnabled: !isShowingComposer && !isShowingSearch && selectedPaper == nil
        ) {
            if viewModel.needsRefresh {
                await viewModel.refresh()
            } else if viewModel.state.paginationError != nil {
                await viewModel.loadMoreIfNeeded(currentPaper: viewModel.state.items.last)
            }
            viewModel.retryFailedPreviews()
        }
        .onDisappear { feeds.models.forEach { $0.cancelRefreshOperations() } }
        .diagnosticAlert(item: Binding(get: { viewModel.alert }, set: { viewModel.alert = $0 }))
        .environment(dependencies).environment(media)
    }

    private var content: some View {
        ZStack {
            AppDesignSystem.Palette.Background.grouped
                .ignoresSafeArea(edges: .bottom)
            ForEach(feeds.models, id: \.selectedOrder) { model in
                AppRetainedPage(isVisible: model === viewModel) {
                    PaperFeedPage(
                        viewModel: model, selectedPaper: $selectedPaper, onStep: switchSortOrder)
                }
            }
        }
        .appBrowserActions {
            AppFloatingActionButton(
                systemImage: "square.and.pencil", accessibilityLabel: "发布文章"
            ) {
                isShowingComposer = true
            }

            AppFloatingActionButton(systemImage: "magnifyingglass", accessibilityLabel: "搜索文章") {
                isShowingSearch = true
            }
        }
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            AppTopSegmentedPicker(
                title: "文章排序",
                selection: Binding(get: { viewModel.selectedOrder }, set: feeds.select),
                variant: .stacked
            ) {
                ForEach(PaperSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
        }

    }

    private func consumePaperLink(_ paperID: Int?) {
        guard let paperID else { return }
        selectedPaper = PaperSummary(
            id: paperID,
            title: "文章",
            intro: "",
            likeNum: 0,
            commentNum: 0,
            updateTime: ""
        )
        requestedPaperID = nil
    }

    /// 发文成功后统一切回默认列表条件，并重新拉文章列表。
    @MainActor
    private func handleComposerCreated() {
        feeds.select(.newest)
        viewModel.enqueueRefresh()
    }

    private func switchSortOrder(step: Int) {
        let allOrders = PaperSortOrder.allCases
        guard let currentIndex = allOrders.firstIndex(of: viewModel.selectedOrder) else {
            return
        }
        let nextIndex = currentIndex + step
        guard allOrders.indices.contains(nextIndex) else { return }

        withAnimation(AppDesignSystem.Motion.transition(reduceMotion: reduceMotion)) {
            feeds.select(allOrders[nextIndex])
        }
    }
}

private struct PaperFeedPage: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    @Environment(\.appPageIsVisible) private var isVisible
    @Bindable var viewModel: PaperListViewModel
    @Binding var selectedPaper: PaperSummary?
    let onStep: (Int) -> Void
    @State private var currentTopPaperID: Int?

    @ViewBuilder
    private func failureStateView(message: String) -> some View {
        AppScrollStateContainer {
            AppFailureState(
                title: "加载文章失败",
                systemImage: "doc.text.magnifyingglass",
                message: message,
                underlyingError: viewModel.state.failureCause,
                onRetry: {
                    viewModel.enqueueRefresh()
                }
            )
        }
    }

    private func paperPaginationTaskId() -> Int? {
        if viewModel.state.status == .loaded {
            return viewModel.state.nextPage
        }
        return nil
    }

    @ViewBuilder
    private func paperRow(index: Int, paper: PaperSummary) -> some View {
        AppFeedRow(
            isLast: index == viewModel.state.items.count - 1,
            isSelected: selectedPaper?.id == paper.id
        ) {
            PaperSummaryCard(
                paper: paper,
                previewMetadata: viewModel.previewMetadata(for: paper.id),
                previewFailed: viewModel.previewFailedIDs.contains(paper.id),
                onOpen: {
                    selectedPaper = paper
                }
            )
        }
        .id(paper.id)
        .task(id: isVisible ? viewModel.previewGeneration : nil) {
            guard isVisible else { return }
            await viewModel.loadPreviewMetadata(for: paper)
        }
        .task(id: isVisible ? paperPaginationTaskId() : nil) {
            guard isVisible else { return }
            await viewModel.loadMoreIfNeeded(currentPaper: paper)
        }
    }

    @ViewBuilder
    private var feedGridView: some View {
        LazyVGrid(
            columns: [GridItem(.flexible())],
            spacing: AppDesignSystem.Spacing.none
        ) {
            ForEach(
                Array(viewModel.state.items.enumerated()), id: \.element.id
            ) { index, paper in
                paperRow(index: index, paper: paper)
            }
        }
        .scrollTargetLayout()
    }

    @ViewBuilder
    private var feedPaginationFooter: some View {
        CommunityPaginationFooter(
            isLoading: viewModel.state.isLoadingMore,
            errorMessage: viewModel.state.paginationError
        ) {
            await viewModel.loadMoreIfNeeded(currentPaper: viewModel.state.items.last)
        }
    }

    @ViewBuilder
    private var feedLoadedView: some View {
        if viewModel.state.items.isEmpty {
            AppScrollStateContainer {
                AppEmptyState(
                    title: "暂无文章",
                    systemImage: "doc.text",
                    message: "还没有可展示的文章。"
                )
            }
        } else {
            feedGridView
            feedPaginationFooter
        }
    }

    @ViewBuilder
    private var paperFeedContent: some View {
        switch viewModel.state.status {
        case .idle where viewModel.state.items.isEmpty,
            .loading where viewModel.state.items.isEmpty:
            AppInlineLoadingState("正在加载文章")
        case .failed(let message) where viewModel.state.items.isEmpty:
            failureStateView(message: message)
        default:
            feedLoadedView
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AppDesignSystem.Spacing.none) {
                CommunityResultsContext(
                    viewModel.needsRefresh ? viewModel.displayedQueryDescription : nil)
                paperFeedContent
            }
        }
        .scrollPosition(
            id: Binding(
                get: { currentTopPaperID },
                set: { if let value = $0 { currentTopPaperID = value } }), anchor: .top
        )
        .refreshable {
            interactionEvidence?("interaction.PaperFeedPage.refreshable", "refresh")

            await viewModel.enqueueRefresh().value
        }
        .appPageSwitch(onStep: onStep)
        .accessibilityIdentifier("paper.sort-surface")

    }
}

#endif
