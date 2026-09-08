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

    private func triggerSearch() {
        Task {
            await viewModel.performSearch()
        }
    }

    var body: some View {
        GalleryFeedView(
            feedState: viewModel.searchState,
            feedIdentity: "search",
            prefetchTriggerThreshold: 0,
            onRefresh: triggerSearch,
            onPrefetch: { _ in },
            onLoadMore: { poster in
                Task {
                    await viewModel.loadMoreSearchResultsIfNeeded(currentPoster: poster)
                }
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
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
        }
    }
}
