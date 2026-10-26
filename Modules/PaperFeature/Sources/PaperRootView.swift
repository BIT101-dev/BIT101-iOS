#if os(iOS)
import MediaKit
import CommunityUI
import CommunityCore
import TransportCore
import DesignSystemKit
//
//  PaperRootView.swift
//  BIT101-iOS
import SwiftUI

/// 文章模块根视图。
///
/// 话廊中的文章场景，负责文章列表、搜索和详情跳转。
public struct PaperRootView: View {
    private let scene: PaperRootViewScene
    private let identity: [ObjectIdentifier]

    public init(dependencies: PaperDependencies,
        media: MediaEnvironment,
        requestedPaperID: Binding<Int?> = .constant(nil),
        onShowFeed: @escaping () -> Void = {}) {
        scene = PaperRootViewScene(dependencies: dependencies, media: media, requestedPaperID: requestedPaperID, onShowFeed: onShowFeed)
        identity = [ObjectIdentifier(dependencies), ObjectIdentifier(media)]
    }

    public var body: some View {
        scene.id(identity)
    }
}

private struct PaperRootViewScene: View {
    @Environment(\.appWindowLayout) private var layout
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let dependencies: PaperDependencies
    private let media: MediaEnvironment
    @StateObject private var viewModel: PaperListViewModel
    @State private var isShowingComposer = false
    @State private var isShowingSearch = false
    @State private var selectedPaper: PaperSummary?
    @State private var currentTopPaperID: Int?
    @Binding var requestedPaperID: Int?
    private let onShowFeed: () -> Void

    init(
        dependencies: PaperDependencies,
        media: MediaEnvironment,
        requestedPaperID: Binding<Int?> = .constant(nil),
        onShowFeed: @escaping () -> Void = {}
    ) {
        self.dependencies = dependencies
        self.media = media
        _requestedPaperID = requestedPaperID
        _viewModel = StateObject(wrappedValue: PaperListViewModel(service: dependencies.list))
        self.onShowFeed = onShowFeed
    }

