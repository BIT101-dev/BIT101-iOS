#if os(iOS)
import CommunityUI
import MediaKit
import DesignSystemKit
//
//  GallerySearchView.swift
//  BIT101-iOS
//
//

import SwiftUI

struct GalleryPublicationReviewView: View {
    @State private var viewModel: GalleryViewModel
    init(service: any GalleryFeedServicing, query: String) {
        let model = GalleryViewModel(service: service)
        model.searchQuery.text = query
        _viewModel = State(initialValue: model)
    }
    var body: some View { GallerySearchView(viewModel: viewModel) }
}

struct GallerySearchView: View {
    @Environment(GalleryDependencies.self) private var dependencies
    @Bindable var viewModel: GalleryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(MediaEnvironment.self) private var media

    private func triggerSearch() {
        viewModel.enqueueSearch()
    }

    @ViewBuilder
    private var orderMenuItems: some View {
        ForEach(GallerySearchOrder.allCases) { order in
            Text(order.title).tag(order)
        }
    }

    @ViewBuilder
    private var searchHeader: some View {
        VStack(spacing: AppDesignSystem.Spacing.none) {
            AppSearchBarContainer {
                AppOrderedSearchBar(
                    text: $viewModel.searchQuery.text,
                    order: $viewModel.searchQuery.order,
                    selectedOrderTitle: viewModel.searchQuery.order.title,
                    onSubmit: triggerSearch,
                    onClear: {
                        viewModel.searchQuery.text = ""
                        triggerSearch()
                    }
                ) {
                    orderMenuItems
                }
            }
            CommunityResultsContext(viewModel.displayedQueryDescription)
        }
    }

    var body: some View {
        GalleryFeedView(
            feedState: viewModel.searchState,
            feedIdentity: "search",
            prefetchTriggerThreshold: 0,
            onRefresh: triggerSearch,
            onPullToRefresh: {
                media.retryFailedImages()
                await viewModel.search()
            },
            onPrefetch: { _ in },
            onLoadMore: { poster in
                viewModel.enqueueSearchLoadMore(currentPoster: poster)
            }
        )
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            searchHeader
        }
        .task {
            await viewModel.bootstrapSearchIfNeeded()
        }
        .communityReadRecovery(networkPath: dependencies.networkPath) {
            if viewModel.searchState.needsRefresh {
                await viewModel.search()
            } else if viewModel.searchState.paginationError != nil {
                await viewModel.loadMoreSearch(
                    currentPoster: viewModel.searchState.posters.last)
            }
        }
        .onChange(of: viewModel.searchQuery.order) { _, _ in
            triggerSearch()
        }
        .onDisappear { viewModel.cancelSearchOperations() }
        .navigationTitle("搜索")
        .appWindowLayout()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
                .accessibilityIdentifier("ui.gallery-search-view.cancel")
            }
        }
    }
}

#endif
