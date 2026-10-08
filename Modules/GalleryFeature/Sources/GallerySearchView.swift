#if os(iOS)
import CommunityUI
import MediaKit
import DesignSystemKit
//
//  GallerySearchView.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

import SwiftUI

struct GallerySearchView: View {
    @ObservedObject var viewModel: GalleryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(MediaEnvironment.self) private var media

    private func triggerSearch() {
        viewModel.enqueueSearch()
    }

    var body: some View {
        GalleryFeedView(
            feedState: viewModel.searchState,
            feedIdentity: "search",
            prefetchTriggerThreshold: 0,
            onRefresh: triggerSearch,
            onPullToRefresh: {
                media.retryFailedImages()
                await viewModel.enqueueSearch().value
            },
            onPrefetch: { _ in },
            onLoadMore: { poster in
                guard let poster else { return }
                viewModel.enqueueSearchLoadMore(currentPoster: poster)
            }
        )
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
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
                    ForEach(GallerySearchOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
            }
        }
        .task {
            await viewModel.bootstrapSearchIfNeeded()
        }
        .onChange(of: viewModel.searchQuery.order) { _, _ in
            triggerSearch()
        }
        .onDisappear { viewModel.cancelSearchOperations() }
        .navigationTitle("搜索")
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