    var body: some View {
        AppBrowserLayout(selection: $selectedPaper, title: "选择一篇文章", symbol: "doc.text") {
            content
        } detail: { paper in
            PaperDetailView(dependencies: dependencies, media: media, initialPaper: paper, onDeleted: { selectedPaper = nil }) {
                viewModel.enqueueRefresh()
            }
        }
        .sheet(isPresented: $isShowingComposer) {
            NavigationStack {
                PaperComposerView(initialContent: "", currentIdentity: dependencies.currentIdentity) {
                    handleComposerCreated()
                }
            }
        }
        .sheet(isPresented: $isShowingSearch) {
            NavigationStack {
                PaperSearchView(dependencies: dependencies, media: media)
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
            viewModel.retryFailedPreviews()
        }
        .task(id: requestedPaperID) {
            consumeDeepLinkedPaperIfNeeded(requestedPaperID)
        }
        .onChange(of: viewModel.selectedOrder) { oldValue, newValue in
            guard oldValue != newValue else { return }
            viewModel.enqueueRefresh()
        }
        .communityReadRecovery(networkPath: dependencies.networkPath,
            isEnabled: !isShowingComposer && !isShowingSearch && selectedPaper == nil) {
            if viewModel.needsRefresh { await viewModel.refresh() }
            else if viewModel.state.paginationError != nil {
                await viewModel.loadMoreIfNeeded(currentPaper: viewModel.state.items.last)
            }
            viewModel.retryFailedPreviews()
        }
        .onDisappear { viewModel.cancelRefreshOperations() }
        .diagnosticAlert(item: $viewModel.alert)
        .environment(dependencies).environment(media)
    }

    private var content: some View {
        ZStack(alignment: .bottomTrailing) {
            AppDesignSystem.Palette.Background.grouped
                .ignoresSafeArea(edges: .bottom)

            ScrollView {
                LazyVStack(spacing: AppDesignSystem.Spacing.none) {
                    CommunityResultsContext(viewModel.displayedQueryDescription)
                    switch viewModel.state.status {
                    case .idle where viewModel.state.items.isEmpty,
                         .loading where viewModel.state.items.isEmpty:
                        AppInlineLoadingState("正在加载文章")
                    case let .failed(message) where viewModel.state.items.isEmpty:
                        AppScrollStateContainer {
                            AppFailureState(
                                title: "加载文章失败",
                                systemImage: "doc.text.magnifyingglass",
                                message: message,
                                onRetry: {
                                    viewModel.enqueueRefresh()
                                }
                            )
                        }
                    default:
                        if viewModel.state.items.isEmpty {
                            AppScrollStateContainer {
                                AppEmptyState(
                                    title: "暂无文章",
                                    systemImage: "doc.text",
                                    message: "还没有可展示的文章。"
                                )
                            }
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible())], spacing: AppDesignSystem.Spacing.none) {
                                ForEach(Array(viewModel.state.items.enumerated()), id: \.element.id) { index, paper in
                                    AppFeedRow(isLast: index == viewModel.state.items.count - 1, isSelected: selectedPaper?.id == paper.id) {
                                        PaperSummaryCard(
                                            paper: paper,
                                            previewMetadata: viewModel.previewMetadata(for: paper.id),
                                            previewFailed: viewModel.previewFailedIDs.contains(paper.id),
                                            onOpen: {
                                                selectedPaper = paper
                                            }
                                        )
                                        .accessibilityElement(children: .combine)
                                        .accessibilityAddTraits(.isButton)
                                        .accessibilityHint("打开文章详情")
                                    }
                                    .id(paper.id)
                                    .task(id: viewModel.previewGeneration) {
                                        await viewModel.loadPreviewMetadataIfNeeded(for: paper)
                                    }
                                    .task(id: viewModel.state.status == .loaded ? viewModel.state.nextPage : nil) {
                                        await viewModel.loadMoreIfNeeded(currentPaper: paper)
                                    }
                                }
                            }
                            .scrollTargetLayout()

                            CommunityPaginationFooter(isLoading: viewModel.state.isLoadingMore,
                                errorMessage: viewModel.state.paginationError) {
                                await viewModel.loadMoreIfNeeded(currentPaper: viewModel.state.items.last)
                            }
                        }
                }
            }
            .padding(.bottom, AppDesignSystem.Size.Layout.floatingActionContentInset)
            }
            .scrollPosition(id: Binding(get: { currentTopPaperID },
                set: { if let value = $0 { currentTopPaperID = value } }), anchor: .top)
            .refreshable {
                    interactionEvidence?("interaction.PaperRootViewScene.refreshable", "refresh")

                await viewModel.enqueueRefresh().value
            }
            .simultaneousGesture(sortSwitchGesture)
            .accessibilityIdentifier("paper.sort-surface")


        }
        .appBrowserActions(expanded: layout.isLandscape) {
                AppFloatingActionButton(systemImage: "square.and.pencil", accessibilityLabel: "发布文章") {
                    isShowingComposer = true
                }

                AppFloatingActionButton(systemImage: "magnifyingglass", accessibilityLabel: "搜索文章") {
                    isShowingSearch = true
                }
        }
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            AppTopSegmentedPicker(
                title: "文章排序",
                selection: $viewModel.selectedOrder,
                variant: .stacked
            ) {
                ForEach(PaperSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
        }

    }

    private func consumeDeepLinkedPaperIfNeeded(_ paperID: Int?) {
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
        viewModel.selectedOrder = .newest
        viewModel.enqueueRefresh()
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
            withAnimation(AppDesignSystem.Motion.transition(reduceMotion: reduceMotion)) {
                onShowFeed()
            }
            return
        }

        let nextIndex = currentIndex + step
        guard allOrders.indices.contains(nextIndex) else { return }

        withAnimation(AppDesignSystem.Motion.transition(reduceMotion: reduceMotion)) {
            viewModel.selectedOrder = allOrders[nextIndex]
        }
    }
}

#endif
