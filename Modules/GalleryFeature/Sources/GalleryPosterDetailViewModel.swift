import CommunityUI
import TransportCore
import DesignSystemKit
import CommunityCore
import CommunityTransport
import Combine
import Foundation

@MainActor
final class GalleryPosterDetailViewModel: ObservableObject {
    let pendingOperations = CommunityDetailTasks()
    private(set) var needsContentRefresh = false
    /// 当前正在展示的帖子详情。
    @Published private(set) var poster: GalleryPosterDetail
    /// 帖子正文区域的加载状态。
    @Published private(set) var posterStatus: CommunityLoadStatus = .idle
    /// 评论区的分页状态。
    @Published private(set) var commentState = CommunityCommentState()
    /// 当前评论排序方式。
    @Published var commentOrder: CommunityCommentOrder = .newest
    /// 点赞请求是否进行中，重复操作直接返回。
    @Published private(set) var isLikingPoster = false
    @Published private(set) var hasKnownLikeState = false
    @Published private(set) var isSavingSubscription = false
    var subscriptionLevel: GallerySubscriptionLevel { poster.subscription ?? GallerySubscriptionLevel.none }
    private var subscriptionRevision = 0
    /// 当前正在点赞的评论 ID 集合。
    @Published private(set) var likingCommentIDs: Set<Int> = []
    /// 评论提交请求是否进行中。
    @Published private(set) var isSubmittingComment = false
    @Published private(set) var deletingCommentIDs: Set<Int> = []
    /// 帖子删除请求是否进行中。
    @Published private(set) var isDeletingPoster = false
    /// 页面级统一提示。
    @Published var alert: AppAlert?

    /// 固定的帖子 ID。后续刷新都基于它重新请求详情。
    private let posterID: Int
    private let service: any GalleryPosterDetailServicing
    private var likeRevision = 0
    private var likeResultNeedsReview = false
    private var latestLikeResult: CommunityLikeResult?
    private var refreshGeneration = 0
    private var commentRefreshGeneration = 0
    private var contentFilter: GalleryCommentFilter?
    /// 当前详情页对应的帖子对象 ID 字符串。
    ///
    /// 评论和帖子点赞接口都使用同一套 `poster{id}` 语义，由这个属性统一生成，
    /// 减少多个方法重复拼接同一个字面量。
    private var posterObjectID: String { "poster\(posterID)" }

    /// 用列表卡片初始化详情状态机。
    ///
    /// 详情页通常从帖子卡片进入，初始化时先用列表数据生成临时详情对象，
    /// 详情请求完成后替换为真实详情，页面首帧保留已有内容。
    init(initialPoster: CommunityPoster, initialDetail: GalleryPosterDetail? = nil, service: any GalleryPosterDetailServicing) {
        posterID = initialPoster.id
        poster = initialDetail ?? GalleryPosterDetail(poster: initialPoster)
        self.service = service
        if initialDetail != nil { posterStatus = .loaded; hasKnownLikeState = true }
    }


    /// 首次进入详情页时并行拉取帖子详情和第一页评论。
    ///
    /// 视图重复出现时保持单次请求，取消后为待加载区域恢复进入请求。
    func bootstrapIfNeeded() async {
        await pendingOperations.bootstrapIfNeeded {
            if posterStatus == .loaded { await refreshComments() }
            else { await refreshAll() }
            return !Task.isCancelled && posterStatus != .idle && commentState.status != .idle
        }
    }

    /// 并行刷新帖子详情和评论列表。
    func refreshAll() async {
        let likeRevisionAtStart = likeRevision
        let subscriptionRevisionAtStart = subscriptionRevision
        refreshGeneration &+= 1
        commentRefreshGeneration &+= 1
        let generation = refreshGeneration
        let commentsGeneration = commentRefreshGeneration
        let previousPosterStatus = posterStatus
        let previousCommentState = commentState
        posterStatus = .loading
        resetCommentStateForRefresh()

        async let posterRefresh: Void = { @MainActor [self] in
            let result = await CommunityDetailTasks.loadResult { [self] in try await service.fetchPoster(id: posterID) }
            guard refreshGeneration == generation else { return }
            handlePosterResult(result, previousStatus: previousPosterStatus, likeRevisionAtStart: likeRevisionAtStart,
                subscriptionRevisionAtStart: subscriptionRevisionAtStart)
        }()
        async let commentRefresh: Void = { @MainActor [self, commentOrder] in
            let result = await CommunityDetailTasks.loadResult { [self] in try await service.fetchComments(objectID: posterObjectID, order: commentOrder, page: nil) }
            guard commentRefreshGeneration == commentsGeneration else { return }
            handleCommentRefreshResult(result, previousState: previousCommentState)
        }()
        _ = await (posterRefresh, commentRefresh)
    }

    /// 仅刷新评论区，不重新请求帖子正文。
    func refreshComments() async {
        commentRefreshGeneration &+= 1
        let generation = commentRefreshGeneration
        let previousState = commentState
        resetCommentStateForRefresh()

        let result = await CommunityDetailTasks.loadResult { [self] in
            try await self.service.fetchComments(objectID: self.posterObjectID, order: self.commentOrder, page: nil)
        }
        guard commentRefreshGeneration == generation else { return }
        handleCommentRefreshResult(result, previousState: previousState)
    }

