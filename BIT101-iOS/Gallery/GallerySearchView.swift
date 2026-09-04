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

    var body: some View {
        GalleryFeedView(
            feedState: viewModel.searchState,
            feedIdentity: "search",
            prefetchTriggerThreshold: 0,
            onRefresh: {
                Task {
                    await viewModel.performSearch()
                }
            },
            onPrefetch: { _ in },
            onLoadMore: { poster in
                Task {
                    await viewModel.loadMoreSearchResultsIfNeeded(currentPoster: poster)
                }
            }
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            AppSearchBarContainer {
                AppOrderedSearchBar(
                    text: $viewModel.searchQuery.text,
                    order: $viewModel.searchQuery.order,
                    selectedOrderTitle: viewModel.searchQuery.order.title,
                    onSubmit: {
                        Task {
                            await viewModel.performSearch()
                        }
                    },
                    onClear: {
                        viewModel.searchQuery.text = ""
                        Task {
                            await viewModel.performSearch()
                        }
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
        .onChange(of: viewModel.searchQuery.order) { oldValue, newValue in
            guard oldValue != newValue else { return }
            Task {
                await viewModel.performSearch()
            }
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
