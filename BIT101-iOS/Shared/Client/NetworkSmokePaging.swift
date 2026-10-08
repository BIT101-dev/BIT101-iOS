import Foundation
import CommunityCore
import CommunityTransport
import GalleryFeature

#if DEBUG || RELEASE_NETWORK_SMOKE
@MainActor
enum NetworkSmokePaging {
    static func arrayPage<Value: Identifiable>(load: (Int) async throws -> [Value]) async throws -> [Value] where Value.ID == Int {
        let identity = AppAccountSession.storage.communityCredentials.identity
        let first = try await load(0)
        try checkIdentity(identity)
        guard first.allSatisfy({ $0.id > 0 }) else { throw URLError(.cannotParseResponse) }
        if !first.isEmpty {
            let second = try await load(1)
            try checkIdentity(identity)
            guard second.allSatisfy({ $0.id > 0 }) else { throw URLError(.cannotParseResponse) }
        }
        return first
    }

    static func batch<Value>(load: (Int) async throws -> GalleryPageBatch<Value>) async throws -> GalleryPageBatch<Value> {
        let identity = AppAccountSession.storage.communityCredentials.identity
        let first = try await load(0)
        try checkIdentity(identity)
        guard first.nextSourcePage > 0 else { throw URLError(.cannotParseResponse) }
        if first.canLoadMore {
            let second = try await load(first.nextSourcePage)
            try checkIdentity(identity)
            guard second.nextSourcePage > first.nextSourcePage else { throw URLError(.cannotParseResponse) }
        }
        return first
    }

    static func messages(load: (Int?) async throws -> [GalleryMessage]) async throws -> [GalleryMessage] {
        let identity = AppAccountSession.storage.communityCredentials.identity
        let first = try await load(nil)
        try checkIdentity(identity)
        if let cursor = first.map(\.id).min() {
            guard cursor > 0 else { throw URLError(.cannotParseResponse) }
            let second = try await load(cursor)
            try checkIdentity(identity)
            guard second.allSatisfy({ $0.id > 0 && $0.id < cursor }) else { throw URLError(.cannotParseResponse) }
        }
        return first
    }

    private static func checkIdentity(_ identity: CommunitySessionIdentity) throws {
        try Task.checkCancellation()
        guard identity == AppAccountSession.storage.communityCredentials.identity else { throw CancellationError() }
    }
}
#endif
