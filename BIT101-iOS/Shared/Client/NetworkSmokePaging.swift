import Foundation
import CommunityCore
import CommunityTransport
import GalleryFeature
import ScoreDomain

#if DEBUG || RELEASE_NETWORK_SMOKE
@MainActor
enum NetworkSmokePaging {
    static func imageURL(in images: [CommunityImage]) -> String? {
        images.lazy.map { $0.lowUrl.isEmpty ? $0.url : $0.lowUrl }.first { !$0.isEmpty }
    }

    static func arrayPage<Value: Identifiable>(requiresContent: Bool = false, load: (Int) async throws -> [Value]) async throws -> [Value] where Value.ID == Int {
        let identity = AppAccountSession.storage.communityCredentials.identity
        let first = try await load(0)
        guard !requiresContent || !first.isEmpty else { throw URLError(.cannotParseResponse) }
        try checkIdentity(identity)
        try checkIDs(first.map(\.id))
        var sampled = CommunityPagedItems<Value>()
        sampled.replace(with: first)
        var progress = CommunityPageProgress<Int>(knownIDs: sampled.ids)
        var page = 1
        while true {
            let next = try await load(page)
            try checkIdentity(identity)
            let ids = next.map(\.id)
            try checkIDs(ids)
            try progress.record(ids)
            let advances = !Set(ids).subtracting(sampled.ids).isEmpty
            sampled.append(next)
            if ids.isEmpty || advances { return sampled.items }
            page += 1
        }
    }

    static func checkScores(brief: [ScoreRow], detailed: [ScoreRow]) throws {
        guard brief.isEmpty && detailed.isEmpty || ScoreRowComparison.briefRowsMatchCache(brief, cachedRows: detailed)
        else { throw URLError(.cannotParseResponse) }
    }

    static func batch<Value: Identifiable>(load: (Int) async throws -> GalleryPageBatch<Value>) async throws -> GalleryPageBatch<Value> where Value.ID == Int {
        let identity = AppAccountSession.storage.communityCredentials.identity
        let first = try await load(0)
        try checkIdentity(identity)
        try checkIDs(first.sourceIDs)
        guard first.nextSourcePage > 0, !first.canLoadMore || !first.sourceIDs.isEmpty
        else { throw URLError(.cannotParseResponse) }
        var sampled = CommunityPagedItems<Value>()
        sampled.replace(with: first.items)
        var sourceIDs = Set(first.sourceIDs)
        var progress = CommunityPageProgress<Int>(knownIDs: sourceIDs)
        var page = first.nextSourcePage
        while true {
            let next = try await load(page)
            try checkIdentity(identity)
            try checkIDs(next.sourceIDs)
            guard next.nextSourcePage > page, !next.canLoadMore || !next.sourceIDs.isEmpty
            else { throw URLError(.cannotParseResponse) }
            try progress.record(next.sourceIDs)
            let advances = !Set(next.sourceIDs).subtracting(sourceIDs).isEmpty
            sampled.append(next.items)
            sourceIDs.formUnion(next.sourceIDs)
            if !next.canLoadMore || advances {
                return .init(items: sampled.items, nextSourcePage: next.nextSourcePage,
                    canLoadMore: next.canLoadMore, sourceIDs: sourceIDs.sorted())
            }
            page = next.nextSourcePage
        }
    }

    static func messages(load: (Int?) async throws -> [GalleryMessage]) async throws -> [GalleryMessage] {
        let identity = AppAccountSession.storage.communityCredentials.identity
        let first = try await load(Int.max)
        try checkIdentity(identity)
        guard zip(first, first.dropFirst()).allSatisfy({ $0.id >= $1.id }) else { throw URLError(.cannotParseResponse) }
        let cursor = first.last?.id ?? 1
        guard cursor > 0 else { throw URLError(.cannotParseResponse) }
        let second = try await load(cursor)
        try checkIdentity(identity)
        guard second.allSatisfy({ $0.id > 0 && $0.id < cursor }),
              zip(second, second.dropFirst()).allSatisfy({ $0.id >= $1.id }) else { throw URLError(.cannotParseResponse) }
        return first
    }

    private static func checkIdentity(_ identity: CommunitySessionIdentity) throws {
        try Task.checkCancellation()
        guard identity == AppAccountSession.storage.communityCredentials.identity else { throw CancellationError() }
    }

    private static func checkIDs(_ ids: [Int]) throws {
        guard ids.allSatisfy({ $0 > 0 })
        else { throw URLError(.badServerResponse) }
    }

    static func checkComments(_ comments: [CommunityComment], for objectID: String) throws {
        guard comments.allSatisfy({ $0.obj == objectID }) else { throw URLError(.badServerResponse) }
    }

    static func checkPosters(_ posters: [CommunityPoster], for userID: Int) throws {
        guard userID > 0, posters.allSatisfy({ $0.user.id == userID }) else { throw URLError(.badServerResponse) }
    }
}
#endif
