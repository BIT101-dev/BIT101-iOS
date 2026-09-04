import Combine
import Foundation

/// 帖子详情评论列表的分页状态。
struct GalleryCommentState {
    /// 当前已加载的顶层评论列表。
    var items: [GalleryComment] = []
    /// 评论区当前的整体加载状态。
    var status: GalleryFeedStatus = .idle
    /// 是否正在请求下一页评论。
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
/// 这两种场景最终需要拼出来的接口参数不同，所以这里用一个枚举把它们收敛到一起。
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

@MainActor
/// 帖子详情状态机。
///
/// 负责重新拉取帖子详情、评论分页、排序切换、点赞和评论发送。
final class GalleryPosterDetailViewModel: ObservableObject {
    /// 当前正在展示的帖子详情。
    @Published private(set) var poster: GalleryPosterDetail
    /// 帖子正文区域的加载状态。
    @Published private(set) var posterStatus: GalleryFeedStatus = .idle
    /// 评论区的分页状态。
    @Published private(set) var commentState = GalleryCommentState()
    /// 当前评论排序方式。
    @Published var commentOrder: GalleryCommentOrder = .newest
    /// 是否正在点赞帖子，避免重复点击。
    @Published private(set) var isLikingPoster = false
    /// 当前正在点赞的评论 ID 集合。
    @Published private(set) var likingCommentIDs: Set<Int> = []
    /// 是否正在提交评论。
    @Published private(set) var isSubmittingComment = false
    /// 是否正在删除帖子。
    @Published private(set) var isDeletingPoster = false
    /// 页面级统一提示。
    @Published var alert: AppAlert?

    /// 固定的帖子 ID。后续刷新都基于它重新请求详情。
    private let posterID: Int
    private let service: any GalleryPosterDetailServicing
    /// 当前详情页对应的帖子对象 ID 字符串。
    ///
    /// 帖子详情、评论、点赞等接口都复用同一套 `poster{id}` 语义，把这层拼接抽成统一属性，
    /// 可以避免同一个字面量在多个方法里重复出现。
    private var posterObjectID: String { "poster\(posterID)" }

    /// 用列表卡片初始化详情状态机。
    ///
    /// 详情页通常是从某张帖子卡片点进来的，因此这里先把列表已有数据转换成一份
    /// 临时详情对象，再异步替换成真实详情，可以避免页面首帧完全空白。
    init(initialPoster: GalleryPoster, service: any GalleryPosterDetailServicing) {
        posterID = initialPoster.id
        poster = GalleryPosterDetail(poster: initialPoster)
        self.service = service
    }

    convenience init(initialPoster: GalleryPoster) {
        self.init(initialPoster: initialPoster, service: GalleryService())
    }

    /// 首次进入详情页时同时拉取帖子详情和第一页评论。
    ///
    /// 这里要求“帖子状态和评论状态都还在 idle”才会触发，是为了防止：
    /// - 视图重复出现时多次并发请求
    /// - 调用方已经手动触发刷新后又被 bootstrap 重复覆盖
    func bootstrapIfNeeded() async {
        guard posterStatus == .idle, commentState.status == .idle else { return }
        await refreshAll()
    }

    /// 同步刷新帖子详情和评论列表。
    func refreshAll() async {
        posterStatus = .loading
        resetCommentStateForRefresh()

        async let posterResult = loadResult { [self] in
            try await self.service.fetchPoster(id: self.posterID)
        }
        async let commentResult = loadResult { [self, commentOrder] in
            try await self.service.fetchComments(objectID: self.posterObjectID, order: commentOrder, page: nil)
        }

        let resolvedPosterResult = await posterResult
        let resolvedCommentResult = await commentResult

        handlePosterResult(resolvedPosterResult)
        handleCommentRefreshResult(resolvedCommentResult)
    }

    /// 仅刷新评论区，不重新请求帖子正文。
    func refreshComments() async {
        resetCommentStateForRefresh()

        let result = await loadResult { [self] in
            try await self.service.fetchComments(objectID: self.posterObjectID, order: self.commentOrder, page: nil)
        }
        handleCommentRefreshResult(result)
    }

    /// 当滚动到尾部附近时触发评论分页。
    ///
    /// 评论分页依然沿用“最后几条触发”的策略，因为评论列表长度通常远小于主 feed，
    /// 且用户更能接受在尾部附近触发一次分页请求。
    func loadMoreCommentsIfNeeded(currentComment: GalleryComment?) async {
        guard let currentComment else { return }
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
            commentState.appendPage(comments)
        case let .failure(error):
            if isCancellation(error) {
                return
            }
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 切换评论排序后立刻重新请求第一页。
    ///
    /// 评论排序会改变整棵评论树的结构，因此不做本地排序，直接重新拉第一页，
    /// 保证与服务端结果完全一致。
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
    /// 取消请求不视为失败，而是静默把状态维持在“已加载”，避免用户快速切页时
    /// 因网络取消看到误导性的失败弹窗。
    private func handlePosterResult(_ result: Result<GalleryPosterDetail, Error>) {
        switch result {
        case let .success(poster):
            self.poster = poster
            posterStatus = .loaded
        case let .failure(error):
            if isCancellation(error) {
                posterStatus = .loaded
                return
            }
            posterStatus = .failed(error.localizedDescription)
            alert = AppAlert(title: "加载帖子失败", message: error.localizedDescription)
        }
    }

    /// 统一处理“刷新第一页评论”的结果。
    private func handleCommentRefreshResult(_ result: Result<[GalleryComment], Error>) {
        switch result {
        case let .success(comments):
            commentState.applyFirstPage(comments)
            commentState.status = .loaded
        case let .failure(error):
            if isCancellation(error) {
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

    /// 把评论区恢复到“重新拉第一页”的初始加载状态。
    ///
    /// 详情页初次进入和切换评论排序时都要把评论分页状态整体重置，因此这里集中收口，
    /// 避免同一组字段在多个方法里重复赋值。
    private func resetCommentStateForRefresh() {
        commentState.status = .loading
        commentState.resetPagination()
    }

    /// 把抛错的异步操作包成 `Result`，方便并发拉详情和评论时统一收口。
    private func loadResult<T>(_ operation: @escaping () async throws -> T) async -> Result<T, Error> {
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
    /// 顶层评论和子评论共用同一个模型结构，因此这里用数组扩展做树状更新，
    /// 让视图模型不必知道评论嵌套的具体深度。
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
