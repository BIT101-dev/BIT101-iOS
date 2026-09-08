import Combine
import Foundation

/// 帖子详情评论列表的分页状态。
struct GalleryCommentState {
    /// 当前已加载的顶层评论列表。
    var items: [GalleryComment] = []
    /// 评论区当前的整体加载状态。
    var status: GalleryFeedStatus = .idle
    /// 下一页评论请求是否进行中。
    var isLoadingMore = false
    /// 下一页评论页码。
    var nextPage = 0
    /// 服务端是否还有更多评论。
    var canLoadMore = true
}

extension GalleryCommentState: PagedItemsState {}

/// 评论输入的目标。
///
/// 发评论页既支持“直接评论帖子”，也支持“回复某条评论”。
/// 这两种场景使用不同的接口参数，这个枚举统一表示两个评论目标。
enum GalleryCommentComposerTarget: Identifiable, Equatable {
    case poster(posterID: Int)
    case comment(mainComment: GalleryComment, targetComment: GalleryComment)

    /// 供 sheet 和焦点状态使用的稳定标识。
    var id: String {
        switch self {
        case let .poster(posterID):
            return "poster-\(posterID)"
        case let .comment(mainComment, targetComment):
            return "comment-\(mainComment.id)-\(targetComment.id)"
        }
    }

    /// 当前输入行为的可读标题。
    var title: String {
        switch self {
        case .poster:
            return "发表评论"
        case let .comment(_, targetComment):
            return "回复 @\(targetComment.user.nickname)"
        }
    }

    /// 评论输入框占位文案。
    var placeholder: String {
        switch self {
        case .poster:
            return "写点什么吧"
        case let .comment(_, targetComment):
            return "回复 @\(targetComment.user.nickname)"
        }
    }

    /// 发评论接口里的目标对象 ID。
    var objectID: String {
        switch self {
        case let .poster(posterID):
            return "poster\(posterID)"
        case let .comment(mainComment, _):
            return "comment\(mainComment.id)"
        }
    }

    /// 回复评论时需要带上的次级目标对象 ID。
    var replyObjectID: String? {
        switch self {
        case .poster:
            return nil
        case let .comment(mainComment, targetComment):
            guard mainComment.id != targetComment.id else { return nil }
            return "comment\(targetComment.id)"
        }
    }

    /// 回复评论时用于 @ 提示的用户 ID。
    var replyUID: Int? {
        switch self {
        case .poster:
            return nil
        case let .comment(mainComment, targetComment):
            guard mainComment.id != targetComment.id else { return nil }
            return targetComment.user.id
        }
    }
}

/// 帖子详情状态机。
///
/// 负责重新拉取帖子详情、评论分页、排序切换、点赞和评论发送。
@MainActor
final class GalleryPosterDetailViewModel: ObservableObject {
    /// 当前正在展示的帖子详情。
    @Published private(set) var poster: GalleryPosterDetail
    /// 帖子正文区域的加载状态。
    @Published private(set) var posterStatus: GalleryFeedStatus = .idle
    /// 评论区的分页状态。
    @Published private(set) var commentState = GalleryCommentState()
    /// 当前评论排序方式。
    @Published var commentOrder: GalleryCommentOrder = .newest
    /// 点赞请求是否进行中，重复操作直接返回。
    @Published private(set) var isLikingPoster = false
    /// 当前正在点赞的评论 ID 集合。
    @Published private(set) var likingCommentIDs: Set<Int> = []
    /// 评论提交请求是否进行中。
    @Published private(set) var isSubmittingComment = false
    /// 帖子删除请求是否进行中。
    @Published private(set) var isDeletingPoster = false
    /// 页面级统一提示。
    @Published var alert: AppAlert?

