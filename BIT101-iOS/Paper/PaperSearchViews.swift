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
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var selectedPaper: PaperSummary?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PaperEmptyState(
                        systemImage: "magnifyingglass",
                        title: "搜索文章",
                        message: "输入关键词后再搜索文章。"
                    )
                    .padding(.top, 48)
                } else {
                    switch viewModel.state.status {
                    case .idle where viewModel.state.items.isEmpty,
                         .loading where viewModel.state.items.isEmpty:
                        ProgressView("正在搜索文章")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    case let .failed(message) where viewModel.state.items.isEmpty:
                        PaperEmptyState(
                            systemImage: "doc.text.magnifyingglass",
                            title: "搜索失败",
                            message: message,
                            onRetry: {
                                Task {
                                    await viewModel.performSearch()
                                }
                            }
                        )
                        .padding(.top, 48)
                    default:
                        if visiblePapers.isEmpty {
                            PaperEmptyState(
                                systemImage: "doc.text.magnifyingglass",
                                title: "没有找到相关文章",
                                message: "换个关键词试试。"
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
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await viewModel.performSearch()
        }
        .safeAreaInset(edge: .top) {
            PaperSearchBar(
                searchText: $viewModel.searchText,
                selectedOrder: $viewModel.selectedOrder,
                onSubmit: {
                    Task {
                        await viewModel.performSearch()
                    }
                },
                onClear: {
                    viewModel.searchText = ""
                    viewModel.reset()
                }
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.thinMaterial)
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

    private func paginationProbePaper(currentPaper: PaperSummary) -> PaperSummary {
        guard currentPaper.id == visiblePapers.last?.id else { return currentPaper }
        return viewModel.state.items.last ?? currentPaper
    }
}

/// 文章搜索栏。
///
/// 这里直接对齐话廊搜索栏的结构：左侧排序菜单，中间搜索输入，右侧清空按钮。
/// 这样文章与话廊两个内容模块的搜索入口会更统一。
private struct PaperSearchBar: View {
    @Binding var searchText: String
    @Binding var selectedOrder: PaperSortOrder
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker(
                selection: Binding(
                    get: { selectedOrder },
                    set: { newValue in
                        selectedOrder = newValue
                        onSubmit()
                    }
                )
            ) {
                ForEach(PaperSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            } label: {
                Label(selectedOrder.title, systemImage: "arrow.up.arrow.down.circle")
            }
            .pickerStyle(.menu)

            TextField("在这里搜索哦", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)

            Button {
                searchText = ""
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(searchText.isEmpty ? Color.secondary.opacity(0.35) : Color.orange)
            }
            .buttonStyle(.plain)
            .disabled(searchText.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 文章摘要行。
///
/// 视觉上和话廊信息流对齐：使用整行白底，而不是独立圆角卡片。
/// 这样文章、话题两个内容流在同一层级切换时不会显得割裂。
