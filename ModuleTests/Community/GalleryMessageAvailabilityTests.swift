import BIT101TestSupport
import CommunityCore
import CommunityPersistence
import Foundation
@testable import GalleryFeature
import StorageCore
import Testing

@MainActor
struct GalleryMessageAvailabilityTests {
    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func messagesArrivingDuringConfirmationKeepAContinuousHistory(browseHistory: Bool) async throws {
        let domain = "BIT101Tests.message-page-continuity"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = AppStorageSession(accountIdentifier: domain)
        let store = GalleryMessageReadStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/message-page-continuity"),
            defaults: defaults, session: { account })
        let service = ArrivingMessages()
        let model = GalleryMessageViewModel(service: service, readStore: store)
        service.beforeAcknowledgement = {
            if browseHistory { await model.loadMoreIfNeeded(for: .comment, currentMessage: model.state(for: .comment).items.last) }
            service.identifiers = Array((1...12).reversed())
        }
        await model.refreshUnreadCounts()
        await model.refresh(type: .comment)
        #expect(model.state(for: .comment).items.map(\.id) == (browseHistory ? [12, 11, 6, 5, 4, 3] : [12, 11, 6, 5]))
        for _ in 0...service.identifiers.count {
            guard model.state(for: .comment).canLoadMore else { break }
            await model.loadMoreIfNeeded(for: .comment, currentMessage: model.state(for: .comment).items.last)
        }
        #expect(model.state(for: .comment).items.map(\.id) == Array((1...12).reversed()))
        #expect(!model.state(for: .comment).canLoadMore && store.unreadCount(for: .comment) == 11)
        #expect(service.cursors.filter { $0 == nil }.count == 1)
    }

    @Test func laterMessageWindowsPreserveTheCursorOfAnInFlightPage() throws {
        var state = GalleryMessageListState()
        state.applyFirstCursorPage(try ArrivingMessages.messages([6, 5]))
        state.appendMessagePage(try ArrivingMessages.messages([4, 3]), after: 5)
        state.prependCurrentWindow(try ArrivingMessages.messages([12, 11]))
        state.prependCurrentWindow(try ArrivingMessages.messages([16, 15]))
        state.appendMessagePage(try ArrivingMessages.messages([10, 9]), after: 11)
        #expect(state.nextCursor == 15)
        state.appendMessagePage(try ArrivingMessages.messages([14, 13]), after: 15)
        state.appendMessagePage(try ArrivingMessages.messages([12, 11]), after: 13)
        #expect(state.nextCursor == 9)
        state.appendMessagePage(try ArrivingMessages.messages([8, 7]), after: 9)
        state.appendMessagePage(try ArrivingMessages.messages([6, 5]), after: 7)
        #expect(state.nextCursor == 3)
        state.appendMessagePage(try ArrivingMessages.messages([2, 1]), after: 3)
        state.appendMessagePage([], after: 1)
        #expect(state.items.map(\.id) == Array((1...16).reversed()) && !state.canLoadMore)
    }

    private final class ArrivingMessages: GalleryMessageServicing {
        var identifiers = Array((1...6).reversed())
        var unread = 5
        var cursors: [Int?] = []
        var beforeAcknowledgement: (() async -> Void)?
        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts { .init(comment: unread) }
        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
            cursors.append(lastID)
            if lastID == nil { await beforeAcknowledgement?(); unread = 0 }
            return try Self.messages(Array(identifiers.filter { $0 < (lastID ?? Int.max) }.prefix(2)))
        }
        static func messages(_ ids: [Int]) throws -> [GalleryMessage] {
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode([GalleryMessage].self, from: JSONSerialization.data(withJSONObject: ids.map {
                ["from_user": [:], "id": $0, "link_obj": "", "obj": "", "text": "正文", "update_time": ""] as [String: Any]
            }))
        }
    }

    private final class DeferredSummaryService: GalleryMessageServicing {
        var pending: CheckedContinuation<GalleryMessageUnreadCounts, Never>?
        var failure: URLError?
        var delay = true
        var pageFails = false
        var unread = 1
        var cursors: [Int?] = []
        var beforeAcknowledgement: (() -> Void)?
        var acknowledgementFails = false
        var delayHistory = false
        var pendingHistory: CheckedContinuation<Void, Never>?

        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts {
            if let failure { throw failure }
            if delay { return await withCheckedContinuation { pending = $0 } }
            return .init(comment: unread)
        }

        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
            cursors.append(lastID)
            if lastID == 42, pageFails { throw URLError(.notConnectedToInternet) }
            if lastID == 42, delayHistory { await withCheckedContinuation { pendingHistory = $0 } }
            if lastID == 41 { return [] }
            if lastID == nil {
                if acknowledgementFails { throw URLError(.networkConnectionLost) }
                beforeAcknowledgement?(); unread = 0
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let id = lastID == 42 ? 41 : 42
            return try decoder.decode([GalleryMessage].self, from: Data(
                #"[{"from_user":{},"id":\#(id),"link_obj":"","obj":"","text":"首屏正文","update_time":""}]"#.utf8))
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func readingDuringUnreadRecoveryPreservesHistoryAndReadIntent(markAll: Bool) async throws {
        let domain = "BIT101Tests.message-active-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = AppStorageSession(accountIdentifier: domain)
        let files = ModuleScoreFiles(), root = URL(fileURLWithPath: "/message-active-recovery")
        let store = GalleryMessageReadStore(files: files, storageRoot: root,
            defaults: defaults, session: { account })
        let service = DeferredSummaryService()
        service.delay = false; service.unread = 2
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        if markAll { service.delayHistory = true } else { service.delay = true }
        let refresh = Task { await model.refreshSelectedType() }
        try await waitForTestEvent { markAll ? service.pendingHistory != nil : service.pending != nil }
        if markAll {
            await model.markCurrentTypeAsRead()
            service.delayHistory = false
            service.pendingHistory?.resume(); service.pendingHistory = nil
        } else {
            #expect(model.state(for: .comment).isLoadingMore == false)
            await model.loadMoreIfNeeded(for: .comment, currentMessage: model.state(for: .comment).items.last)
            #expect(model.state(for: .comment).items.map(\.id) == [42, 41])
            service.delay = false
            service.pending?.resume(returning: .init(comment: 2)); service.pending = nil
        }
        await refresh.value
        if markAll {
            #expect(store.unreadCount(for: .comment) == 0 && !store.isUnread(id: 41, for: .comment))
            let reopened = GalleryMessageReadStore(files: files, storageRoot: root, defaults: defaults, session: { account })
            #expect(await reopened.prepareSnapshot())
            #expect(!reopened.isUnread(id: 41, for: .comment) && !reopened.isUnread(id: 42, for: .comment))
            #expect(await store.replaceLatestIDs([43], unreadCount: 1, for: .comment))
            #expect(store.isUnread(id: 43, for: .comment))
        } else {
            #expect(model.state(for: .comment).items.map(\.id) == [42, 41])
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: ["{}", "{\"schemaVersion\":999,\"latestIDsByType\":{},\"seenIDsByType\":{}}"])
    func invalidMessageDocumentsStayIntactUntilRecovery(document: String) async throws {
        let domain = "BIT101Tests.message-document-contract"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = AppStorageSession(accountIdentifier: domain)
        let root = URL(fileURLWithPath: "/message-document-contract"), files = ModuleScoreFiles()
        let path = root.appending(path: account.accountStorageIdentifier).appending(path: "message-read-snapshot.json")
        let original = Data(document.utf8)
        try files.writeData(original, to: path, options: [])
        let store = GalleryMessageReadStore(files: files, storageRoot: root, defaults: defaults, session: { account })
        #expect(await store.prepareSnapshot() == false && store.hasUnreadableSnapshot)
        #expect(await store.markSeen(ids: [42], for: .comment) == false)
        #expect(files.storedData[path].map { String(decoding: $0, as: UTF8.self) } == document)
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: ["summary", "acknowledgement"])
    func automaticRecoveryFinishesTheFailedMessageConfirmation(stage: String) async throws {
        let domain = "BIT101Tests.message-automatic-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = AppStorageSession(accountIdentifier: domain)
        let store = GalleryMessageReadStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/message-auto-recovery"),
            defaults: defaults, session: { account })
        let service = DeferredSummaryService()
        service.delay = false
        if stage == "summary" { service.failure = URLError(.notConnectedToInternet) }
        else { service.acknowledgementFails = true }
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshSelectedType()
        #expect(model.state(for: .comment).status == .loaded && model.state(for: .comment).items.map(\.id) == [42])
        let underlying = try #require(model.alert?.underlyingError as? URLError)
        #expect(underlying.code == (stage == "summary" ? .notConnectedToInternet : .networkConnectionLost))
        let previousRequests = service.cursors.count
        service.failure = nil
        service.acknowledgementFails = false
        await model.retrySelectedTypeIfNeeded()
        #expect(model.unreadCountsFailure == nil && service.cursors.contains(nil))
        #expect(service.cursors.count > previousRequests && service.unread == 0)
        let recoveredRequests = service.cursors.count
        await model.retrySelectedTypeIfNeeded()
        #expect(service.cursors.count == recoveredRequests)
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func confirmedMessageRecoveryKeepsOtherAccountsAndResumesReadUpdates(legacyOnly: Bool) async throws {
        let domain = "BIT101Tests.message-storage-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = AppStorageSession(accountIdentifier: "message-A"), second = AppStorageSession(accountIdentifier: "message-B")
        var current = first
        let files = ModuleScoreFiles(), root = URL(fileURLWithPath: "/message-storage-recovery")
        let firstURL = root.appending(path: first.accountStorageIdentifier).appending(path: "message-read-snapshot.json")
        let secondURL = root.appending(path: second.accountStorageIdentifier).appending(path: "message-read-snapshot.json")
        let original = Data("{damaged".utf8), unrelated = Data("other account".utf8)
        if legacyOnly { defaults.set(7, forKey: first.key("gallery.message.read.snapshot")) }
        else { try files.writeData(original, to: firstURL, options: []) }
        try files.writeData(unrelated, to: secondURL, options: [])
        defaults.set("other setting", forKey: "unrelated.setting")
        let store = GalleryMessageReadStore(files: files, storageRoot: root, defaults: defaults, session: { current })
        #expect(await store.prepareSnapshot() == false && store.hasUnreadableSnapshot)
        #expect(await store.markSeen(ids: [42], for: .comment) == false)
        if !legacyOnly { #expect(files.storedData[firstURL] == original) }
        let service = DeferredSummaryService(); service.delay = false; service.unread = 0
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshSelectedType()
        #expect(model.alert != nil)
        model.alert = nil
        let requests = service.cursors.count
        await model.retrySelectedTypeIfNeeded()
        #expect(model.alert == nil && service.cursors.count == requests)
        let staleConfirmation = model.readStateRecoveryAction()
        current = second
        await staleConfirmation()
        #expect(files.storedData[secondURL] == unrelated)
        current = first
        files.setFailures(writing: true)
        await model.readStateRecoveryAction()()
        #expect(model.needsReadStateRecovery && model.alert != nil)
        if !legacyOnly { #expect(files.storedData[firstURL] == original) }
        files.setFailures()
        await model.readStateRecoveryAction()()
        #expect(!store.hasUnreadableSnapshot && !model.needsReadStateRecovery)
        #expect(await store.markSeen(ids: [42], for: .comment))
        let saved = try JSONDecoder().decode(GalleryMessageReadSnapshot.self, from: #require(files.storedData[firstURL]))
        #expect(saved.seenIDsByType[GalleryMessageType.comment.rawValue] == [42])
        #expect(files.storedData[secondURL] == unrelated && defaults.string(forKey: "unrelated.setting") == "other setting")
        #expect(defaults.object(forKey: first.key("gallery.message.read.snapshot")) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func failedMessagePageRemainsAvailableForAnInPlaceRetry() async throws {
        let domain = "BIT101Tests.message-pagination"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let store = GalleryMessageReadStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/message-pagination"),
            defaults: defaults, session: { session })
        let service = DeferredSummaryService()
        service.delay = false; service.unread = 0
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshSelectedType()
        await model.refresh(type: .like)
        #expect(model.paginationTaskID(for: .comment) != model.paginationTaskID(for: .like))
        service.pageFails = true
        await model.loadMoreIfNeeded(for: .comment, currentMessage: model.state(for: .comment).items.last)
        let failed = model.state(for: .comment)
        #expect(failed.items.map(\.id) == [42] && failed.nextCursor == 42 && failed.paginationError != nil)
        await model.refreshSelectedType()
        #expect(model.state(for: .comment).paginationError == nil)
        await model.loadMoreIfNeeded(for: .comment, currentMessage: model.state(for: .comment).items.last)
        #expect(model.state(for: .comment).paginationError != nil)
        service.pageFails = false
        await model.loadMoreIfNeeded(for: .comment, currentMessage: failed.items.last)
        #expect(model.state(for: .comment).items.map(\.id) == [42, 41] && model.state(for: .comment).paginationError == nil)
        await model.loadMoreIfNeeded(for: .comment, currentMessage: model.state(for: .comment).items.last)
        #expect(model.state(for: .comment).canLoadMore == false)
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
