import BIT101TestSupport
import CommunityCore
import Foundation

@MainActor
final class ListRequestGate<Value: Sendable> {
    private var requests: [CheckedContinuation<Value, any Error>] = []
    private var timeoutTask: Task<Void, Never>?
    private let timeout: Duration
    init(timeout: Duration = .seconds(5)) { self.timeout = timeout }
    func request() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            if timeoutTask == nil {
                timeoutTask = Task { [weak self, timeout = self.timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.complete(.failure(URLError(.timedOut)))
                }
            }
        }
    }
    func waitUntilRequested(count: Int = 1) async throws {
        try await waitForTestEvent { requests.count >= count }
    }
    func finish(_ value: Value) { complete(.success(value)) }
    private func complete(_ value: Result<Value, any Error>) {
        let pending = requests
        requests.removeAll()
        timeoutTask?.cancel()
        timeoutTask = nil
        for request in pending { request.resume(with: value) }
    }
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
