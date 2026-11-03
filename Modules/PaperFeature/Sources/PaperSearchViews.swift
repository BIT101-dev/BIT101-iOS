#if os(iOS)
import MediaKit
import CommunityUI
import CommunityCore
import DesignSystemKit
//
//  PaperSearchViews.swift
//  BIT101-iOS
import SwiftUI

struct PaperSearchView: View {
    private let scene: PaperSearchScene
    private let identity: [ObjectIdentifier]
    init(dependencies: PaperDependencies, media: MediaEnvironment, initialQuery: String = "") {
        scene = PaperSearchScene(
            dependencies: dependencies, media: media, initialQuery: initialQuery)
        identity = [ObjectIdentifier(dependencies), ObjectIdentifier(media)]
    }
    var body: some View { scene.id(identity) }
}

private struct PaperSearchScene: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    private let dependencies: PaperDependencies
    private let media: MediaEnvironment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: PaperSearchViewModel

    init(dependencies: PaperDependencies, media: MediaEnvironment, initialQuery: String) {
        self.dependencies = dependencies
        self.media = media
        let model = PaperSearchViewModel(service: dependencies.list)
        model.searchText = initialQuery
        _viewModel = StateObject(wrappedValue: model)
    }
    @State private var selectedPaper: PaperSummary?

    var body: some View { content.environment(dependencies).environment(media) }

    private var isInitialSearchState: Bool {
        viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (viewModel.state.status == .idle && viewModel.state.items.isEmpty)
    }

    @ViewBuilder
    private var initialSearchPrompt: some View {
        AppEmptyState(
            title: "搜索文章",
            systemImage: "magnifyingglass",
            message: "输入关键词后，点击键盘上的搜索。"
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func searchFailureView(message: String) -> some View {
        AppScrollStateContainer {
            AppFailureState(
                title: "搜索失败",
                systemImage: "doc.text.magnifyingglass",
                message: message,
                underlyingError: viewModel.state.failureCause,
                onRetry: {
                    Task {
                        await viewModel.performSearch()
                    }
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
        AppFeedRow(isLast: index == viewModel.state.items.count - 1) {
            PaperSummaryCard(
                paper: paper,
                previewMetadata: viewModel.previewMetadata(for: paper.id),
                previewFailed: viewModel.previewFailedIDs.contains(paper.id),
                onOpen: {
                    selectedPaper = paper
                }
            )
        }
        .task(id: viewModel.previewGeneration) {
            await viewModel.loadPreviewMetadata(for: paper)
        }
        .task(id: paperPaginationTaskId()) {
            await viewModel.loadMoreIfNeeded(currentPaper: paper)
        }
    }

    @ViewBuilder
    private var itemsList: some View {
        ForEach(Array(viewModel.state.items.enumerated()), id: \.element.id) { index, paper in
            paperRow(index: index, paper: paper)
        }

        CommunityPaginationFooter(
            isLoading: viewModel.state.isLoadingMore,
            errorMessage: viewModel.state.paginationError
        ) {
            await viewModel.loadMoreIfNeeded(currentPaper: viewModel.state.items.last)
        }
    }

    @ViewBuilder
    private var loadedResultsView: some View {
        if viewModel.state.items.isEmpty {
            AppScrollStateContainer {
                AppEmptyState(
                    title: "没有找到相关文章",
                    systemImage: "doc.text.magnifyingglass",
                    message: "换个关键词试试。"
                )
            }
        } else {
            itemsList
        }
    }

    @ViewBuilder
    private var statusResultsView: some View {
        switch viewModel.state.status {
        case .loading where viewModel.state.items.isEmpty:
            AppInlineLoadingState("正在搜索文章")
        case .failed(let message) where viewModel.state.items.isEmpty:
            searchFailureView(message: message)
        default:
            loadedResultsView
        }
    }

    @ViewBuilder
    private var resultsBody: some View {
        if isInitialSearchState {
            initialSearchPrompt
        } else {
            statusResultsView
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: AppDesignSystem.Spacing.none) {
                CommunityResultsContext(viewModel.displayedQueryDescription)
                resultsBody
            }
            .padding(.vertical, AppDesignSystem.Spacing.content)
        }
        .accessibilityIdentifier("interaction.PaperSearchScene.scroll")
        .background(AppDesignSystem.Palette.Background.grouped)
        .refreshable {
            interactionEvidence?("interaction.PaperSearchScene.refreshable", "refresh")

            await viewModel.enqueueSearch().value
        }
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            AppSearchBarContainer {
                AppOrderedSearchBar(
                    text: $viewModel.searchText,
                    order: $viewModel.selectedOrder,
                    selectedOrderTitle: viewModel.selectedOrder.title,
                    onSubmit: {
                        viewModel.enqueueSearch()
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
            guard newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            viewModel.reset()
        }
        .onChange(of: viewModel.selectedOrder) { oldValue, newValue in
            guard oldValue != newValue else { return }
            guard !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            viewModel.enqueueSearch()
        }
        .onDisappear { viewModel.cancelSearchOperations() }
        .communityReadRecovery(
            networkPath: dependencies.networkPath, isEnabled: selectedPaper == nil
        ) {
            if viewModel.needsRefresh {
                await viewModel.refresh()
            } else if viewModel.state.paginationError != nil {
                await viewModel.loadMoreIfNeeded(currentPaper: viewModel.state.items.last)
            }
            viewModel.retryFailedPreviews()
        }
        .task {
            if viewModel.state.status == .idle, !viewModel.searchText.isEmpty {
                await viewModel.performSearch()
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedPaper) { paper in
            PaperDetailView(dependencies: dependencies, media: media, initialPaper: paper) {
                viewModel.enqueueSearch()
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
                .accessibilityIdentifier("ui.paper-search-scene.cancel")
            }
        }
        .diagnosticAlert(item: $viewModel.alert)
    }

}

#endif
