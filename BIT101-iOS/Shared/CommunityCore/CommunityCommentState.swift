import ClientCore

/// 帖子详情评论列表的分页状态。
public struct CommunityCommentState {
    public init() {}

    /// 当前已加载的顶层评论列表。
    public var items: [CommunityComment] = []
    /// 评论区当前的整体加载状态。
    public var status: CommunityLoadStatus = .idle
    /// 下一页评论请求是否进行中。
    public var isLoadingMore = false
    /// 下一页评论页码。
    public var nextPage = 0
    /// 服务端是否还有更多评论。
    public var canLoadMore = true
}

extension CommunityCommentState: PagedItemsState {}

