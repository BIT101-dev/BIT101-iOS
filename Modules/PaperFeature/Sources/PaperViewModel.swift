import TransportCore
import DesignSystemKit
import CommunityCore
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
    private var pageQuery: (search: String?, order: PaperSortOrder)?
    private var previewLoadingIDs: Set<Int> = []
    @Published private(set) var refreshGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshPreviousState: (state: PaperListState, metadata: [Int: PaperPreviewMetadata])?

    init(service: any PaperListServicing) {
        self.service = service
    }

    deinit { refreshTask?.cancel() }

    func cancelRefreshOperations() {
        refreshTask?.cancel(); refreshTask = nil
        refreshGeneration &+= 1
        if let refreshPreviousState {
            state = refreshPreviousState.state
            previewMetadataByPaperID = refreshPreviousState.metadata
        }
        refreshPreviousState = nil
        if state.status == .loading { state.status = state.items.isEmpty ? .idle : .loaded }
        state.isLoadingMore = false
    }

    @discardableResult
    func enqueueRefresh() -> Task<Void, Never> {
        cancelRefreshOperations()
        let generation = refreshGeneration
        let task = Task { [weak self] in
            guard let self, self.refreshGeneration == generation, !Task.isCancelled else { return }
            await self.performRefresh()
            if self.refreshGeneration == generation { self.refreshTask = nil }
        }
        refreshTask = task
        return task
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refresh()
        if state.status == .idle { hasBootstrapped = false }
    }

    func refresh() async {
        let task = enqueueRefresh()
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private func performRefresh() async {
        let generation = refreshGeneration
        let query = (search: trimmedSearchText, order: selectedOrder)
        let previousState = state
        let previousMetadata = previewMetadataByPaperID
        refreshPreviousState = (previousState, previousMetadata)
        previewMetadataByPaperID = [:]
        previewLoadingIDs = []
        defer { if refreshGeneration == generation { refreshPreviousState = nil } }
        if state.items.isEmpty {
            state.prepareForRefresh()
        } else {
            state.status = .loading
            state.nextPage = 0
            state.isLoadingMore = false
            state.canLoadMore = true
        }

        do {
            let papers = try await service.fetchPapers(
                search: query.search,
                order: query.order,
                page: 0
            )
            try Task.checkCancellation()
            guard refreshGeneration == generation else { return }
            state.applyFirstPage(papers)
            pageQuery = query
            state.status = .loaded
        } catch {
            guard refreshGeneration == generation else { return }
            if TaskCancellation.matches(error) {
                var restoredState = previousState
                restoredState.isLoadingMore = false
                if !restoredState.items.isEmpty {
                    restoredState.status = .loaded
                } else if case .loading = restoredState.status {
                    restoredState.status = .idle
                }
                state = restoredState
                previewMetadataByPaperID = previousMetadata
                return
            }
            if previousState.items.isEmpty {
                state.status = .failed(error.localizedDescription)
                state.canLoadMore = false
                alert = AppAlert(title: "加载文章失败", message: error.localizedDescription)
            } else {
                state = previousState
                previewMetadataByPaperID = previousMetadata
                state.status = .loaded
                state.isLoadingMore = false
                alert = AppAlert(title: "刷新文章失败", message: error.localizedDescription)
            }
        }
    }

    func loadMoreIfNeeded(currentPaper: PaperSummary?) async {
        guard let currentPaper, let query = pageQuery else { return }
        let generation = refreshGeneration
        guard state.status == .loaded, state.shouldLoadMore(currentID: currentPaper.id) else { return }

        state.isLoadingMore = true
        defer {
            if refreshGeneration == generation {
                state.isLoadingMore = false
            }
        }

        do {
            let previousCount = state.items.count
            var progress = CommunityPageProgress(knownIDs: state.items.map(\.id))
            repeat {
                try Task.checkCancellation()
                state.isLoadingMore = true
                let papers = try await service.fetchPapers(search: query.search, order: query.order, page: state.nextPage)
                try Task.checkCancellation()
                guard refreshGeneration == generation else { return }
                try progress.record(papers.map(\.id))
                state.appendPage(papers)
            } while state.canLoadMore && state.items.count == previousCount
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
        let generation = refreshGeneration
        previewLoadingIDs.insert(paper.id)
        defer { if refreshGeneration == generation { previewLoadingIDs.remove(paper.id) } }

        do {
            let detail = try await service.fetchPaper(id: paper.id)
            try Task.checkCancellation()
            guard refreshGeneration == generation else { return }
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
    private var pageQuery: (search: String, order: PaperSortOrder)?
    @Published private(set) var searchGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var searchPreviousState: (state: PaperListState, metadata: [Int: PaperPreviewMetadata])?

    init(service: any PaperListServicing) {
        self.service = service
    }

    deinit { searchTask?.cancel() }

    func cancelSearchOperations() {
        searchTask?.cancel(); searchTask = nil
        searchGeneration &+= 1
        if let searchPreviousState {
            state = searchPreviousState.state
            previewMetadataByPaperID = searchPreviousState.metadata
        }
        searchPreviousState = nil
        if state.status == .loading { state.status = state.items.isEmpty ? .idle : .loaded }
        state.isLoadingMore = false
    }

    @discardableResult
    func enqueueSearch() -> Task<Void, Never> {
        cancelSearchOperations()
        let generation = searchGeneration
        let task = Task { [weak self] in
            guard let self, self.searchGeneration == generation, !Task.isCancelled else { return }
            await self.executeSearch()
            if self.searchGeneration == generation { self.searchTask = nil }
        }
        searchTask = task
        return task
    }

    func performSearch() async {
        let task = enqueueSearch()
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private func executeSearch() async {
        let generation = searchGeneration
        guard let trimmedSearchText else {
            reset()
            return
        }
        let query = (search: trimmedSearchText, order: selectedOrder)

        let previousState = state
        let previousMetadata = previewMetadataByPaperID
        searchPreviousState = (previousState, previousMetadata)
        previewMetadataByPaperID = [:]
        previewLoadingIDs = []
        defer { if searchGeneration == generation { searchPreviousState = nil } }
        state.prepareForRefresh()

        do {
            let papers = try await service.fetchPapers(
                search: query.search,
                order: query.order,
                page: 0
            )
            try Task.checkCancellation()
            guard searchGeneration == generation else { return }
            state.applyFirstPage(papers)
            pageQuery = query
            state.status = .loaded
        } catch {
            guard searchGeneration == generation else { return }
            if TaskCancellation.matches(error) {
                var restoredState = previousState
                restoredState.isLoadingMore = false
                if !restoredState.items.isEmpty {
                    restoredState.status = .loaded
                } else if case .loading = restoredState.status {
                    restoredState.status = .idle
                }
                state = restoredState
                previewMetadataByPaperID = previousMetadata
                return
            }
            state = previousState
            previewMetadataByPaperID = previousMetadata
            state.status = previousState.items.isEmpty ? .failed(error.localizedDescription) : .loaded
            state.isLoadingMore = false
            alert = AppAlert(title: "搜索文章失败", message: error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(currentPaper: PaperSummary?) async {
        guard let currentPaper, let query = pageQuery else { return }
        let generation = searchGeneration
        guard state.status == .loaded, state.shouldLoadMore(currentID: currentPaper.id) else { return }

        state.isLoadingMore = true
        defer {
            if searchGeneration == generation {
                state.isLoadingMore = false
            }
        }

        do {
            let previousCount = state.items.count
            var progress = CommunityPageProgress(knownIDs: state.items.map(\.id))
            repeat {
                try Task.checkCancellation()
                state.isLoadingMore = true
                let papers = try await service.fetchPapers(search: query.search, order: query.order, page: state.nextPage)
                try Task.checkCancellation()
                guard searchGeneration == generation else { return }
                try progress.record(papers.map(\.id))
                state.appendPage(papers)
            } while state.canLoadMore && state.items.count == previousCount
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

        let generation = searchGeneration
        previewLoadingIDs.insert(paper.id)
        defer { if searchGeneration == generation { previewLoadingIDs.remove(paper.id) } }

        do {
            let detail = try await service.fetchPaper(id: paper.id)
            try Task.checkCancellation()
            guard searchGeneration == generation else { return }
            previewMetadataByPaperID[paper.id] = detail.previewMetadata
        } catch {
            return
        }
    }

    func previewMetadata(for paperID: Int) -> PaperPreviewMetadata? {
        previewMetadataByPaperID[paperID]
    }

    func reset() {
        cancelSearchOperations()
        previewMetadataByPaperID = [:]
        previewLoadingIDs = []
        state = PaperListState()
        pageQuery = nil
    }

    private var trimmedSearchText: String? {
        normalizedPaperSearchText(searchText)
    }
}

#if os(iOS)
@MainActor
/// 文章详情状态机。
final class PaperDetailViewModel: ObservableObject {
    @Published private(set) var paper: PaperDetail?
    @Published private(set) var contentBlocks: [PaperContentBlock] = []
    @Published private(set) var paperStatus: CommunityLoadStatus = .idle
    @Published private(set) var commentState = CommunityCommentState()
    @Published var commentOrder: CommunityCommentOrder = .newest
    @Published private(set) var isLikingPaper = false
    @Published private(set) var isDeletingPaper = false
    @Published private(set) var likingCommentIDs: Set<Int> = []
    @Published private(set) var isSubmittingComment = false
    @Published var alert: AppAlert?

    let initialPaper: PaperSummary

    private let service: any PaperDetailServicing
    private var hasBootstrapped = false
    private var likeRevision = 0
    @Published private var latestLikeResult: CommunityLikeResult?
    private var refreshGeneration = 0
    private var commentRefreshGeneration = 0

    init(initialPaper: PaperSummary, service: any PaperDetailServicing) {
        self.initialPaper = initialPaper
        self.service = service
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refreshAll()
        if paperStatus == .idle || commentState.status == .idle { hasBootstrapped = false }
    }

    func refreshAll() async {
        let likeRevisionAtStart = likeRevision
        refreshGeneration &+= 1
        commentRefreshGeneration &+= 1
        let generation = refreshGeneration
        let commentsGeneration = commentRefreshGeneration
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
        handlePaperResult(resolvedPaperResult, previousStatus: previousPaperStatus, likeRevisionAtStart: likeRevisionAtStart)

        let resolvedCommentResult = await commentResult
        guard commentRefreshGeneration == commentsGeneration else { return }
        handleCommentRefreshResult(resolvedCommentResult, previousState: previousCommentState)
    }

    func refreshComments() async {
        commentRefreshGeneration &+= 1
        let generation = commentRefreshGeneration
        let previousState = commentState
        resetCommentStateForRefresh()
        let result = await loadResult { [self] in
            try await self.service.fetchComments(paperID: self.initialPaper.id, order: self.commentOrder, page: nil)
        }
        guard commentRefreshGeneration == generation else { return }
        handleCommentRefreshResult(result, previousState: previousState)
    }

    func loadMoreCommentsIfNeeded(currentComment: CommunityComment?) async {
        guard let currentComment else { return }
        let generation = commentRefreshGeneration
        guard commentState.status == .loaded,
              commentState.shouldLoadMore(currentID: currentComment.id)
        else { return }

        let order = commentOrder
        let nextPage = commentState.nextPage
        let likeRevisionAtStart = commentState.likeRevision
        commentState.isLoadingMore = true
        defer {
            if commentRefreshGeneration == generation {
                commentState.isLoadingMore = false
            }
        }

        let result = await loadResult { [self] in
            try await self.service.fetchComments(
                paperID: self.initialPaper.id,
                order: order,
                page: nextPage
            )
        }

        switch result {
        case let .success(comments):
            guard commentRefreshGeneration == generation else { return }
            commentState.appendPage(commentState.applyingLikes(to: comments, since: likeRevisionAtStart))
        case let .failure(error):
            guard commentRefreshGeneration == generation else { return }
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 切换评论排序时刷新评论区，文章正文保持当前内容。
    func setCommentOrder(_ order: CommunityCommentOrder) async {
        guard commentOrder != order else { return }
        commentOrder = order
        await refreshComments()
    }

    var isPaperLiked: Bool { latestLikeResult?.like ?? paper?.like ?? false }
    var resolvedLikeNum: Int { latestLikeResult?.likeNum ?? paper?.likeNum ?? initialPaper.likeNum }

    func likePaper() async {
        guard !isLikingPaper else { return }
        isLikingPaper = true
        defer { isLikingPaper = false }

        do {
            let result = try await service.likePaper(id: initialPaper.id)
            try Task.checkCancellation()
            likeRevision &+= 1
            latestLikeResult = result
            if let paper {
                self.paper = paper.updatingLike(result.like, likeNum: result.likeNum)
            }
        } catch {
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    func deletePaper() async -> Bool {
        guard paper?.own == true, !isDeletingPaper else { return false }
        isDeletingPaper = true
        defer { isDeletingPaper = false }
        do {
            try Task.checkCancellation()
            try await service.deletePaper(id: initialPaper.id)
            try Task.checkCancellation()
            return true
        } catch {
            if TaskCancellation.matches(error) { return false }
            alert = AppAlert(title: "删除失败", message: error.localizedDescription)
            return false
        }
    }

    func toggleCommentLike(_ comment: CommunityComment) async {
        guard !likingCommentIDs.contains(comment.id) else { return }
        likingCommentIDs.insert(comment.id)
        defer { likingCommentIDs.remove(comment.id) }

        do {
            let result = try await service.sendLike(objectID: "comment\(comment.id)")
            try Task.checkCancellation()
            commentState.recordLike(result, for: comment.id)
        } catch {
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    func submitComment(text: String, anonymous: Bool, target: PaperCommentComposerTarget) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alert = AppAlert.userInput(title: "发送失败", message: "评论不能为空。")
            return false
        }
        guard !isSubmittingComment else { return false }

        isSubmittingComment = true
        defer { isSubmittingComment = false }

        do {
            try Task.checkCancellation()
            _ = try await service.createComment(
                objectID: target.objectID,
                text: trimmed,
                replyObjectID: target.replyObjectID,
                replyUID: target.replyUID,
                anonymous: anonymous
            )
            try Task.checkCancellation()
            await refreshAll()
            try Task.checkCancellation()
            return true
        } catch {
            if Task.isCancelled || TaskCancellation.matches(error) { return false }
            alert = AppAlert(title: "发送失败", message: error.localizedDescription)
            return false
        }
    }

    private func handlePaperResult(_ result: Result<PaperDetail, Error>, previousStatus: CommunityLoadStatus, likeRevisionAtStart: Int) {
        switch result {
        case let .success(paper):
            if likeRevision != likeRevisionAtStart, let latestLikeResult {
                self.paper = paper.updatingLike(latestLikeResult.like, likeNum: latestLikeResult.likeNum)
            } else {
                self.paper = paper
                latestLikeResult = nil
            }
            contentBlocks = PaperContentRenderer.blocks(from: paper.content)
            paperStatus = .loaded
        case let .failure(error):
            if TaskCancellation.matches(error) {
                if paper == nil {
                    paperStatus = previousStatus
                    if case .loading = previousStatus {
                        paperStatus = .idle
                    }
                } else {
                    paperStatus = .loaded
                }
                return
            }
            paperStatus = .failed(error.localizedDescription)
            alert = AppAlert(title: "加载文章失败", message: error.localizedDescription)
        }
    }

    private func handleCommentRefreshResult(
        _ result: Result<[CommunityComment], Error>,
        previousState: CommunityCommentState
    ) {
        switch result {
        case let .success(comments):
            commentState.applyFirstPage(commentState.applyingLikes(to: comments, since: previousState.likeRevision))
            commentState.order = commentOrder
            commentState.status = .loaded
        case let .failure(error):
            let cancelled = TaskCancellation.matches(error)
            commentState.restoreAfterRefreshFailure(previousState, failureStatus: cancelled ? nil : .failed(error.localizedDescription))
            if !commentState.items.isEmpty { commentOrder = commentState.order }
            if cancelled { return }
            alert = AppAlert(title: "加载评论失败", message: error.localizedDescription)
        }
    }

    private func resetCommentStateForRefresh() {
        commentState.status = .loading
        commentState.isLoadingMore = false
    }

    private func loadResult<T: Sendable>(_ operation: @MainActor () async throws -> T) async -> Result<T, Error> {
        do {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            return .success(value)
        } catch {
            return .failure(error)
        }
    }
}



#endif