    func loadContent(filter: GalleryCommentFilter) async {
        let changed = contentFilter != nil && contentFilter != filter
        contentFilter = filter
        guard changed else { await bootstrapIfNeeded(); return }
        commentState.filterContent(filter.apply)
        if posterStatus == .loaded { await refreshComments() }
        else { await refreshAll() }
    }

    func retryFailedContentIfNeeded() async {
        if needsContentRefresh { await refreshAll(); return }
        if case .failed = posterStatus { await refreshAll() }
        else if case .failed = commentState.status { await refreshComments() }
    }

    /// 当滚动到尾部附近时触发评论分页。
    ///
    /// 评论分页使用“最后几条触发”策略，评论列表接近尾部时请求下一页。
    func loadMoreCommentsIfNeeded(currentComment: CommunityComment?) async {
        let generation = commentRefreshGeneration
        guard commentState.status == .loaded,
              commentState.canLoadMore, !commentState.isLoadingMore,
              currentComment.map({ commentState.shouldLoadMore(currentID: $0.id) }) ?? commentState.items.isEmpty
        else { return }

        commentState.isLoadingMore = true
        defer {
            if commentRefreshGeneration == generation {
                commentState.isLoadingMore = false
            }
        }
        let likeRevisionAtStart = commentState.likeRevision
        let initialPage = commentState.nextPage
        var sourcePage = initialPage
        let result = await CommunityDetailTasks.loadResult { [self] in
            var progress = CommunityPageProgress<Int>()
            while true {
                let batch = try await self.service.fetchComments(objectID: self.posterObjectID, order: self.commentOrder, page: sourcePage)
                try Task.checkCancellation()
                guard commentRefreshGeneration == generation else { throw CancellationError() }
                guard !batch.canLoadMore || (batch.nextSourcePage > sourcePage && !batch.sourceIDs.isEmpty)
                else { throw GalleryServiceError.invalidResponse }
                try progress.record(batch.sourceIDs, knownIDs: commentState.pagedItems.ids)
                if !batch.canLoadMore || batch.items.isEmpty || batch.items.contains(where: { !commentState.pagedItems.ids.contains($0.id) })
                    || batch.nextSourcePage - initialPage >= GalleryPaging.maximumSourcePages { return batch }
                sourcePage = batch.nextSourcePage
            }
        }

        guard commentRefreshGeneration == generation else { return }
        commentState.nextPage = sourcePage
        switch result {
        case let .success(batch):
            commentState.needsContinuation = batch.canLoadMore && batch.items.allSatisfy { commentState.pagedItems.ids.contains($0.id) }
            commentState.confirmRead(in: batch.items)
            commentState.appendPage(commentState.applyingLocalChanges(to: batch.items, since: likeRevisionAtStart))
            commentState.nextPage = batch.nextSourcePage
            commentState.canLoadMore = batch.canLoadMore
            commentState.paginationError = nil
        case let .failure(error):
            if TaskCancellation.matches(error) {
                return
            }
            alert = AppAlert(title: "加载更多失败", error: error)
            commentState.paginationError = error.localizedDescription
        }
    }

    /// 切换评论排序后立刻重新请求第一页。
    ///
    /// 评论排序会改变整棵评论树的结构，排序切换后直接重新拉取第一页，保持与服务端结果一致。
    func setCommentOrder(_ order: CommunityCommentOrder) async {
        guard commentOrder != order else { return }
        commentOrder = order
        await refreshComments()
    }

