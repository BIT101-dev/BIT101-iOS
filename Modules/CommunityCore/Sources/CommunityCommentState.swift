import Foundation

/// 帖子详情评论列表的分页状态。
public struct CommunityCommentState {
    public init() {}

    /// 当前已加载的顶层评论列表。
    public var pagedItems = CommunityPagedItems<CommunityComment>()
    public var items: [CommunityComment] {
        get { pagedItems.items }
        set { pagedItems.replace(with: newValue) }
    }
    /// 评论区当前的整体加载状态。
    public var status: CommunityLoadStatus = .idle
    public var order: CommunityCommentOrder = .newest
    /// 下一页评论请求是否进行中。
    public var isLoadingMore = false
    /// 下一页评论页码。
    public var nextPage = 0
    /// 服务端是否还有更多评论。
    public var canLoadMore = true
    public var needsContinuation = false
    public private(set) var likeRevision = 0
    private var likeResults: [Int: (revision: Int, result: CommunityLikeResult)] = [:]
    public private(set) var likesNeedingReview: Set<Int> = []

    public mutating func recordUncertainLike(for commentID: Int) {
        likesNeedingReview.insert(commentID)
        likeResults.removeValue(forKey: commentID)
    }

    public mutating func confirmReadLikes(in comments: [CommunityComment]) {
        for comment in comments {
            likesNeedingReview.remove(comment.id)
            confirmReadLikes(in: comment.sub)
        }
    }

    public mutating func recordLike(_ result: CommunityLikeResult, for commentID: Int) {
        let previousRevision = likeRevision
        likeRevision &+= 1
        likeResults[commentID] = (likeRevision, result)
        items = applyingLikes(to: items, since: previousRevision)
    }

    public func applyingLikes(to comments: [CommunityComment], since revision: Int) -> [CommunityComment] {
        applyingLikeChanges(to: comments, since: revision).comments
    }

    private func applyingLikeChanges(to comments: [CommunityComment], since revision: Int) -> (comments: [CommunityComment], changed: Bool) {
        var result = comments
        var changed = false
        for (index, comment) in comments.enumerated() {
            let replies = applyingLikeChanges(to: comment.sub, since: revision)
            var updated = replies.changed ? comment.replacingSubComments(replies.comments) : comment
            var hasChange = replies.changed
            if let change = likeResults[comment.id], change.revision > revision {
                updated = updated.updatingLike(change.result.like, likeNum: change.result.likeNum)
                hasChange = true
            }
            if hasChange { result[index] = updated; changed = true }
        }
        return (result, changed)
    }

    public mutating func restoreAfterRefreshFailure(_ previous: Self, failureStatus: CommunityLoadStatus? = nil) {
        let currentResults = likeResults
        let currentRevision = likeRevision
        let currentPending = likesNeedingReview
        self = previous
        likeResults = currentResults
        likeRevision = currentRevision
        likesNeedingReview = currentPending
        items = applyingLikes(to: items, since: previous.likeRevision)
        isLoadingMore = false
        if !items.isEmpty { status = .loaded }
        else if let failureStatus { status = failureStatus }
        else if status == .loading { status = .idle }
    }
}

extension CommunityCommentState: PagedItemsState {}

/// 详情页持有交互任务，页面退出时结束所属请求。
@MainActor public final class CommunityDetailTasks {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    deinit { tasks.values.forEach { $0.cancel() } }

    @discardableResult
    public func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await operation()
            self?.tasks[id] = nil
        }
        tasks[id] = task
        return task
    }

    public func cancel() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
