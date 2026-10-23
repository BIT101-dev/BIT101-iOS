import CommunityUI
import TransportCore
import DesignSystemKit
import CommunityCore
import CommunityTransport
import Combine
import Foundation

private func normalizedPaperSearchText(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private extension PaperListState {
    /// 首屏请求开始前统一重置分页状态。
    mutating func prepareForRefresh() {
        paginationError = nil
        status = .loading
        resetPagination()
    }
}

@MainActor
/// 文章集合统一维护刷新、分页、取消恢复与预览元数据。
class PaperCollectionViewModel: ObservableObject {
    @Published private(set) var state = PaperListState()
    @Published private(set) var previewMetadataByPaperID: [Int: PaperPreviewMetadata] = [:]
    @Published private(set) var previewFailedIDs: Set<Int> = []
    @Published var selectedOrder: PaperSortOrder = .newest
    @Published var searchText = ""
    @Published var alert: AppAlert?

    private let service: any PaperListServicing
    private let requiresSearchText: Bool
    private var hasBootstrapped = false
    private var pageQuery: (search: String?, order: PaperSortOrder)?
    var displayedQueryDescription: String? {
        guard let pageQuery, pageQuery.search != trimmedSearchText || pageQuery.order != selectedOrder else { return nil }
        return "\(pageQuery.search.map { "“\($0)”的文章" } ?? "全部文章") · \(pageQuery.order.title)"
    }
    private var previewLoadingIDs: Set<Int> = []
    @Published private(set) var refreshGeneration = 0
    @Published private(set) var previewGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshPreviousState: (state: PaperListState, metadata: [Int: PaperPreviewMetadata], failures: Set<Int>)?

    init(service: any PaperListServicing, requiresSearchText: Bool) {
        self.service = service
        self.requiresSearchText = requiresSearchText
    }

    deinit { refreshTask?.cancel() }

    func cancelRefreshOperations() {
        refreshTask?.cancel(); refreshTask = nil
        refreshGeneration &+= 1
        previewLoadingIDs.removeAll()
        if let refreshPreviousState {
            state = refreshPreviousState.state
            previewMetadataByPaperID = refreshPreviousState.metadata
            previewFailedIDs = refreshPreviousState.failures
        }
        refreshPreviousState = nil
        if state.status == .loading { state.status = state.items.isEmpty ? .idle : .loaded }
        if state.status == .idle { hasBootstrapped = false }
        state.isLoadingMore = false
    }

    @discardableResult
    func enqueueRefresh() -> Task<Void, Never> {
        cancelRefreshOperations()
        hasBootstrapped = true
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
        guard !requiresSearchText || query.search != nil else { reset(); return }
        let previousState = state
        let previousMetadata = previewMetadataByPaperID
        let previousFailures = previewFailedIDs
        refreshPreviousState = (previousState, previousMetadata, previousFailures)
        previewLoadingIDs = []
        defer {
            if refreshGeneration == generation {
                refreshPreviousState = nil
                previewGeneration &+= 1
            }
        }
        if requiresSearchText || state.items.isEmpty {
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
            previewMetadataByPaperID = [:]
            previewFailedIDs = []
            previewLoadingIDs = []
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
                previewFailedIDs = previousFailures
                return
            }
            state = previousState
            previewMetadataByPaperID = previousMetadata
            previewFailedIDs = previousFailures
            state.status = previousState.items.isEmpty ? .failed(error.localizedDescription) : .loaded
            state.isLoadingMore = false
            if previousState.items.isEmpty && !requiresSearchText { state.canLoadMore = false }
            let title = requiresSearchText ? "搜索文章失败" : previousState.items.isEmpty ? "加载文章失败" : "刷新文章失败"
            alert = AppAlert(title: title, error: error)
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

        var sourcePage = state.nextPage
        do {
            var progress = CommunityPageProgress<Int>()
            while true {
                try Task.checkCancellation()
                let papers = try await service.fetchPapers(search: query.search, order: query.order, page: sourcePage)
                try Task.checkCancellation()
                guard refreshGeneration == generation else { return }
                try progress.record(papers.map(\.id), knownIDs: state.pagedItems.ids)
                if papers.isEmpty || papers.contains(where: { !state.pagedItems.ids.contains($0.id) }) {
                    var updated = state
                    updated.nextPage = sourcePage
                    updated.appendPage(papers)
                    updated.paginationError = nil
                    state = updated
                    return
                }
                sourcePage += 1
            }
        } catch {
            guard refreshGeneration == generation else { return }
            state.nextPage = sourcePage
            if TaskCancellation.matches(error) { return }
            state.paginationError = error.localizedDescription
            alert = AppAlert(title: "加载更多失败", error: error)
        }
    }

    /// 文章作者信息由详情接口提供；文章行展示前请求详情，并将成功返回的作者预览信息缓存在内存中。
    func loadPreviewMetadataIfNeeded(for paper: PaperSummary) async {
        guard state.status == .loaded else { return }
        guard previewMetadataByPaperID[paper.id] == nil else { return }
        guard !previewLoadingIDs.contains(paper.id) else { return }
        let generation = refreshGeneration
        previewLoadingIDs.insert(paper.id)
        previewFailedIDs.remove(paper.id)
        defer { if refreshGeneration == generation { previewLoadingIDs.remove(paper.id) } }

        do {
            let metadata = try await service.fetchPreviewMetadata(id: paper.id)
            try Task.checkCancellation()
            guard refreshGeneration == generation else { return }
            previewMetadataByPaperID[paper.id] = metadata
        } catch {
            guard refreshGeneration == generation, !TaskCancellation.matches(error) else { return }
            previewFailedIDs.insert(paper.id)
        }
    }

    func previewMetadata(for paperID: Int) -> PaperPreviewMetadata? {
        previewMetadataByPaperID[paperID]
    }

    func reset() {
        cancelRefreshOperations()
        previewMetadataByPaperID = [:]
        previewFailedIDs = []
        previewLoadingIDs = []
        state = PaperListState()
        pageQuery = nil
    }

    private var trimmedSearchText: String? {
        normalizedPaperSearchText(searchText)
    }
}

@MainActor
final class PaperListViewModel: PaperCollectionViewModel {
    init(service: any PaperListServicing) {
        super.init(service: service, requiresSearchText: false)
    }
}

@MainActor
/// 搜索页持有独立集合，空查询沿搜索语义清空结果。
final class PaperSearchViewModel: PaperCollectionViewModel {

    init(service: any PaperListServicing) {
        super.init(service: service, requiresSearchText: true)
    }

    func cancelSearchOperations() { cancelRefreshOperations() }
    @discardableResult func enqueueSearch() -> Task<Void, Never> { enqueueRefresh() }
    func performSearch() async { await refresh() }
}

#if os(iOS)
@MainActor
/// 文章详情状态机。
final class PaperDetailViewModel: ObservableObject {
    let pendingOperations = CommunityDetailTasks()
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
    private var likeResultNeedsReview = false
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
        if paper == nil, let cached = await service.cachedPaper(id: initialPaper.id), !Task.isCancelled {
            await handlePaperResult(.success(cached), previousStatus: .idle, likeRevisionAtStart: likeRevision, generation: refreshGeneration)
        }
        guard !Task.isCancelled else { hasBootstrapped = false; return }
        await refreshAll()
        if Task.isCancelled || paperStatus == .idle || commentState.status == .idle { hasBootstrapped = false }
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

        async let paperRefresh: Void = { @MainActor [self] in
            let result = await loadResult { [self] in try await service.fetchPaper(id: initialPaper.id) }
            guard refreshGeneration == generation else { return }
            await handlePaperResult(result, previousStatus: previousPaperStatus, likeRevisionAtStart: likeRevisionAtStart, generation: generation)
        }()
        async let commentRefresh: Void = { @MainActor [self, commentOrder] in
            let result = await loadResult { [self] in try await service.fetchComments(paperID: initialPaper.id, order: commentOrder, page: nil) }
            guard commentRefreshGeneration == commentsGeneration else { return }
            handleCommentRefreshResult(result, previousState: previousCommentState)
        }()
        _ = await (paperRefresh, commentRefresh)
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
        let likeRevisionAtStart = commentState.likeRevision
        commentState.isLoadingMore = true
        defer {
            if commentRefreshGeneration == generation {
                commentState.isLoadingMore = false
            }
        }

        let result = await loadResult { [self] in
            var progress = CommunityPageProgress<Int>()
            while true {
                let comments = try await self.service.fetchComments(paperID: self.initialPaper.id, order: order, page: commentState.nextPage)
                try Task.checkCancellation()
                guard commentRefreshGeneration == generation else { throw CancellationError() }
                try progress.record(comments.map(\.id), knownIDs: commentState.pagedItems.ids)
                if comments.isEmpty || comments.contains(where: { !commentState.pagedItems.ids.contains($0.id) }) { return comments }
                commentState.nextPage += 1
            }
        }

        switch result {
        case let .success(comments):
            guard commentRefreshGeneration == generation else { return }
            commentState.confirmRead(in: comments)
            commentState.appendPage(commentState.applyingLocalChanges(to: comments, since: likeRevisionAtStart))
            commentState.canLoadMore = !comments.isEmpty
            commentState.paginationError = nil
        case let .failure(error):
            guard commentRefreshGeneration == generation else { return }
            if TaskCancellation.matches(error) { return }
            commentState.paginationError = error.localizedDescription
            alert = AppAlert(title: "加载更多失败", error: error)
        }
    }

    /// 切换评论排序时刷新评论区，文章正文保持当前内容。
    func setCommentOrder(_ order: CommunityCommentOrder) async {
        guard commentOrder != order else { return }
        commentOrder = order
        await refreshComments()
    }

    var isPaperLiked: Bool { latestLikeResult?.like ?? paper?.like ?? false }
    var hasKnownLikeState: Bool { paper?.isViewerAuthenticated == true || latestLikeResult != nil }
    var likeStateMessage: String { paper?.isViewerAuthenticated == false ? "社区认证后可点赞" : "点赞状态待获取" }
    var resolvedLikeNum: Int { latestLikeResult?.likeNum ?? paper?.likeNum ?? initialPaper.likeNum }

    func likePaper() async {
        guard hasKnownLikeState else { return }
        guard !likeResultNeedsReview else {
            alert = AppAlert(title: "点赞结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage)
            return
        }
        guard !isLikingPaper else { return }
        isLikingPaper = true
        defer { isLikingPaper = false }

        do {
            let result = try await service.likePaper(id: initialPaper.id)
            likeRevision &+= 1
            latestLikeResult = result
            if let paper {
                self.paper = paper.updatingLike(result.like, likeNum: result.likeNum)
            }
        } catch {
            if error is CommunityToggleOutcomeUnknown {
                likeResultNeedsReview = true
                await refreshAll()
                if likeResultNeedsReview { alert = AppAlert(title: "点赞结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage) }
                return
            }
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "点赞失败", error: error)
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
            alert = AppAlert(title: "删除失败", error: error)
            return false
        }
    }

    func toggleCommentLike(_ comment: CommunityComment) async {
        guard comment.isViewerAuthenticated else { return }
        guard !commentState.likesNeedingReview.contains(comment.id) else {
            alert = AppAlert(title: "点赞结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage)
            return
        }
        guard !likingCommentIDs.contains(comment.id) else { return }
        likingCommentIDs.insert(comment.id)
        defer { likingCommentIDs.remove(comment.id) }

        do {
            let result = try await service.sendLike(objectID: "comment\(comment.id)")
            commentState.recordLike(result, for: comment.id)
        } catch {
            if error is CommunityToggleOutcomeUnknown {
                commentState.recordUncertainLike(for: comment.id)
                await refreshComments()
                if commentState.likesNeedingReview.contains(comment.id) { alert = AppAlert(title: "点赞结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage) }
                return
            }
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "点赞失败", error: error)
        }
    }

    var commentReview: CommunityCommentReviewActions {
        .init(needsReview: { self.commentState.needsReview($0) },
            acknowledge: { self.commentState.acknowledgeSubmissionReview($0) })
    }

    func submitComment(text: String, anonymous: Bool, target: CommunityCommentComposerTarget) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alert = AppAlert.userInput(title: "发送失败", message: "评论不能为空。")
            return false
        }
        guard !isSubmittingComment else { return false }
        let submission = CommunityCommentSubmission(objectID: target.objectID, text: trimmed,
            anonymous: anonymous, replyObjectID: target.replyObjectID, replyUID: target.replyUID)
        guard !commentState.needsReview(submission) else {
            alert = AppAlert(title: "发送结果待确认", message: CommunityCreateOutcomeUnknown.commentReviewMessage)
            return false
        }

        isSubmittingComment = true
        defer { isSubmittingComment = false }

        do {
            try Task.checkCancellation()
            let created = try await service.createComment(
                objectID: target.objectID,
                text: trimmed,
                replyObjectID: target.replyObjectID,
                replyUID: target.replyUID,
                anonymous: anonymous
            )
            let parent: CommunityComment?
            if case let .comment(mainComment, _) = target { parent = mainComment } else { parent = nil }
            commentState.recordCreated(created, replyingTo: parent)
            pendingOperations.enqueue { [weak self] in await self?.refreshAll() }
            return true
        } catch {
            if error is CommunityCreateOutcomeUnknown {
                commentState.recordUncertainSubmission(submission)
                alert = AppAlert(title: "发送结果待确认", message: CommunityCreateOutcomeUnknown.commentReviewMessage)
                return false
            }
            if Task.isCancelled || TaskCancellation.matches(error) { return false }
            alert = AppAlert(title: "发送失败", error: error)
            return false
        }
    }

    private func handlePaperResult(_ result: Result<PaperDetail, Error>, previousStatus: CommunityLoadStatus, likeRevisionAtStart: Int, generation: Int) async {
        guard refreshGeneration == generation else { return }
        switch result {
        case let .success(paper):
            let prepared: [PaperContentBlock]
            do {
                prepared = try await PaperContentRenderer.blocksForDisplay(from: paper.content)
                try Task.checkCancellation()
            }
            catch {
                await handlePaperResult(.failure(error), previousStatus: previousStatus, likeRevisionAtStart: likeRevisionAtStart, generation: generation)
                return
            }
            guard refreshGeneration == generation else { return }
            likeResultNeedsReview = false
            if likeRevision != likeRevisionAtStart, let latestLikeResult {
                self.paper = paper.updatingLike(latestLikeResult.like, likeNum: latestLikeResult.likeNum)
            } else {
                self.paper = paper
                latestLikeResult = nil
            }
            contentBlocks = prepared
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
            alert = AppAlert(title: "加载文章失败", error: error)
        }
    }

    private func handleCommentRefreshResult(
        _ result: Result<[CommunityComment], Error>,
        previousState: CommunityCommentState
    ) {
        switch result {
        case let .success(comments):
            commentState.order = commentOrder
            commentState.confirmRead(in: comments)
            commentState.applyFirstPage(commentState.applyingLocalChanges(to: comments, since: previousState.likeRevision))
            commentState.canLoadMore = !comments.isEmpty
            commentState.paginationError = nil
            commentState.status = .loaded
        case let .failure(error):
            let cancelled = TaskCancellation.matches(error)
            commentState.restoreAfterRefreshFailure(previousState, failureStatus: cancelled ? nil : .failed(error.localizedDescription))
            if !commentState.items.isEmpty { commentOrder = commentState.order }
            if cancelled { return }
            alert = AppAlert(title: "加载评论失败", error: error)
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
