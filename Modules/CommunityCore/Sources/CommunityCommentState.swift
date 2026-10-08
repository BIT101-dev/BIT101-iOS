/// 帖子详情评论列表的分页状态。
public struct CommunityCommentState {
    public init() {}

    /// 当前已加载的顶层评论列表。
    public var items: [CommunityComment] = []
    /// 评论区当前的整体加载状态。
    public var status: CommunityLoadStatus = .idle
    public var order: CommunityCommentOrder = .newest
    /// 下一页评论请求是否进行中。
    public var isLoadingMore = false
    /// 下一页评论页码。
    public var nextPage = 0
    /// 服务端是否还有更多评论。
    public var canLoadMore = true
    public private(set) var likeRevision = 0
    private var likeResults: [Int: (revision: Int, result: CommunityLikeResult)] = [:]

    public mutating func recordLike(_ result: CommunityLikeResult, for commentID: Int) {
        let previousRevision = likeRevision
        likeRevision &+= 1
        likeResults[commentID] = (likeRevision, result)
        items = applyingLikes(to: items, since: previousRevision)
    }

    public func applyingLikes(to comments: [CommunityComment], since revision: Int) -> [CommunityComment] {
        comments.map { comment in
            let updated = comment.replacingSubComments(applyingLikes(to: comment.sub, since: revision))
            if let change = likeResults[comment.id], change.revision > revision {
                return updated.updatingLike(change.result.like, likeNum: change.result.likeNum)
            }
            return updated
        }
    }

    public mutating func restoreAfterRefreshFailure(_ previous: Self, failureStatus: CommunityLoadStatus? = nil) {
        let currentResults = likeResults
        let currentRevision = likeRevision
        self = previous
        likeResults = currentResults
        likeRevision = currentRevision
        items = applyingLikes(to: items, since: previous.likeRevision)
        isLoadingMore = false
        if !items.isEmpty { status = .loaded }
        else if let failureStatus { status = failureStatus }
        else if status == .loading { status = .idle }
    }
}

extension CommunityCommentState: PagedItemsState {}
