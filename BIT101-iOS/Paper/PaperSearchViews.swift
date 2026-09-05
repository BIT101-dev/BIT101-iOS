//
//  PaperSearchViews.swift
//  BIT101-iOS
//
//  Split from PaperRootView.swift.
//

import SwiftUI

struct PaperSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = PaperSearchViewModel()
    @State private var selectedPaper: PaperSummary?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    AppEmptyState(
                        title: "搜索文章",
                        systemImage: "magnifyingglass",
                        message: "输入关键词后再搜索文章。"
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    switch viewModel.state.status {
                    case .idle where viewModel.state.items.isEmpty,
                         .loading where viewModel.state.items.isEmpty:
                        AppInlineLoadingState("正在搜索文章")
                    case let .failed(message) where viewModel.state.items.isEmpty:
                        AppScrollStateContainer {
                            AppFailureState(
                                title: "搜索失败",
                                systemImage: "doc.text.magnifyingglass",
                                message: message,
                                onRetry: {
                                    Task {
                                        await viewModel.performSearch()
                                    }
                                }
                            )
                        }
                    default:
                        if visiblePapers.isEmpty {
                            AppScrollStateContainer {
                                AppEmptyState(
                                    title: "没有找到相关文章",
                                    systemImage: "doc.text.magnifyingglass",
                                    message: "换个关键词试试。"
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
            }
            .padding(.vertical, AppDesignSystem.Spacing.content)
        }
        .background(AppDesignSystem.Palette.groupedBackground)
        .refreshable {
            await viewModel.performSearch()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            AppSearchBarContainer {
                AppOrderedSearchBar(
                    text: $viewModel.searchText,
                    order: $viewModel.selectedOrder,
                    selectedOrderTitle: viewModel.selectedOrder.title,
                    onSubmit: {
                        Task {
                            await viewModel.performSearch()
                        }
                    },
                    onClear: {
                        viewModel.searchText = ""
                        viewModel.reset()
                    }
                ) {
                    ForEach(PaperSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
            }
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
        .diagnosticAlert(item: $viewModel.alert)
    }

    private var visiblePapers: [PaperSummary] { viewModel.state.items }

    private func paginationProbePaper(currentPaper: PaperSummary) -> PaperSummary {
        guard currentPaper.id == visiblePapers.last?.id else { return currentPaper }
        return viewModel.state.items.last ?? currentPaper
    }
}


/// 文章摘要行。
///
/// 视觉上和话廊信息流对齐：使用整行白底，而不是独立圆角卡片。
/// 这样文章、话题两个内容流在同一层级切换时不会显得割裂。
