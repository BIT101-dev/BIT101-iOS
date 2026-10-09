import CommunityCore
import Foundation

@MainActor
final class ListRequestGate<Value: Sendable> {
    private var result: CheckedContinuation<Value, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func request() async -> Value {
        await withCheckedContinuation {
            result = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilRequested() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ value: Value) { result?.resume(returning: value); result = nil }
}

@MainActor
func listUser(_ id: Int) -> CommunityUser {
    CommunityUser(id: id, createTime: "", nickname: "用户\(id)",
        avatar: CommunityImage(mid: "", url: "", lowUrl: ""), motto: "",
        identity: CommunityIdentity(id: 0, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
}

@MainActor
func listPoster(_ id: Int) -> CommunityPoster {
    CommunityPoster(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0,
        createTime: "", editTime: "", id: id, images: [], likeNum: 0, public: true,
        tags: [], text: "正文", title: "帖子\(id)", updateTime: "", user: listUser(id))
}
