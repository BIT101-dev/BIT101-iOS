import CommunityCore
import DesignSystemKit

/// 社区评论共用提交对象、定向回复和作者展示规则。
public nonisolated enum CommunityCommentComposerTarget: Identifiable, Equatable, Sendable {
    case poster(posterID: Int)
    case course(courseID: Int)
    case paper(paperID: Int)
    case comment(mainComment: CommunityComment, targetComment: CommunityComment)

    public var id: String {
        switch self {
        case .poster(let id): "poster-\(id)"
        case .course(let id): "course-\(id)"
        case .paper(let id): "paper-\(id)"
        case .comment(let main, let target): "comment-\(main.id)-\(target.id)"
        }
    }

    public var title: String {
        if case .comment(_, let target) = self {
            return
                "回复 @\(target.anonymous ? AppUserPresentation.anonymousName : target.user.nickname)"
        }
        return "发表评论"
    }

    public var placeholder: String {
        if case .comment = self { return title }
        return "写点什么吧"
    }

    public var objectID: String {
        switch self {
        case .poster(let id): "poster\(id)"
        case .course(let id): "course\(id)"
        case .paper(let id): "paper\(id)"
        case .comment(let main, _): "comment\(main.id)"
        }
    }

    public var replyObjectID: String? {
        guard case .comment(let main, let target) = self, main.id != target.id else { return nil }
        return "comment\(target.id)"
    }

    public var replyUID: Int? {
        guard case .comment(let main, let target) = self, main.id != target.id, target.user.id != 0
        else { return nil }
        return target.user.id
    }
}
