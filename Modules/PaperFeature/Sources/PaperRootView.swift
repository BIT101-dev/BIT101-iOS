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
/// 这里承接底部栏里的“文章”入口，负责文章列表、搜索和详情跳转。
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
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let dependencies: PaperDependencies
    private let media: MediaEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: PaperListViewModel
    private var networkObserver: NetworkPathState { dependencies.networkPath }
    @State private var isShowingComposer = false
    @State private var isShowingSearch = false
    @State private var selectedPaper: PaperSummary?
    @Binding var requestedPaperID: Int?
    private let onShowFeed: () -> Void
    @State private var deepLinkedPaper: PaperSummary?

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
        content.environment(dependencies).environment(media)
    }

    private var content: some View {
        ZStack(alignment: .bottomTrailing) {
            AppDesignSystem.Palette.Background.grouped
                .ignoresSafeArea(edges: .bottom)

            ScrollView {
                LazyVStack(spacing: AppDesignSystem.Spacing.none) {
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
                            ForEach(Array(viewModel.state.items.enumerated()), id: \.element.id) { index, paper in
                                AppFeedRow(isLast: index == viewModel.state.items.count - 1) {
                                    PaperSummaryCard(
                                        paper: paper,
                                        previewMetadata: viewModel.previewMetadata(for: paper.id),
                                        onOpen: {
                                            selectedPaper = paper
                                        }
                                    )
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityHint("打开文章详情")
                                }
                                .task(id: viewModel.refreshGeneration) {
                                    await viewModel.loadPreviewMetadataIfNeeded(for: paper)
                                }
                                .task {
                                    await viewModel.loadMoreIfNeeded(currentPaper: paper)
                                }
                            }

                            if viewModel.state.isLoadingMore {
                                AppInlineLoadingState("正在加载更多")
                            }
                        }
                }
            }
            .padding(.bottom, AppDesignSystem.Size.Layout.floatingActionContentInset)
            }
            .refreshable {
                    interactionEvidence?("interaction.PaperRootViewScene.refreshable", "refresh")

                await viewModel.refresh()
            }
            .simultaneousGesture(sortSwitchGesture)
            .accessibilityIdentifier("paper.sort-surface")

            AppFloatingActionStack {
                AppFloatingActionButton(systemImage: "square.and.pencil", accessibilityLabel: "发布文章") {
                    isShowingComposer = true
                }

                AppFloatingActionButton(systemImage: "magnifyingglass", accessibilityLabel: "搜索文章") {
                    isShowingSearch = true
                }
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
        .navigationDestination(item: $selectedPaper) { paper in
            PaperDetailView(dependencies: dependencies, media: media, initialPaper: paper) {
                viewModel.enqueueRefresh()
            }
        }
        .navigationDestination(item: $deepLinkedPaper) { paper in
            PaperDetailView(dependencies: dependencies, media: media, initialPaper: paper) {
                viewModel.enqueueRefresh()
            }
        }
        .sheet(isPresented: $isShowingComposer) {
            NavigationStack {
                PaperComposerView(initialContent: "") {
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
        }
        .task(id: requestedPaperID) {
            consumeDeepLinkedPaperIfNeeded(requestedPaperID)
        }
        .onChange(of: viewModel.selectedOrder) { oldValue, newValue in
            guard oldValue != newValue else { return }
            viewModel.enqueueRefresh()
        }
        .onChange(of: networkObserver.isReachable) { oldValue, newValue in
            guard newValue, !oldValue else { return }
            retryListIfNeeded()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            retryListIfNeeded()
        }
        .onDisappear { viewModel.cancelRefreshOperations() }
        .diagnosticAlert(item: $viewModel.alert)
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
    private func retryListIfNeeded() {
        guard networkObserver.isReachable else { return }
        let state = viewModel.state
        guard case .failed = state.status, state.items.isEmpty else { return }
        viewModel.enqueueRefresh()
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
