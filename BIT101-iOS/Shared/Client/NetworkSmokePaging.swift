import Foundation
import CommunityCore
import CommunityTransport
import GalleryFeature

#if DEBUG || RELEASE_NETWORK_SMOKE
@MainActor
enum NetworkSmokePaging {
    static func imageURL(in images: [CommunityImage]) -> String? {
        images.lazy.map { $0.lowUrl.isEmpty ? $0.url : $0.lowUrl }.first { !$0.isEmpty }
    }

    static func arrayPage<Value: Identifiable>(load: (Int) async throws -> [Value]) async throws -> [Value] where Value.ID == Int {
        let identity = AppAccountSession.storage.communityCredentials.identity
        let first = try await load(0)
        try checkIdentity(identity)
        try checkProgress(first: [], next: first.map(\.id))
        let second = try await load(1)
        try checkIdentity(identity)
        try checkProgress(first: first.map(\.id), next: second.map(\.id))
        return first
    }

    static func batch<Value>(load: (Int) async throws -> GalleryPageBatch<Value>) async throws -> GalleryPageBatch<Value> {
        let identity = AppAccountSession.storage.communityCredentials.identity
        let first = try await load(0)
        try checkIdentity(identity)
        try checkProgress(first: [], next: first.sourceIDs)
        guard first.nextSourcePage > 0, !first.canLoadMore || !first.sourceIDs.isEmpty
        else { throw URLError(.cannotParseResponse) }
        let second = try await load(first.nextSourcePage)
        try checkIdentity(identity)
        try checkProgress(first: first.sourceIDs, next: second.sourceIDs)
        guard second.nextSourcePage > first.nextSourcePage, !second.canLoadMore || !second.sourceIDs.isEmpty
        else { throw URLError(.cannotParseResponse) }
        return first
    }

    static func messages(load: (Int?) async throws -> [GalleryMessage]) async throws -> [GalleryMessage] {
        let identity = AppAccountSession.storage.communityCredentials.identity
        let first = try await load(nil)
        try checkIdentity(identity)
        let cursor = first.map(\.id).min() ?? 0
        guard first.isEmpty || cursor > 0 else { throw URLError(.cannotParseResponse) }
        let second = try await load(cursor)
        try checkIdentity(identity)
        guard second.allSatisfy({ $0.id > 0 && $0.id < cursor }) else { throw URLError(.cannotParseResponse) }
        return first
    }

    private static func checkIdentity(_ identity: CommunitySessionIdentity) throws {
        try Task.checkCancellation()
        guard identity == AppAccountSession.storage.communityCredentials.identity else { throw CancellationError() }
    }

    private static func checkProgress(first: [Int], next: [Int]) throws {
        guard next.allSatisfy({ $0 > 0 }), next.isEmpty || !Set(next).subtracting(first).isEmpty
        else { throw URLError(.badServerResponse) }
    }
}
#endif
