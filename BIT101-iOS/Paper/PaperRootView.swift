//
//  PaperRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-01.
//

import SwiftUI
import Network
import Combine

/// 文章模块根视图。
///
/// 这里承接底部栏里的“文章”入口，负责文章列表、搜索和详情跳转。
struct PaperRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = PaperListViewModel()
    @StateObject private var networkObserver = PaperNetworkObserver()
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
            AppDesignSystem.Palette.groupedBackground
                .ignoresSafeArea(edges: .bottom)

            ScrollView {
                LazyVStack(spacing: 0) {
                    switch viewModel.state.status {
                    case .idle where viewModel.state.items.isEmpty:
                        AppInlineLoadingState("正在加载文章")
                    case .loading where viewModel.state.items.isEmpty:
                        AppInlineLoadingState("正在加载文章")
                    case let .failed(message) where viewModel.state.items.isEmpty:
                        AppScrollStateContainer {
                            AppFailureState(
                                title: "加载文章失败",
                                systemImage: "doc.text.magnifyingglass",
                                message: message,
                                onRetry: {
                                    Task {
                                        await viewModel.refresh()
                                    }
                                }
                            )
                        }
                    default:
                        if visiblePapers.isEmpty {
                            AppScrollStateContainer {
                                AppEmptyState(
                                    title: "暂无文章",
                                    systemImage: "doc.text",
                                    message: "还没有可展示的文章。"
                                )
                            }
                        } else {
                            ForEach(Array(visiblePapers.enumerated()), id: \.element.id) { index, paper in
                                AppFeedRow(isLast: index == visiblePapers.count - 1) {
                                    PaperSummaryCard(
                                        paper: paper,
                                        previewMetadata: viewModel.previewMetadata(for: paper.id),
                                        onOpen: {
                                            selectedPaper = paper
                                        }
                                    )
                                }
                                .task {
                                    await viewModel.loadPreviewMetadataIfNeeded(for: paper)
                                    await viewModel.loadMoreIfNeeded(currentPaper: paginationProbePaper(currentPaper: paper))
                                }
                            }

                            if viewModel.state.isLoadingMore {
                                AppInlineLoadingState("正在加载更多")
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

            AppFloatingActionStack {
                AppFloatingActionButton(systemImage: "square.and.pencil", accessibilityLabel: "发布文章") {
                    isShowingComposer = true
                }

                AppFloatingActionButton(systemImage: "magnifyingglass", accessibilityLabel: "搜索文章") {
                    isShowingSearch = true
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
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
    private func retryListIfNeeded() async {
        guard networkObserver.isReachable else { return }
        let state = viewModel.state
        guard case .failed = state.status, state.items.isEmpty else { return }
        await viewModel.refresh()
    }

    /// 当前真正应显示在文章首页的列表。
    private var visiblePapers: [PaperSummary] { viewModel.state.items }

    /// 分页触发继续参考原始数据尾部，避免过滤后的列表提前停止加载。
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
