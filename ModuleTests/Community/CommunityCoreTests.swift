import BIT101TestSupport
import Combine
import CommunityCore
import CommunityPersistence
import CommunityUI
import Foundation
import StorageCore
import Testing
import os

@MainActor
struct CommunityCoreTests {
    @Test func uncertainCommentsRetainTheirOwnRefresh() {
        let first = CommunityCommentSubmission(
            objectID: "paper1", text: "评论", anonymous: false,
            replyObjectID: nil, replyUID: nil)
        let other = CommunityCommentSubmission(
            objectID: "paper1", text: "另一条评论", anonymous: false,
            replyObjectID: nil, replyUID: nil)
        var state = CommunityCommentState()
        let previous = state
        state.recordUncertainSubmission(first)
        state.restoreFailedRefresh(previous)
        #expect(state.needsReview(first) && state.needsReview(other) == false)
        state.recordUncertainSubmission(other)
        state.confirmSubmissionReview(first)
        #expect(state.needsReview(first) == false && state.needsReview(other))
    }

    @Test(arguments: [false, true])
    func confirmedCommentsSurviveStaleReads(reply: Bool) {
        let user = CommunityUser.placeholder(id: 1, nickname: "作者")
        func comment(_ id: Int, sub: [CommunityComment] = []) -> CommunityComment {
            CommunityComment(
                id: id, obj: "paper1", images: [], user: user, anonymous: false,
                createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: sub.count,
                own: true, rate: 0, replyUser: user, replyObj: "", text: "评论\(id)", sub: sub)
        }
        let parent = comment(1)
        let created = comment(2)
        var state = CommunityCommentState()
        state.applyFirstPage([parent])
        let previous = state
        state.recordCreated(created, replyingTo: reply ? parent : nil)
        state.confirmRead(in: [])
        state.applyFirstPage(state.applyingLocalChanges(to: [], since: 0))
        state.restoreFailedRefresh(previous, failureStatus: .failed("offline"))
        let visible = state.items + state.items.flatMap(\.flattenedReplies)
        #expect(visible.contains(where: { $0.id == created.id }) && state.status == .loaded)
        let server = reply ? [comment(1, sub: [created])] : [created]
        state.confirmRead(in: server)
        state.applyFirstPage(state.applyingLocalChanges(to: server, since: 0))
        #expect(
            (state.items + state.items.flatMap(\.flattenedReplies)).filter { $0.id == created.id }
                .count == 1)
        state.recordDeleted(created.id)
        state.applyFirstPage(state.applyingLocalChanges(to: server, since: 0))
        #expect(
            (state.items + state.items.flatMap(\.flattenedReplies)).contains { $0.id == created.id }
                == false)
        state.applyFirstPage(state.applyingLocalChanges(to: [], since: 0))
        #expect(state.items.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func detailExitCancelsEveryOwnedRequest() async throws {
        let tasks = CommunityDetailTasks()
        var started = 0
        var cancelled = 0
        func operation() async {
            started += 1
            do { try await Task.sleep(for: .seconds(30)) } catch {
                if Task.isCancelled { cancelled += 1 }
            }
        }
        let first = tasks.enqueue { await operation() }
        let second = tasks.enqueue { await operation() }
        try await waitForTestEvent { started == 2 }
        tasks.cancel()
        await first.value
        await second.value
        #expect(cancelled == 2)
        var reentered = false
        await tasks.enqueue { reentered = true }.value
        #expect(reentered)
        var owner: CommunityDetailTasks? = CommunityDetailTasks()
        let released = try #require(owner).enqueue { await operation() }
        try await waitForTestEvent { started == 3 }
        owner = nil
        await released.value
        #expect(cancelled == 3)
    }

    @Test func commentRepliesFlattenOrder() {
        let user = CommunityUser.placeholder(id: 1, nickname: "作者")
        func comment(_ id: Int, sub: [CommunityComment] = []) -> CommunityComment {
            .init(
                id: id, obj: "poster1", images: [], user: user, anonymous: false, createTime: "",
                updateTime: "",
                like: false, likeNum: 0, commentNum: 0, own: false, rate: 0, replyUser: user,
                replyObj: "",
                text: String(id), sub: sub)
        }
        let root = comment(
            1,
            sub: [comment(2, sub: [comment(3, sub: [comment(4)])]), comment(5, sub: [comment(6)])])
        #expect(root.flattenedReplies.map(\.id) == [2, 3, 4, 5, 6])
        #expect(root.sub.map(\.id) == [2, 5] && comment(7).flattenedReplies.isEmpty)
        var state = CommunityCommentState()
        state.items = [root, comment(7)]
        state.recordLike(.init(like: true, likeNum: 3), for: 4)
        #expect(state.items[0].flattenedReplies.first { $0.id == 4 }?.likeNum == 3)
        #expect(state.items[0].sub[1] == root.sub[1] && state.items[1] == comment(7))
        #expect(state.applyingLocalChanges(to: [root], since: state.likeRevision) == [root])
        #expect(state.applyingLocalChanges(to: [root], since: 0) == [state.items[0]])
    }

    @Test func displayBudgetsRetainValidMultibyteText() {
        for text in [
            String(repeating: "A", count: 100_000), String(repeating: "中", count: 100_000),
            String(repeating: "👨‍👩‍👧‍👦é", count: 10_000),
        ] {
            let preview = CommunityTextLimits.displayText(text, preview: true)
            let full = CommunityTextLimits.displayText(text)
            #expect(
                preview.utf8.count <= CommunityTextLimits.maximumPreviewBytes
                    && preview.hasSuffix("…"))
            #expect(
                full.utf8.count <= CommunityTextLimits.maximumDisplayBytes && full.hasSuffix("…"))
            #expect(String(data: Data(preview.utf8), encoding: .utf8) == preview)
            #expect(text.utf8.count > CommunityTextLimits.maximumDisplayBytes)
            #expect(CommunityTextLimits.requiresFullReading(text))
        }
        let boundary = String(repeating: "A", count: CommunityTextLimits.maximumPreviewBytes)
        #expect(CommunityTextLimits.displayText(boundary, preview: true) == boundary)
        #expect(
            !CommunityTextLimits.requiresFullReading(
                String(repeating: "A", count: CommunityTextLimits.maximumDisplayBytes)))
    }

    @Test(arguments: [("e\u{0301}", 1), ("🇨🇳", 4), ("👨‍👩‍👧‍👦", 4)])
    func displayBudgetsKeepBoundary(character: String, partialBytes: Int) {
        let prefix = String(
            repeating: "A", count: CommunityTextLimits.maximumPreviewBytes - 3 - partialBytes)
        #expect(
            CommunityTextLimits.displayText(prefix + character + "long tail", preview: true)
                == prefix + "…")
    }

    @Test(.timeLimit(.minutes(1))) func unreadCandidatesSurviveNewNoticesReads() async throws {
        let domain = "BIT101ModulesTests.unread-candidates"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "unread-candidates")
        let files = ModuleScoreFiles()
        let store = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { session })
        #expect(store.syncSnapshot().seenIDsByType.isEmpty)
        await store.replaceLatestIDs([5, 4, 3], unreadCount: 3, for: .comment)
        await store.markSeen(ids: [4], for: .comment)
        await store.replaceLatestIDs([6, 5], unreadCount: 1, for: .comment)
        let reopened = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { session })
        await reopened.prepareSnapshot()
        #expect(reopened.unreadCount(for: .comment) == 3)
        #expect(reopened.isUnread(id: 3, for: .comment))
        #expect(!reopened.isUnread(id: 4, for: .comment))
        await reopened.replaceLatestIDs([], unreadCount: 0, for: .comment)
        #expect(reopened.unreadCount(for: .comment) == 3)
        await reopened.replaceLatestIDs(Array(1...2_000), unreadCount: 2_000, for: .like)
        #expect(reopened.unreadCount(for: .like) == 2_000)
        defaults.removePersistentDomain(forName: domain)
        let recovered = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { session })
        await recovered.prepareSnapshot()
        #expect(recovered.unreadCount(for: .like) == 2_000)
        #expect(await recovered.markSeen(ids: Array(1_001...2_000), for: .like))
        #expect(recovered.isUnread(id: 1, for: .like) && recovered.unreadCount(for: .like) == 1_000)
        #expect(await recovered.markSeen(ids: [1], for: .like))
        #expect(!recovered.isUnread(id: 1, for: .like))
    }

    @Test(.timeLimit(.minutes(1)), .serialized, arguments: [false, true])
    func failedMessageCheckpointPreservesFile(protection: Bool) async throws {
        let domain = "BIT101ModulesTests.message-checkpoint"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let files = ModuleScoreFiles()
        let root = URL(fileURLWithPath: "/messages")
        let store = GalleryMessageReadStore(
            files: files, storageRoot: root, defaults: defaults, session: { session })
        #expect(await store.replaceLatestIDs([42], unreadCount: 1, for: .comment))
        let before = files.storedData
        files.setFailures(writing: true)
        #expect(!(await store.setPendingUnreadAfterID(42, for: .comment)))
        #expect(files.storedData == before)
        let reopened = GalleryMessageReadStore(
            files: files, storageRoot: root, defaults: defaults, session: { session })
        await reopened.prepareSnapshot()
        #expect(
            reopened.pendingUnreadAfterID(for: .comment) == nil
                && reopened.isUnread(id: 42, for: .comment))
        files.setFailures(reading: !protection, protection: protection)
        let recovering = GalleryMessageReadStore(
            files: files, storageRoot: root, defaults: defaults, session: { session })
        await recovering.prepareSnapshot()
        #expect(recovering.hasUnreadableSnapshot)
        #expect(!(await recovering.setPendingUnreadAfterID(42, for: .comment)))
        #expect(files.storedData == before)
        files.setFailures()
        await recovering.prepareSnapshot()
        #expect(!recovering.hasUnreadableSnapshot && recovering.isUnread(id: 42, for: .comment))
        #expect(await recovering.setPendingUnreadAfterID(42, for: .comment))
        #expect(recovering.pendingUnreadAfterID(for: .comment) == 42)
        #expect(
            recovering.isUnread(id: 43, for: .comment)
                && !recovering.isUnread(id: 41, for: .comment))
        #expect(await recovering.markSeen(ids: [43], for: .comment))
        #expect(
            !recovering.isUnread(id: 43, for: .comment)
                && recovering.isUnread(id: 44, for: .comment))
    }

    @Test(.timeLimit(.minutes(1))) func damagedMessageReadStatePreservesBytes() async throws {
        let domain = "BIT101ModulesTests.message-corruption"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "message-corruption")
        let files = ModuleScoreFiles()
        let store = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { session })
        let key = session.key("gallery.message.read.snapshot")
        let damaged = Data("damaged".utf8)
        defaults.set(damaged, forKey: key)
        await store.prepareSnapshot()
        #expect(store.hasUnreadableSnapshot)
        var saves = 0
        let subscription = store.localSaves.sink { _ in saves += 1 }
        #expect(!(await store.markSeen(ids: [1], for: .comment)))
        #expect(!(await store.replaceLatestIDs([1, 2], unreadCount: 2, for: .comment)))
        var remote = GalleryMessageReadSnapshot()
        remote.seenIDsByType = ["comment": [3]]
        await store.applySyncedSnapshot(remote)
        #expect(defaults.data(forKey: key) == damaged)
        #expect(saves == 0)
        let file = URL(fileURLWithPath: "/messages").appending(
            path: session.accountStorageIdentifier
        )
        .appending(path: "message-read-snapshot.json")
        let reads = files.readCount(at: file)
        for type in GalleryMessageType.allCases {
            #expect(store.unreadCount(for: type) == 0 && !store.isUnread(id: 1, for: type))
        }
        #expect(files.readCount(at: file) == reads)
        #expect(store.unreadCount(for: .comment) == 0)
        subscription.cancel()
    }

    @Test(.timeLimit(.minutes(1))) func messageReadHistoryStaysBounded() async throws {
        let domain = "BIT101ModulesTests.message-history"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = AppStorageSession(accountIdentifier: "history")
        let files = ModuleScoreFiles()
        let store = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { account })
        await store.replaceLatestIDs([1, 10_000, 10_001], unreadCount: 3, for: .comment)
        await store.markSeen(ids: Array(1...10_000), for: .comment)
        let snapshot = store.syncSnapshot()
        #expect(
            snapshot.seenIDsByType["comment"]?.count
                == GalleryMessageReadSnapshot.maximumHistoryIDsPerType)
        #expect(snapshot.retainedFromIDByType["comment"] == 8_977)
        #expect(store.unreadCount(for: .comment) == 1)
        #expect(!store.isUnread(id: 1, for: .comment))
        #expect(store.isUnread(id: 10_001, for: .comment))
        #expect(await store.replaceLatestIDs([1, 8_976, 10_001], unreadCount: 3, for: .comment))
        #expect(store.unreadCount(for: .comment) == 1 && !store.isUnread(id: 1, for: .comment))
        #expect(!store.isUnread(id: 8_976, for: .comment))
        let reopened = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { account })
        await reopened.prepareSnapshot()
        #expect(reopened.syncSnapshot() == snapshot)
        await reopened.markSeen(ids: [10_001], for: .comment)
        await store.prepareSnapshot()
        #expect(store.unreadCount(for: .comment) == 0)
        var older = GalleryMessageReadSnapshot()
        older.seenIDsByType = ["comment": [1, 2, 10_002]]
        let forward = snapshot.mergingReadState(older)
        let backward = older.mergingReadState(snapshot)
        #expect(forward.seenIDsByType == backward.seenIDsByType)
        #expect(forward.retainedFromIDByType == backward.retainedFromIDByType)
        #expect(
            forward.seenIDsByType["comment"]?.count
                == GalleryMessageReadSnapshot.maximumHistoryIDsPerType)
        #expect(forward.retainedFromIDByType["comment"] == 8_978)
        let legacy = try JSONDecoder().decode(
            GalleryMessageReadSnapshot.self,
            from: Data(#"{"latestIDsByType":{"comment":[1]},"seenIDsByType":{"comment":[1]}}"#.utf8)
        )
        #expect(legacy.retainedFromIDByType.isEmpty)
        #expect(legacy.seenIDsByType["comment"] == [1])
        let document =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        #expect(
            document?["schemaVersion"] as? Int == GalleryMessageReadSnapshot.currentSchemaVersion)
        #expect(await store.replaceLatestIDs([10_002, 10_003], unreadCount: 2, for: .comment))
        var remote = GalleryMessageReadSnapshot()
        remote.retainedFromIDByType["comment"] = 10_003
        #expect(await store.applySyncedSnapshot(remote))
        #expect(store.unreadCount(for: .comment) == 1 && !store.isUnread(id: 10_002, for: .comment))
        #expect(await store.replaceLatestIDs([1, 10_002, 10_003], unreadCount: 3, for: .comment))
        #expect(store.unreadCount(for: .comment) == 1 && store.isUnread(id: 10_003, for: .comment))
    }

    @Test(.timeLimit(.minutes(1))) func messageStorageSeparatesAccountUploads() async throws {
        let domain = "BIT101ModulesTests.message-storage"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "messages")
        let files = ModuleScoreFiles()
        let store = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { session })
        let other = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { session })
        await other.prepareSnapshot()
        var changes: [AppStorageSession] = []
        var uploads: [AppStorageSession] = []
        var otherChanges: [AppStorageSession] = []
        let subscriptions = [
            store.changes.sink { changes.append($0) },
            store.localSaves.sink { uploads.append($0) },
            other.changes.sink { otherChanges.append($0) },
        ]
        await store.replaceLatestIDs([42], unreadCount: 1, for: .comment)
        #expect(uploads == [session])
        #expect(changes == [session])
        var remote = GalleryMessageReadSnapshot()
        remote.latestIDsByType = ["comment": [42]]
        remote.seenIDsByType = ["comment": [42]]
        await store.applySyncedSnapshot(remote)
        #expect(store.unreadCount(for: .comment) == 0)
        #expect(changes == [session, session])
        #expect(uploads == [session])
        #expect(otherChanges.isEmpty)
        let revisionKey = session.key("gallery.message.read.snapshot") + ".revision"
        let revision = defaults.integer(forKey: revisionKey)
        let bytes = files.storedData
        #expect(await store.markSeen(ids: [42, 42], for: .comment))
        #expect(defaults.integer(forKey: revisionKey) == revision && files.storedData == bytes)
        #expect(changes == [session, session] && uploads == [session])
        withExtendedLifetime(subscriptions) {}
    }

    @Test(.timeLimit(.minutes(1))) func unreadQueriesRefreshWrites() async throws {
        let domain = "BIT101ModulesTests.unread-query-index"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        var session = AppStorageSession(accountIdentifier: "A")
        let files = ModuleScoreFiles()
        let store = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { session })
        let external = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { session })
        #expect(await store.replaceLatestIDs([42, 43], unreadCount: 2, for: .comment))
        #expect(store.isUnread(id: 42, for: .comment))
        #expect(await external.markSeen(ids: [42], for: .comment))
        await store.prepareSnapshot()
        #expect(!store.isUnread(id: 42, for: .comment) && store.unreadCount(for: .comment) == 1)
        session = AppStorageSession(accountIdentifier: "B")
        #expect(!store.isUnread(id: 43, for: .comment) && store.unreadCount(for: .comment) == 0)
        #expect(await store.replaceLatestIDs([44], unreadCount: 1, for: .comment))
        session = AppStorageSession(accountIdentifier: "A")
        await store.prepareSnapshot()
        #expect(store.isUnread(id: 43, for: .comment) && !store.isUnread(id: 44, for: .comment))
    }

    @Test(.timeLimit(.minutes(1))) func messageStorageExecutesFileWorkAwayMain() async throws {
        let domain = "BIT101ModulesTests.message-executor"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let execution = OSAllocatedUnfairLock(initialState: [Bool]())
        let record: @Sendable () -> Void = { execution.withLock { $0.append(Thread.isMainThread) } }
        let files = ModuleScoreFiles(beforeReading: record, beforeCreatingDirectory: record)
        let account = AppStorageSession(accountIdentifier: domain)
        let root = URL(fileURLWithPath: "/messages")
        let first = GalleryMessageReadStore(
            files: files, storageRoot: root, defaults: defaults, session: { account })
        let second = GalleryMessageReadStore(
            files: files, storageRoot: root, defaults: defaults, session: { account })
        async let a = first.markSeen(ids: [1], for: .comment)
        async let b = second.markSeen(ids: [2], for: .comment)
        let saved = await (a, b)
        #expect(saved.0 && saved.1)
        await first.prepareSnapshot()
        #expect(first.syncSnapshot().seenIDsByType["comment"] == [1, 2])
        #expect(execution.withLock { !$0.isEmpty && $0.allSatisfy { !$0 } })
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func messageStorageKeepsBackendsMoving(differentRoot: Bool) async throws {
        let domain = "BIT101ModulesTests.message-independent"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let entered = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            entered.withLock { $0 = true }
            #expect(gate.wait(timeout: .now() + 5) == .success)
        })
        defer { gate.signal() }
        let account = AppStorageSession(accountIdentifier: domain)
        let root = URL(fileURLWithPath: "/messages")
        let first = GalleryMessageReadStore(
            files: files, storageRoot: root, defaults: defaults, session: { account })
        let otherFiles = ModuleScoreFiles()
        let second = GalleryMessageReadStore(
            files: otherFiles,
            storageRoot: differentRoot ? root.appending(path: "independent") : root,
            defaults: defaults, session: { account })
        let waiting = Task { await first.markSeen(ids: [1], for: .comment) }
        try await waitForTestEvent { entered.withLock { $0 } }
        var saved: Bool?
        let independent = Task { saved = await second.markSeen(ids: [2], for: .comment) }
        try await waitForTestEvent(timeout: .seconds(2)) { saved != nil }
        #expect(saved == true)
        #expect(second.syncSnapshot().seenIDsByType["comment"] == [2])
        gate.signal()
        #expect(await waiting.value)
        await independent.value
        #expect(first.syncSnapshot().seenIDsByType["comment"] == [1])
    }

    @Test(.timeLimit(.minutes(1))) func messageStorageCleanupWaitsAcceptedWrites() async throws {
        let domain = "BIT101ModulesTests.message-cleanup"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let entered = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            entered.withLock { $0 = true }
            #expect(gate.wait(timeout: .now() + 5) == .success)
        })
        let tracker = StorageOperationTracker()
        let root = URL(fileURLWithPath: "/messages")
        defer { gate.signal() }
        var account = AppStorageSession(accountIdentifier: domain)
        let store = GalleryMessageReadStore(
            files: files, storageRoot: root, defaults: defaults,
            session: { account }, storageOperations: tracker)
        let writing = Task { await store.markSeen(ids: [1], for: .comment) }
        try await waitForTestEvent { entered.withLock { $0 } }
        var draining = false
        var drained = false
        let cleanup = Task {
            draining = true
            await tracker.suspendAndDrain()
            drained = true
        }
        try await waitForTestEvent { draining }
        #expect(!drained)
        #expect(await store.markSeen(ids: [2], for: .comment) == false)
        account = AppStorageSession(accountIdentifier: "signed-out")
        gate.signal()
        #expect(await writing.value == false)
        await cleanup.value
        #expect(drained && !files.storedData.isEmpty)
        #expect(files.removeContents(of: root))
        #expect(await store.prepareSnapshot() == false && files.storedData.isEmpty)
        tracker.resume()
    }

    @Test(.timeLimit(.minutes(1))) func messageStorageResetDropsMigratedMemory() async throws {
        let domain = "BIT101ModulesTests.message-reset"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = AppStorageSession(accountIdentifier: domain)
        let files = ModuleScoreFiles()
        var legacy = GalleryMessageReadSnapshot()
        legacy.seenIDsByType = ["comment": [1]]
        defaults.set(
            try JSONEncoder().encode(legacy), forKey: account.key("gallery.message.read.snapshot"))
        let store = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { account })
        await store.prepareSnapshot()
        #expect(store.syncSnapshot().seenIDsByType["comment"] == [1])
        store.invalidateSnapshot()
        defaults.removePersistentDomain(forName: domain)
        #expect(await store.markSeen(ids: [2], for: .comment))
        #expect(store.syncSnapshot().seenIDsByType["comment"] == [2])
    }

    @Test(.timeLimit(.minutes(1))) func completedMessageWriteAdvancesOwnerRevision() async throws {
        let domain = "BIT101ModulesTests.message-commit-owner"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let entered = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            entered.withLock { $0 = true }
            #expect(gate.wait(timeout: .now() + 5) == .success)
        })
        let owner = AppStorageSession(accountIdentifier: domain)
        let root = URL(fileURLWithPath: "/messages")
        defer { gate.signal() }
        let first = GalleryMessageReadStore(
            files: files, storageRoot: root, defaults: defaults, session: { owner })
        let other = GalleryMessageReadStore(
            files: files, storageRoot: root, defaults: defaults, session: { owner })
        await other.prepareSnapshot()
        let writing = Task { await first.markSeen(ids: [1], for: .comment) }
        try await waitForTestEvent { entered.withLock { $0 } }
        first.invalidateSnapshot()
        gate.signal()
        #expect(await writing.value == false)
        await other.prepareSnapshot()
        #expect(other.syncSnapshot().seenIDsByType["comment"] == [1])
    }

    @Test func communityImageDecodesExistingWireKeys() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let image = try decoder.decode(
            CommunityImage.self,
            from: Data(
                #"""
                {"mid":"image","url":"https://example.invalid/image.gif","low_url":"https://ex\#
                ample.invalid/thumbnail.jpg"}
                """#
                .utf8))
        #expect(image.id == "image")
        #expect(image.lowUrl.hasSuffix("thumbnail.jpg"))
        #expect(image.isGIF)
    }

    @Test func commentCopiesPreserveIdentityAndReplyTree() {
        let user = CommunityUser.placeholder(id: 42, nickname: "用户")
        let comment = CommunityComment(
            id: 17, obj: "course17", images: [], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 2, commentNum: 0,
            own: true, rate: 5, replyUser: user, replyObj: "", text: "评论", sub: []
        )
        let liked = comment.updatingLike(true, likeNum: 3)
        #expect(liked.id == comment.id)
        #expect(liked.obj == comment.obj)
        #expect(liked.text == comment.text)
        #expect(liked.user == user)
        #expect(liked.like && liked.likeNum == 3)
        let thread = comment.replacingSubComments([liked])
        #expect(thread.sub == [liked])
        #expect(thread.like == comment.like)
        var state = CommunityCommentState()
        state.applyFirstPage([thread, thread])
        #expect(state.items == [thread])
        #expect(state.nextPage == 1)
        state.appendPage([thread, liked, liked])
        #expect(state.items == [thread])
        #expect(state.nextPage == 2 && state.canLoadMore)
        state.appendPage([])
        #expect(state.canLoadMore == false)
    }

    @Test func accountStorePreservesLegacyKeys() throws {
        let suite = "BIT101ModulesTests.storage"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var session = AppStorageSession(accountIdentifier: "module-a")
        defaults.set(
            try JSONEncoder().encode(["old-value"]), forKey: session.legacyKey("module-test"))
        let store = AccountScopedCodableStore<[String]>(
            keyPrefix: "module-test", defaults: defaults, sessionProvider: { session })
        #expect(store.load() == ["old-value"])
        #expect(defaults.data(forKey: session.legacyKey("module-test")) == nil)
        #expect(defaults.data(forKey: store.storageKey) != nil)
        session = AppStorageSession(accountIdentifier: "module-b")
        #expect(store.load() == nil)
        store.save(["account-b"])
        session = AppStorageSession(accountIdentifier: "module-a")
        #expect(store.load() == ["old-value"])
        let guestStore = AccountScopedCodableStore<[String]>(
            keyPrefix: "module-test", defaults: defaults, sessionProvider: { session },
            guestIdentifier: "__default__"
        )
        session = AppStorageSession(accountIdentifier: "")
        guestStore.save(["guest-value"])
        #expect(guestStore.storageKey == "module-test.__default__")
        #expect(guestStore.load() == ["guest-value"])
        #expect(store.load() == nil)
        session = AppStorageSession(accountIdentifier: "module-a")
        #expect(guestStore.load() == ["old-value"])
    }
}

@MainActor
struct ComposerPublicContractTests {
    private final class Account {
        var session = AppStorageSession(accountIdentifier: "composer-A")
    }
    @Test(.timeLimit(.minutes(1))) func imagePreparation() async throws {
        let files = ModuleScoreFiles()
        let session = AppStorageSession(accountIdentifier: "composer-A")
        let store = ComposerDraftStore(
            files: files, applicationSupport: URL(fileURLWithPath: "/module-composer"),
            session: { session }, prepareImageData: { Data([42]) + $0 })
        let snapshot = DeveloperSuggestionDraftSnapshot(
            text: "draft",
            images: [
                ComposerImageDraftSnapshot(
                    filename: "image.jpg", previewData: Data([7]), uploadData: nil)
            ], contact: "contact")
        #expect(await store.saveSuggestion(snapshot))
        let restored = try #require(await store.loadSuggestion().snapshot)
        #expect(restored.text == snapshot.text)
        #expect(restored.contact == snapshot.contact)
        #expect(restored.images.first?.uploadData == Data([42, 7]))
        #expect(restored.images.first?.previewData == Data([42, 7]))
        let url = URL(fileURLWithPath: "/module-composer/BIT101-iOS")
            .appending(path: session.accountStorageIdentifier).appending(
                path: "composer-suggestion.json")
        #expect(files.writingOptions(at: url)?.contains(.atomic) == true)
        files.setFailures(writing: true)
        #expect(await store.saveSuggestion(.init(text: "next", images: [])) == false)
        #expect(await store.loadSuggestion().snapshot?.text == "draft")
    }

    @Test(.timeLimit(.minutes(1))) func capturedCleanupMatchesAccount() async {
        let account = Account()
        let store = ComposerDraftStore(
            files: ModuleScoreFiles(), applicationSupport: URL(fileURLWithPath: "/module-composer"),
            session: { account.session }, prepareImageData: { $0 })
        #expect(await store.saveSuggestion(.init(text: "A", images: [])))
        let cleanup = await store.captureSuggestionCleanup()
        account.session = AppStorageSession(accountIdentifier: "composer-B")
        #expect(await store.saveSuggestion(.init(text: "B", images: [])))
        #expect(await cleanup())
        #expect(await store.loadSuggestion().snapshot?.text == "B")
        account.session = AppStorageSession(accountIdentifier: "composer-A")
        #expect(await store.loadSuggestion().snapshot == nil)
        #expect(await store.saveSuggestion(.init(text: "submitted", images: [])))
        let oldCleanup = await store.captureSuggestionCleanup()
        #expect(await store.saveSuggestion(.init(text: "continued", images: [])))
        #expect(await oldCleanup())
        #expect(await store.loadSuggestion().snapshot?.text == "continued")
    }

    @Test(.timeLimit(.minutes(1))) func preparedImageSizeIsEnforcedAtBoundary() async {
        let store = ComposerDraftStore(
            files: ModuleScoreFiles(), applicationSupport: URL(fileURLWithPath: "/module-composer"),
            session: { AppStorageSession(accountIdentifier: "composer-A") },
            prepareImageData: { _ in Data(count: ComposerDraftImagePolicy.maximumBytes + 1) })
        #expect(await store.saveSuggestion(.init(text: "saved", images: [])))
        #expect(
            await store.saveSuggestion(
                .init(
                    text: "oversized",
                    images: [
                        .init(filename: "image.jpg", previewData: Data([1]), uploadData: nil)
                    ])) == false)
        #expect(await store.loadSuggestion().snapshot?.text == "saved")
    }
}