    /// 固定的帖子 ID。后续刷新都基于它重新请求详情。
    private let posterID: Int
    private let service: any GalleryPosterDetailServicing
    private var refreshGeneration = 0
    /// 当前详情页对应的帖子对象 ID 字符串。
    ///
    /// 评论和帖子点赞接口都使用同一套 `poster{id}` 语义，由这个属性统一生成，
    /// 减少多个方法重复拼接同一个字面量。
    private var posterObjectID: String { "poster\(posterID)" }

    /// 用列表卡片初始化详情状态机。
    ///
    /// 详情页通常从帖子卡片进入，初始化时先用列表数据生成临时详情对象，
    /// 详情请求完成后替换为真实详情，页面首帧保留已有内容。
    init(initialPoster: GalleryPoster, service: any GalleryPosterDetailServicing) {
        posterID = initialPoster.id
        poster = GalleryPosterDetail(poster: initialPoster)
        self.service = service
    }

    convenience init(initialPoster: GalleryPoster) {
        self.init(initialPoster: initialPoster, service: GalleryService())
    }

    /// 首次进入详情页时并行拉取帖子详情和第一页评论。
    ///
    /// 只有“帖子状态和评论状态都还在 idle”时才触发：
    /// - 视图重复出现时保持单次请求
    /// - 调用方手动刷新后保留刷新结果
    func bootstrapIfNeeded() async {
        guard posterStatus == .idle, commentState.status == .idle else { return }
        await refreshAll()
    }

    /// 并行刷新帖子详情和评论列表。
    func refreshAll() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let previousPosterStatus = posterStatus
        let previousCommentState = commentState
        posterStatus = .loading
        resetCommentStateForRefresh()

        async let posterResult = loadResult { [self] in
            try await self.service.fetchPoster(id: self.posterID)
        }
        async let commentResult = loadResult { [self, commentOrder] in
            try await self.service.fetchComments(objectID: self.posterObjectID, order: commentOrder, page: nil)
        }

        let resolvedPosterResult = await posterResult
        guard refreshGeneration == generation else { return }
        handlePosterResult(resolvedPosterResult, previousStatus: previousPosterStatus)

