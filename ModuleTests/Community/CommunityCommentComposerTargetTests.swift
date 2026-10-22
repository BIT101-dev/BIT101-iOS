import CommunityCore
import CommunityUI
import Testing

@MainActor
struct CommunityCommentComposerTargetTests {
    @Test(arguments: [-1, 0, 7])
    func commentTargetsShareRootAndDirectedReplyRules(userID: Int) {
        let user = CommunityUser.placeholder(id: userID, nickname: "作者")
        func comment(_ id: Int) -> CommunityComment {
            .init(id: id, obj: "paper1", images: [], user: user, anonymous: false, createTime: "", updateTime: "",
                like: false, likeNum: 0, commentNum: 0, own: false, rate: 0, replyUser: user, replyObj: "", text: "", sub: [])
        }
        let roots: [(CommunityCommentComposerTarget, String)] = [(.poster(posterID: 1), "poster"),
            (.course(courseID: 1), "course"), (.paper(paperID: 1), "paper")]
        for (target, kind) in roots {
            #expect(target.id == "\(kind)-1" && target.objectID == "\(kind)1")
            #expect(target.replyObjectID == nil && target.replyUID == nil)
            #expect(target.title == "发表评论" && target.placeholder == "写点什么吧")
        }
        let root = CommunityCommentComposerTarget.comment(mainComment: comment(1), targetComment: comment(1))
        let reply = CommunityCommentComposerTarget.comment(mainComment: comment(1), targetComment: comment(2))
        #expect(root.id == "comment-1-1" && reply.id == "comment-1-2")
        #expect(root.objectID == "comment1" && root.replyObjectID == nil && root.replyUID == nil)
        #expect(reply.objectID == "comment1" && reply.replyObjectID == "comment2")
        #expect(reply.replyUID == (userID == 0 ? nil : userID))
    }
}