    /// 点赞或取消点赞当前帖子。
    ///
    /// 帖子详情只维护一份当前详情模型，因此点赞成功后直接替换 `poster` 即可。
    func likePoster() async {
        guard hasKnownLikeState else { return }
        guard !likeResultNeedsReview else {
            alert = AppAlert(title: "点赞结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage)
            return
        }
        guard !isLikingPoster else { return }
        isLikingPoster = true
        defer { isLikingPoster = false }

        do {
            let result = try await service.like(objectID: posterObjectID)
            likeRevision &+= 1
            latestLikeResult = result
            poster = poster.updatingLike(result.like, likeNum: result.likeNum)
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

    func setSubscription(_ level: GallerySubscriptionLevel) async -> Bool {
        guard !isSavingSubscription, posterStatus == .loaded, subscriptionLevel != level else { return false }
        isSavingSubscription = true
        defer { isSavingSubscription = false }
        do {
            try await service.setSubscription(objectID: posterObjectID, level: level)
            subscriptionRevision &+= 1
            poster = poster.updatingSubscription(level)
            return true
        } catch {
            if !TaskCancellation.matches(error) { alert = AppAlert(title: "插眼设置失败", error: error) }
            return false
        }
    }

    /// 点赞或取消点赞某条评论。
    ///
    /// 评论可能嵌套在多级子评论里，所以更新时需要递归地重建评论树。
    func likeComment(_ comment: CommunityComment) async {
        guard !commentState.likesNeedingReview.contains(comment.id) else {
            alert = AppAlert(title: "点赞结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage)
            return
        }
        guard !likingCommentIDs.contains(comment.id) else { return }
        likingCommentIDs.insert(comment.id)
        defer { likingCommentIDs.remove(comment.id) }

        do {
            let result = try await service.like(objectID: "comment\(comment.id)")
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

    /// 发送评论或回复。
    ///
    /// 发送确认后立即合并评论，关联计数沿页面任务刷新。
    var commentReview: CommunityCommentReviewActions {
        .init(needsReview: { self.commentState.needsReview($0) },
            acknowledge: { self.commentState.acknowledgeSubmissionReview($0) })
    }

    func submitComment(
        text: String,
        anonymous: Bool,
        imageMids: [String] = [],
        target: CommunityCommentComposerTarget
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alert = AppAlert.userInput(title: "发送失败", message: "评论不能为空。")
            return false
        }
        guard !isSubmittingComment else { return false }
        let submission = CommunityCommentSubmission(objectID: target.objectID, text: trimmed,
            anonymous: anonymous, replyObjectID: target.replyObjectID, replyUID: target.replyUID, imageMids: imageMids)
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
                anonymous: anonymous,
                imageMids: imageMids
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

    func deleteComment(_ comment: CommunityComment) async {
        guard comment.own, !deletingCommentIDs.contains(comment.id) else { return }
        deletingCommentIDs.insert(comment.id)
        defer { deletingCommentIDs.remove(comment.id) }

        do {
            try await service.deleteComment(id: comment.id)
            commentState.recordDeleted(comment.id)
            pendingOperations.enqueue { [weak self] in await self?.refreshAll() }
        } catch {
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "删除评论失败", error: error)
        }
    }

    /// 删除当前帖子。
    ///
    /// 只有本人帖子允许删帖；视图层会根据返回值决定是否关闭详情页并刷新上层列表。
    func deletePoster() async -> Bool {
        guard poster.own else { return false }
        guard !isDeletingPoster else { return false }

        isDeletingPoster = true
        defer { isDeletingPoster = false }

        do {
            try await service.deletePoster(id: posterID)
            return true
        } catch {
            if TaskCancellation.matches(error) { return false }
            alert = AppAlert(title: "删除失败", error: error)
            return false
        }
    }

    /// 统一处理帖子详情请求结果。
    ///
    /// 取消请求时恢复刷新前状态，页面快速切换时静默处理网络取消。
    private func handlePosterResult(
        _ result: Result<GalleryPosterDetail, Error>,
        previousStatus: CommunityLoadStatus,
        likeRevisionAtStart: Int,
        subscriptionRevisionAtStart: Int
    ) {
        switch result {
        case let .success(poster):
            needsContentRefresh = false
            hasKnownLikeState = true
            likeResultNeedsReview = false
            let previousSubscription = self.poster.subscription
            if likeRevision != likeRevisionAtStart, let latestLikeResult {
                self.poster = poster.updatingLike(latestLikeResult.like, likeNum: latestLikeResult.likeNum)
            } else {
                self.poster = poster
                latestLikeResult = nil
            }
            if subscriptionRevision != subscriptionRevisionAtStart, let previousSubscription {
                self.poster = self.poster.updatingSubscription(previousSubscription)
            }
            posterStatus = .loaded
        case let .failure(error):
            if TaskCancellation.matches(error) {
                posterStatus = previousStatus == .loading ? .idle : previousStatus
                return
            }
            needsContentRefresh = true
            posterStatus = hasKnownLikeState ? .loaded : .failed(error.localizedDescription)
            alert = AppAlert(title: "加载帖子失败", error: error)
        }
    }

    /// 统一处理“刷新第一页评论”的结果。
    private func handleCommentRefreshResult(
        _ result: Result<GalleryPageBatch<CommunityComment>, Error>,
        previousState: CommunityCommentState
    ) {
        switch result {
        case let .success(batch):
            commentState.order = commentOrder
            commentState.confirmRead(in: batch.items)
            commentState.applyFirstPage(commentState.applyingLocalChanges(to: batch.items, since: previousState.likeRevision))
            commentState.nextPage = batch.nextSourcePage
            commentState.canLoadMore = batch.canLoadMore
            commentState.needsContinuation = batch.items.isEmpty && batch.canLoadMore
            commentState.status = .loaded
            commentState.paginationError = nil
        case let .failure(error):
            let cancelled = TaskCancellation.matches(error)
            commentState.restoreAfterRefreshFailure(previousState, failureStatus: cancelled ? nil : .failed(error.localizedDescription))
            if commentState.status == .loaded { commentOrder = commentState.order }
            if cancelled { return }
            alert = AppAlert(title: "加载评论失败", error: error)
        }
    }

    /// 把评论区恢复到“重新拉第一页”的初始加载状态。
    ///
    /// 详情页初次进入和切换评论排序时都要把评论分页状态整体重置，这里集中处理相关字段。
    private func resetCommentStateForRefresh() {
        commentState.status = .loading
        commentState.isLoadingMore = false
    }

    /// 把抛错的异步操作包装为 `Result`，并行加载详情和评论时统一处理结果。


}