        let resolvedCommentResult = await commentResult
        guard refreshGeneration == generation else { return }
        handleCommentRefreshResult(resolvedCommentResult, previousState: previousCommentState)
    }

    /// 仅刷新评论区，不重新请求帖子正文。
    func refreshComments() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let previousState = commentState
        resetCommentStateForRefresh()

        let result = await loadResult { [self] in
            try await self.service.fetchComments(objectID: self.posterObjectID, order: self.commentOrder, page: nil)
        }
        guard refreshGeneration == generation else { return }
        handleCommentRefreshResult(result, previousState: previousState)
    }

    /// 当滚动到尾部附近时触发评论分页。
    ///
    /// 评论分页使用“最后几条触发”策略，评论列表接近尾部时请求下一页。
    func loadMoreCommentsIfNeeded(currentComment: GalleryComment?) async {
        guard let currentComment else { return }
        let generation = refreshGeneration
        guard commentState.status == .loaded,
              commentState.shouldLoadMore(currentID: currentComment.id)
        else { return }

        commentState.isLoadingMore = true
        defer { commentState.isLoadingMore = false }
        let nextPage = commentState.nextPage
        let result = await loadResult { [self] in
            try await self.service.fetchComments(objectID: self.posterObjectID, order: self.commentOrder, page: nextPage)
        }

        switch result {
        case let .success(comments):
            guard refreshGeneration == generation else { return }
            commentState.appendPage(comments)
        case let .failure(error):
            guard refreshGeneration == generation else { return }
            if isCancellation(error) {
                return
            }
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 切换评论排序后立刻重新请求第一页。
    ///
    /// 评论排序会改变整棵评论树的结构，排序切换后直接重新拉取第一页，保持与服务端结果一致。
    func setCommentOrder(_ order: GalleryCommentOrder) async {
        guard commentOrder != order else { return }
        commentOrder = order
        await refreshComments()
    }

    /// 点赞或取消点赞当前帖子。
    ///
    /// 帖子详情只维护一份当前详情模型，因此点赞成功后直接替换 `poster` 即可。
    func likePoster() async {
        guard !isLikingPoster else { return }
        isLikingPoster = true
        defer { isLikingPoster = false }

        do {
            let result = try await service.like(objectID: posterObjectID)
            poster = poster.updatingLike(result.like, likeNum: result.likeNum)
        } catch {
            if isCancellation(error) { return }
            alert = AppAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    /// 点赞或取消点赞某条评论。
    ///
    /// 评论可能嵌套在多级子评论里，所以更新时需要递归地重建评论树。
    func likeComment(_ comment: GalleryComment) async {
        guard !likingCommentIDs.contains(comment.id) else { return }
        likingCommentIDs.insert(comment.id)
        defer { likingCommentIDs.remove(comment.id) }

        do {
            let result = try await service.like(objectID: "comment\(comment.id)")
            commentState.items = commentState.items.updatingLike(for: comment.id, like: result.like, likeNum: result.likeNum)
        } catch {
            if isCancellation(error) { return }
            alert = AppAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    /// 发送评论或回复。
    ///
    /// 发送成功后直接整页刷新，确保帖子计数和评论树保持一致。
    func submitComment(text: String, anonymous: Bool, target: GalleryCommentComposerTarget) async -> Bool {
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
            if isCancellation(error) { return false }
            alert = AppAlert(title: "发送失败", message: error.localizedDescription)
            return false
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
            if isCancellation(error) { return false }
            alert = AppAlert(title: "删除失败", message: error.localizedDescription)
            return false
        }
    }

    /// 统一处理帖子详情请求结果。
    ///
    /// 取消请求时恢复刷新前状态，页面快速切换时静默处理网络取消。
    private func handlePosterResult(
        _ result: Result<GalleryPosterDetail, Error>,
        previousStatus: GalleryFeedStatus
    ) {
        switch result {
        case let .success(poster):
            self.poster = poster
            posterStatus = .loaded
        case let .failure(error):
            if isCancellation(error) {
                posterStatus = previousStatus
                return
            }
            posterStatus = .failed(error.localizedDescription)
            alert = AppAlert(title: "加载帖子失败", message: error.localizedDescription)
        }
    }

    /// 统一处理“刷新第一页评论”的结果。
    private func handleCommentRefreshResult(
        _ result: Result<[GalleryComment], Error>,
        previousState: GalleryCommentState
    ) {
        switch result {
        case let .success(comments):
            commentState.applyFirstPage(comments)
            commentState.status = .loaded
        case let .failure(error):
            if isCancellation(error) {
                commentState = previousState
                return
            }
            commentState.status = .failed(error.localizedDescription)
            commentState.canLoadMore = false
            commentState.isLoadingMore = false
            alert = AppAlert(title: "加载评论失败", message: error.localizedDescription)
        }
    }

    /// 把评论区恢复到“重新拉第一页”的初始加载状态。
    ///
    /// 详情页初次进入和切换评论排序时都要把评论分页状态整体重置，这里集中处理相关字段。
    private func resetCommentStateForRefresh() {
        commentState.status = .loading
        commentState.resetPagination()
    }

    /// 把抛错的异步操作包装为 `Result`，并行加载详情和评论时统一处理结果。
    private func loadResult<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    /// 同时兼容 Swift Concurrency 的 `CancellationError` 和 URLSession 的 `-999 cancelled`。
    private func isCancellation(_ error: Error) -> Bool {
        TaskCancellation.matches(error)
    }
}

private extension Array where Element == GalleryComment {
    /// 递归更新评论树中的点赞状态。
    ///
    /// 顶层评论和子评论使用同一模型，这个数组扩展递归更新评论树，
    /// 视图模型只调用数组扩展处理嵌套评论。
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
