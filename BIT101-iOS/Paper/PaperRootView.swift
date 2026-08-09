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
