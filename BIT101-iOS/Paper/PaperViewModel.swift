//
//  PaperViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-01.
//

import Combine
import Foundation

/// 判断文章模块请求是否只是任务取消。
private func isPaperRequestCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
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

    init(service: (any PaperListServicing)? = nil) {
        self.service = service ?? PaperService()
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refresh()
    }

    func refresh() async {
        state.prepareForRefresh()

        do {
            let papers = try await service.fetchPapers(
                search: trimmedSearchText,
                order: selectedOrder,
                page: 0
            )
            state.applyFirstPage(papers)
            state.status = .loaded
        } catch {
            if isPaperRequestCancellation(error) { return }
            state.status = .failed(error.localizedDescription)
            alert = AppAlert(title: "加载文章失败", message: error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(currentPaper: PaperSummary?) async {
        guard let currentPaper else { return }
        guard state.status == .loaded, state.shouldLoadMore(currentID: currentPaper.id) else { return }

        state.isLoadingMore = true
        defer { state.isLoadingMore = false }

        do {
            let papers = try await service.fetchPapers(
                search: trimmedSearchText,
                order: selectedOrder,
                page: state.nextPage
            )
            state.appendPage(papers)
        } catch {
            if isPaperRequestCancellation(error) { return }
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 为文章列表按需补拉作者预览信息。
    ///
    /// 文章列表接口缺少作者字段，因此只在行即将显示时请求一次详情，并把作者信息缓存在内存里。
    func loadPreviewMetadataIfNeeded(for paper: PaperSummary) async {
        guard previewMetadataByPaperID[paper.id] == nil else { return }
        guard !previewLoadingIDs.contains(paper.id) else { return }

        previewLoadingIDs.insert(paper.id)
        defer { previewLoadingIDs.remove(paper.id) }

        do {
            let detail = try await service.fetchPaper(id: paper.id)
            previewMetadataByPaperID[paper.id] = detail.previewMetadata
        } catch {
            if isPaperRequestCancellation(error) { return }
        }
    }

    func previewMetadata(for paperID: Int) -> PaperPreviewMetadata? {
        previewMetadataByPaperID[paperID]
    }

    private var trimmedSearchText: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
/// 文章搜索状态机。
///
/// 搜索页不复用主列表状态，避免“在搜索页里搜索”直接污染文章首页当前正在看的列表。
final class PaperSearchViewModel: ObservableObject {
    @Published private(set) var state = PaperListState()
    @Published private(set) var previewMetadataByPaperID: [Int: PaperPreviewMetadata] = [:]
    @Published var selectedOrder: PaperSortOrder = .newest
    @Published var searchText = ""
    @Published var alert: AppAlert?

    private let service: any PaperListServicing
    private var previewLoadingIDs: Set<Int> = []

    init(service: (any PaperListServicing)? = nil) {
        self.service = service ?? PaperService()
    }

    func performSearch() async {
        guard let trimmedSearchText else {
            reset()
            return
        }

        state.prepareForRefresh()

        do {
            let papers = try await service.fetchPapers(
                search: trimmedSearchText,
                order: selectedOrder,
                page: 0
            )
            state.applyFirstPage(papers)
            state.status = .loaded
        } catch {
            if isPaperRequestCancellation(error) { return }
            state.status = .failed(error.localizedDescription)
            alert = AppAlert(title: "搜索文章失败", message: error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(currentPaper: PaperSummary?) async {
        guard let currentPaper, let trimmedSearchText else { return }
        guard state.status == .loaded, state.shouldLoadMore(currentID: currentPaper.id) else { return }

        state.isLoadingMore = true
        defer { state.isLoadingMore = false }

        do {
            let papers = try await service.fetchPapers(
                search: trimmedSearchText,
                order: selectedOrder,
                page: state.nextPage
            )
            state.appendPage(papers)
        } catch {
            if isPaperRequestCancellation(error) { return }
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 搜索结果页和文章首页一样，按需补拉作者预览元数据。
    func loadPreviewMetadataIfNeeded(for paper: PaperSummary) async {
        guard previewMetadataByPaperID[paper.id] == nil else { return }
        guard !previewLoadingIDs.contains(paper.id) else { return }

        previewLoadingIDs.insert(paper.id)
        defer { previewLoadingIDs.remove(paper.id) }

        do {
            let detail = try await service.fetchPaper(id: paper.id)
            previewMetadataByPaperID[paper.id] = detail.previewMetadata
        } catch {
            if isPaperRequestCancellation(error) { return }
        }
    }

    func previewMetadata(for paperID: Int) -> PaperPreviewMetadata? {
        previewMetadataByPaperID[paperID]
    }

    func reset() {
        state = PaperListState()
    }

    private var trimmedSearchText: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        paperStatus = .loading
        resetCommentStateForRefresh()

        async let paperResult = loadResult { [self] in
            try await self.service.fetchPaper(id: self.initialPaper.id)
        }
        async let commentResult = loadResult { [self, commentOrder] in
            try await self.service.fetchComments(paperID: self.initialPaper.id, order: commentOrder, page: nil)
        }

        handlePaperResult(await paperResult)
        handleCommentRefreshResult(await commentResult)
    }

    func refreshComments() async {
        resetCommentStateForRefresh()
        let result = await loadResult { [self] in
            try await self.service.fetchComments(paperID: self.initialPaper.id, order: self.commentOrder, page: nil)
        }
        handleCommentRefreshResult(result)
    }

    func loadMoreCommentsIfNeeded(currentComment: GalleryComment?) async {
        guard let currentComment else { return }
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
            commentState.appendPage(comments)
        case let .failure(error):
            if isPaperRequestCancellation(error) { return }
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 切换评论排序时只刷新评论区，避免整篇文章正文跟着闪动。
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
            if isPaperRequestCancellation(error) { return }
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
            if isPaperRequestCancellation(error) { return }
            alert = AppAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    func submitComment(text: String, anonymous: Bool, target: PaperCommentComposerTarget) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alert = AppAlert(title: "发送失败", message: "评论不能为空。")
            return false
        }
        if let message = CommunityModeration.validateCommentDraft(text: trimmed) {
            alert = AppAlert(title: "内容不合规", message: message)
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
            if isPaperRequestCancellation(error) { return false }
            alert = AppAlert(title: "发送失败", message: error.localizedDescription)
            return false
        }
    }

    private func handlePaperResult(_ result: Result<PaperDetail, Error>) {
        switch result {
        case let .success(paper):
            self.paper = paper
            contentBlocks = PaperContentRenderer.blocks(from: paper.content)
            paperStatus = .loaded
        case let .failure(error):
            if isPaperRequestCancellation(error) {
                paperStatus = .loaded
                return
            }
            paperStatus = .failed(error.localizedDescription)
            alert = AppAlert(title: "加载文章失败", message: error.localizedDescription)
        }
    }

    private func handleCommentRefreshResult(_ result: Result<[GalleryComment], Error>) {
        switch result {
        case let .success(comments):
            commentState.items = comments
            commentState.status = .loaded
            commentState.nextPage = 1
            commentState.canLoadMore = !comments.isEmpty
            commentState.isLoadingMore = false
        case let .failure(error):
            if isPaperRequestCancellation(error) {
                commentState.status = .idle
                commentState.isLoadingMore = false
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
