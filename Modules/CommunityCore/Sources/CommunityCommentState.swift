import Foundation

public nonisolated struct CommunityCommentSubmission: Hashable, Sendable {
    public let objectID: String
    public let text: String
    public let anonymous: Bool
    public let replyObjectID: String?
    public let replyUID: Int?
    public let rate: Int?
    public let imageMids: [String]

    public init(objectID: String, text: String, anonymous: Bool, replyObjectID: String?, replyUID: Int?,
        rate: Int? = nil, imageMids: [String] = []) {
        self.objectID = objectID; self.text = text; self.anonymous = anonymous
        self.replyObjectID = replyObjectID; self.replyUID = replyUID
        self.rate = rate; self.imageMids = imageMids
    }
}

public struct CommunityCommentReviewActions {
    public let needsReview: @MainActor (CommunityCommentSubmission) -> Bool
    public let acknowledge: @MainActor (CommunityCommentSubmission) -> Void

    public init(needsReview: @escaping @MainActor (CommunityCommentSubmission) -> Bool,
        acknowledge: @escaping @MainActor (CommunityCommentSubmission) -> Void) {
        self.needsReview = needsReview
        self.acknowledge = acknowledge
    }
}

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
    public var paginationError: String?
    private struct ConfirmedCreation {
        let comment: CommunityComment
        let parent: CommunityComment?
    }
    private var confirmedCreations: [ConfirmedCreation] = []
    private var confirmedDeletions: Set<Int> = []
    private var uncertainSubmissions: Set<CommunityCommentSubmission> = []

    public func needsReview(_ submission: CommunityCommentSubmission) -> Bool {
        uncertainSubmissions.contains(submission)
    }

    public mutating func recordUncertainSubmission(_ submission: CommunityCommentSubmission) {
        uncertainSubmissions.insert(submission)
    }

    public mutating func acknowledgeSubmissionReview(_ submission: CommunityCommentSubmission) {
        uncertainSubmissions.remove(submission)
    }
    public private(set) var likeRevision = 0
    private var likeResults: [Int: (revision: Int, result: CommunityLikeResult)] = [:]
    public private(set) var likesNeedingReview: Set<Int> = []

    public mutating func recordUncertainLike(for commentID: Int) {
        likesNeedingReview.insert(commentID)
        likeResults.removeValue(forKey: commentID)
    }

    public mutating func confirmRead(in comments: [CommunityComment]) {
        var pending = comments
        var readIDs = Set<Int>()
        while let comment = pending.popLast() {
            readIDs.insert(comment.id)
            pending.append(contentsOf: comment.sub)
        }
        likesNeedingReview.subtract(readIDs)
        confirmedCreations.removeAll { readIDs.contains($0.comment.id) }
    }

    public mutating func recordCreated(_ comment: CommunityComment, replyingTo parent: CommunityComment? = nil) {
        confirmedDeletions.remove(comment.id)
        confirmedCreations.removeAll { $0.comment.id == comment.id }
        confirmedCreations.append(.init(comment: comment, parent: parent))
        items = applyingLocalChanges(to: items, since: likeRevision)
        status = .loaded
    }

    public mutating func recordDeleted(_ commentID: Int) {
        confirmedDeletions.insert(commentID)
        confirmedCreations.removeAll { $0.comment.id == commentID || $0.parent?.id == commentID }
        items = applyingLocalChanges(to: items, since: likeRevision)
    }

    public mutating func recordLike(_ result: CommunityLikeResult, for commentID: Int) {
        let previousRevision = likeRevision
        likeRevision &+= 1
        likeResults[commentID] = (likeRevision, result)
        items = applyingLocalChanges(to: items, since: previousRevision)
    }

    public func applyingLocalChanges(to comments: [CommunityComment], since revision: Int) -> [CommunityComment] {
        func retainingComments(_ comments: [CommunityComment]) -> [CommunityComment] {
            comments.filter { !confirmedDeletions.contains($0.id) }.map { comment in
                comment.replacingSubComments(retainingComments(comment.sub))
            }
        }
        var result = confirmedDeletions.isEmpty ? comments : retainingComments(comments)
        for creation in confirmedCreations {
            if let parent = creation.parent {
                let index = result.firstIndex { $0.id == parent.id }
                let current = index.map { result[$0] } ?? parent
                if current.flattenedReplies.contains(where: { $0.id == creation.comment.id }) { continue }
                let replies = current.sub.filter { $0.id != creation.comment.id } + [creation.comment]
                let updated = current.replacingSubComments(replies)
                if let index { result[index] = updated }
                else if order == .newest { result.insert(updated, at: 0) }
                else { result.append(updated) }
            } else if !result.contains(where: { $0.id == creation.comment.id }) {
                if order == .newest { result.insert(creation.comment, at: 0) }
                else { result.append(creation.comment) }
            }
        }
        return applyingLikeChanges(to: result, since: revision).comments
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
        let currentCreations = confirmedCreations
        let currentDeletions = confirmedDeletions
        let currentSubmissions = uncertainSubmissions
        self = previous
        likeResults = currentResults
        likeRevision = currentRevision
        likesNeedingReview = currentPending
        confirmedCreations = currentCreations
        confirmedDeletions = currentDeletions
        uncertainSubmissions = currentSubmissions
        items = applyingLocalChanges(to: items, since: previous.likeRevision)
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
