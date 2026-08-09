//
//  GallerySearchView.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

import SwiftUI

struct GallerySearchView: View {
    @ObservedObject var viewModel: GalleryViewModel
    @ObservedObject private var settings = AppSettingsStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GalleryFeedView(
            feedState: filteredSearchState,
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
        .safeAreaInset(edge: .top) {
            GallerySearchBar(
                query: $viewModel.searchQuery,
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
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.thinMaterial)
        }
        .task {
            await viewModel.bootstrapSearchIfNeeded()
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

    private var filteredSearchState: GalleryFeedState {
        var state = viewModel.searchState
        state.posters = CommunityModeration.filterVisiblePosters(state.posters, snapshot: settings.snapshot)
        return state
    }
}

/// 原生消息页。
///
/// Android 虽然最终落到网页，但后端已经提供独立消息接口，因此 iOS 直接走 native list。
private struct GallerySearchBar: View {
    @Binding var query: GallerySearchQuery
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker(
                selection: Binding(
                    get: { query.order },
                    set: { newValue in
                        query.order = newValue
                        onSubmit()
                    }
                )
            ) {
                ForEach(GallerySearchOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            } label: {
                Label(query.order.title, systemImage: "arrow.up.arrow.down.circle")
            }
            .pickerStyle(.menu)

            TextField("在这里搜索哦", text: $query.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)

            Button {
                query.text = ""
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(query.text.isEmpty ? Color.secondary.opacity(0.35) : Color.orange)
            }
            .buttonStyle(.plain)
            .disabled(query.text.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
