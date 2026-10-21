import BIT101TestSupport
import CommunityCore
import CommunityPersistence
import Foundation
@testable import GalleryFeature
import StorageCore
import Testing

@MainActor
struct GalleryMessageAvailabilityTests {
    private final class DeferredSummaryService: GalleryMessageServicing {
        var pending: CheckedContinuation<GalleryMessageUnreadCounts, Never>?
        var failure: URLError?
        var delay = true
        var unread = 1
        var cursors: [Int?] = []
        var beforeAcknowledgement: (() -> Void)?

        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts {
            if let failure { throw failure }
            if delay { return await withCheckedContinuation { pending = $0 } }
            return .init(comment: unread)
        }

        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
            cursors.append(lastID)
            if lastID == nil { beforeAcknowledgement?(); unread = 0 }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode([GalleryMessage].self, from: Data(
                #"[{"from_user":{},"id":42,"link_obj":"","obj":"","text":"首屏正文","update_time":""}]"#.utf8))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func historyAppearsWhileInitialAndRetriedUnreadSummariesArePending() async throws {
        let domain = "BIT101Tests.message-availability"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        for retry in [false, true] {
            defaults.removePersistentDomain(forName: domain)
            let files = ModuleScoreFiles()
            let session = AppStorageSession(accountIdentifier: domain)
            let store = GalleryMessageReadStore(files: files, storageRoot: URL(fileURLWithPath: "/message-availability"),
                defaults: defaults, session: { session })
            #expect(await store.replaceLatestIDs([99], unreadCount: 1, for: .comment))
            let original = files.storedData
            let service = DeferredSummaryService()
            service.beforeAcknowledgement = { #expect(store.isUnread(id: 42, for: .comment)) }
            let model = GalleryMessageViewModel(service: service, readStore: store)
            if retry {
                service.failure = URLError(.timedOut)
                await model.refreshUnreadCounts()
                service.failure = nil
            }
            let loading = Task {
                if retry { await model.refreshSelectedType() }
                else { await model.bootstrapIfNeeded() }
            }
            defer {
                loading.cancel()
                service.pending?.resume(returning: .init())
                service.pending = nil
            }
            try await waitForTestEvent { service.pending != nil }
            #expect(model.state(for: .comment).status == .loaded)
            #expect(model.state(for: .comment).items.map(\.id) == [42])
            #expect(service.cursors == [Int.max] && files.storedData == original)
            service.delay = false
            service.pending?.resume(returning: .init(comment: 1))
            service.pending = nil
            await loading.value
            #expect(model.alert == nil && model.unreadCountsFailure == nil)
            #expect(service.cursors.contains(nil))
        }
    }
}
