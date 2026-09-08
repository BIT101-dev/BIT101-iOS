//
//  PaperViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-01.
//

import Combine
import Foundation

private func normalizedPaperSearchText(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private extension PaperListState {
    /// 首屏请求开始前统一重置分页状态。
    mutating func prepareForRefresh() {
        status = .loading
        resetPagination()
    }
}

@MainActor
/// 文章列表状态机。
final class PaperListViewModel: ObservableObject {
    @Published private(set) var state = PaperListState()
    @Published private(set) var previewMetadataByPaperID: [Int: PaperPreviewMetadata] = [:]
    @Published var selectedOrder: PaperSortOrder = .newest
    @Published var searchText = ""
    @Published var alert: AppAlert?

    private let service: any PaperListServicing
    private var hasBootstrapped = false
    private var previewLoadingIDs: Set<Int> = []
    private var refreshGeneration = 0

    init(service: (any PaperListServicing)? = nil) {
        self.service = service ?? PaperService()
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refresh()
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let previousState = state
        state.prepareForRefresh()

        do {
            let papers = try await service.fetchPapers(
                search: trimmedSearchText,
                order: selectedOrder,
                page: 0
            )
            guard refreshGeneration == generation else { return }
            state.applyFirstPage(papers)
            state.status = .loaded
        } catch {
            guard refreshGeneration == generation else { return }
            if TaskCancellation.matches(error) {
                state = previousState
                return
            }
            state.status = .failed(error.localizedDescription)
            alert = AppAlert(title: "加载文章失败", message: error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(currentPaper: PaperSummary?) async {
        guard let currentPaper else { return }
        let generation = refreshGeneration
        guard state.status == .loaded, state.shouldLoadMore(currentID: currentPaper.id) else { return }

        state.isLoadingMore = true
        defer { state.isLoadingMore = false }

        do {
            let papers = try await service.fetchPapers(
                search: trimmedSearchText,
                order: selectedOrder,
                page: state.nextPage
            )
            guard refreshGeneration == generation else { return }
            state.appendPage(papers)
        } catch {
            guard refreshGeneration == generation else { return }
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 文章作者信息由详情接口提供；文章行展示前请求详情，并将成功返回的作者预览信息缓存在内存中。
    func loadPreviewMetadataIfNeeded(for paper: PaperSummary) async {
        guard previewMetadataByPaperID[paper.id] == nil else { return }
        guard !previewLoadingIDs.contains(paper.id) else { return }

        previewLoadingIDs.insert(paper.id)
        defer { previewLoadingIDs.remove(paper.id) }

        do {
            let detail = try await service.fetchPaper(id: paper.id)
            previewMetadataByPaperID[paper.id] = detail.previewMetadata
        } catch {
            return
        }
    }

    func previewMetadata(for paperID: Int) -> PaperPreviewMetadata? {
        previewMetadataByPaperID[paperID]
    }

    private var trimmedSearchText: String? {
        normalizedPaperSearchText(searchText)
    }
}

@MainActor
/// 文章搜索状态机。
///
/// 搜索页维护独立的文章列表状态，主列表保留首页当前列表。
final class PaperSearchViewModel: ObservableObject {
    @Published private(set) var state = PaperListState()
    @Published private(set) var previewMetadataByPaperID: [Int: PaperPreviewMetadata] = [:]
    @Published var selectedOrder: PaperSortOrder = .newest
    @Published var searchText = ""
    @Published var alert: AppAlert?

    private let service: any PaperListServicing
    private var previewLoadingIDs: Set<Int> = []
    private var searchGeneration = 0

    init(service: (any PaperListServicing)? = nil) {
        self.service = service ?? PaperService()
    }

    func performSearch() async {
        searchGeneration &+= 1
        let generation = searchGeneration
        guard let trimmedSearchText else {
            reset()
            return
        }

        let previousState = state
        state.prepareForRefresh()

        do {
            let papers = try await service.fetchPapers(
                search: trimmedSearchText,
                order: selectedOrder,
                page: 0
            )
            guard searchGeneration == generation else { return }
            state.applyFirstPage(papers)
            state.status = .loaded
        } catch {
            guard searchGeneration == generation else { return }
            if TaskCancellation.matches(error) {
                state = previousState
                return
            }
            state.status = .failed(error.localizedDescription)
            alert = AppAlert(title: "搜索文章失败", message: error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(currentPaper: PaperSummary?) async {
        guard let currentPaper, let trimmedSearchText else { return }
        let generation = searchGeneration
        guard state.status == .loaded, state.shouldLoadMore(currentID: currentPaper.id) else { return }

        state.isLoadingMore = true
        defer { state.isLoadingMore = false }

        do {
            let papers = try await service.fetchPapers(
                search: trimmedSearchText,
                order: selectedOrder,
                page: state.nextPage
            )
            guard searchGeneration == generation else { return }
            state.appendPage(papers)
        } catch {
            guard searchGeneration == generation else { return }
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 搜索结果页按需请求文章详情，并缓存作者预览元数据。
    func loadPreviewMetadataIfNeeded(for paper: PaperSummary) async {
        guard previewMetadataByPaperID[paper.id] == nil else { return }
        guard !previewLoadingIDs.contains(paper.id) else { return }

        previewLoadingIDs.insert(paper.id)
        defer { previewLoadingIDs.remove(paper.id) }

        do {
            let detail = try await service.fetchPaper(id: paper.id)
            previewMetadataByPaperID[paper.id] = detail.previewMetadata
        } catch {
            return
        }
    }

    func previewMetadata(for paperID: Int) -> PaperPreviewMetadata? {
        previewMetadataByPaperID[paperID]
    }

    func reset() {
        searchGeneration &+= 1
        state = PaperListState()
    }

    private var trimmedSearchText: String? {
        normalizedPaperSearchText(searchText)
    }
}

@MainActor
/// 文章详情状态机。
final class PaperDetailViewModel: ObservableObject {
    @Published private(set) var paper: PaperDetail?
    @Published private(set) var contentBlocks: [PaperContentBlock] = []
    @Published private(set) var paperStatus: GalleryFeedStatus = .idle
    @Published private(set) var commentState = GalleryCommentState()
    @Published var commentOrder: GalleryCommentOrder = .newest
    @Published private(set) var isLikingPaper = false
    @Published private(set) var likingCommentIDs: Set<Int> = []
    @Published private(set) var isSubmittingComment = false
    @Published var alert: AppAlert?

    let initialPaper: PaperSummary

    private let service: any PaperDetailServicing
    private var hasBootstrapped = false
    private var refreshGeneration = 0

    init(initialPaper: PaperSummary, service: (any PaperDetailServicing)? = nil) {
        self.initialPaper = initialPaper
        self.service = service ?? PaperService()
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refreshAll()
    }

    func refreshAll() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let previousPaperStatus = paperStatus
        let previousCommentState = commentState
        paperStatus = .loading
        resetCommentStateForRefresh()

        async let paperResult = loadResult { [self] in
            try await self.service.fetchPaper(id: self.initialPaper.id)
        }
        async let commentResult = loadResult { [self, commentOrder] in
            try await self.service.fetchComments(paperID: self.initialPaper.id, order: commentOrder, page: nil)
        }

        let resolvedPaperResult = await paperResult
        guard refreshGeneration == generation else { return }
        handlePaperResult(resolvedPaperResult, previousStatus: previousPaperStatus)

        let resolvedCommentResult = await commentResult
        guard refreshGeneration == generation else { return }
        handleCommentRefreshResult(resolvedCommentResult, previousState: previousCommentState)
    }

    func refreshComments() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let previousState = commentState
        resetCommentStateForRefresh()
        let result = await loadResult { [self] in
            try await self.service.fetchComments(paperID: self.initialPaper.id, order: self.commentOrder, page: nil)
        }
        guard refreshGeneration == generation else { return }
        handleCommentRefreshResult(result, previousState: previousState)
    }

    func loadMoreCommentsIfNeeded(currentComment: GalleryComment?) async {
        guard let currentComment else { return }
        let generation = refreshGeneration
        guard commentState.status == .loaded,
              commentState.shouldLoadMore(currentID: currentComment.id)
        else { return }

        commentState.isLoadingMore = true
        defer { commentState.isLoadingMore = false }

        let result = await loadResult { [self] in
            try await self.service.fetchComments(
                paperID: self.initialPaper.id,
                order: self.commentOrder,
                page: self.commentState.nextPage
            )
        }

        switch result {
        case let .success(comments):
            guard refreshGeneration == generation else { return }
            commentState.appendPage(comments)
        case let .failure(error):
            guard refreshGeneration == generation else { return }
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 切换评论排序时刷新评论区，文章正文保持当前内容。
    func setCommentOrder(_ order: GalleryCommentOrder) async {
        guard commentOrder != order else { return }
        commentOrder = order
        await refreshComments()
    }

    func likePaper() async {
        guard !isLikingPaper else { return }
        isLikingPaper = true
        defer { isLikingPaper = false }

        do {
            let result = try await service.likePaper(id: initialPaper.id)
            if let paper {
                self.paper = paper.updatingLike(result.like, likeNum: result.likeNum)
            }
        } catch {
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    func toggleCommentLike(_ comment: GalleryComment) async {
        guard !likingCommentIDs.contains(comment.id) else { return }
        likingCommentIDs.insert(comment.id)
        defer { likingCommentIDs.remove(comment.id) }

        do {
            let result = try await service.sendLike(objectID: "comment\(comment.id)")
            commentState.items = commentState.items.updatingLike(for: comment.id, like: result.like, likeNum: result.likeNum)
        } catch {
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    func submitComment(text: String, anonymous: Bool, target: PaperCommentComposerTarget) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alert = AppAlert(title: "发送失败", message: "评论不能为空。")
            return false
        }
        guard !isSubmittingComment else { return false }

        isSubmittingComment = true
        defer { isSubmittingComment = false }

        do {
            _ = try await service.createComment(
                objectID: target.objectID,
                text: trimmed,
                replyObjectID: target.replyObjectID,
                replyUID: target.replyUID,
                anonymous: anonymous
            )
            await refreshAll()
            return true
        } catch {
            if TaskCancellation.matches(error) { return false }
            alert = AppAlert(title: "发送失败", message: error.localizedDescription)
            return false
        }
    }

    private func handlePaperResult(_ result: Result<PaperDetail, Error>, previousStatus: GalleryFeedStatus) {
        switch result {
        case let .success(paper):
            self.paper = paper
            contentBlocks = PaperContentRenderer.blocks(from: paper.content)
            paperStatus = .loaded
        case let .failure(error):
            if TaskCancellation.matches(error) {
                paperStatus = paper == nil ? previousStatus : .loaded
                return
            }
            paperStatus = .failed(error.localizedDescription)
            alert = AppAlert(title: "加载文章失败", message: error.localizedDescription)
        }
    }

    private func handleCommentRefreshResult(
        _ result: Result<[GalleryComment], Error>,
        previousState: GalleryCommentState
    ) {
        switch result {
        case let .success(comments):
            commentState.applyFirstPage(comments)
            commentState.status = .loaded
        case let .failure(error):
            if TaskCancellation.matches(error) {
                commentState = previousState
                return
            }
            commentState.status = .failed(error.localizedDescription)
            commentState.canLoadMore = false
            commentState.isLoadingMore = false
            alert = AppAlert(title: "加载评论失败", message: error.localizedDescription)
        }
    }

    private func resetCommentStateForRefresh() {
        commentState.status = .loading
        commentState.resetPagination()
    }

    private func loadResult<T>(_ operation: @escaping () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }
}

private extension Array where Element == GalleryComment {
    func updatingLike(for commentID: Int, like: Bool, likeNum: Int) -> [GalleryComment] {
        map { comment in
            let updatedSub = comment.sub.updatingLike(for: commentID, like: like, likeNum: likeNum)
            let updated = comment.replacingSubComments(updatedSub)
            if updated.id == commentID {
                return updated.updatingLike(like, likeNum: likeNum)
            }
            return updated
        }
    }
}
