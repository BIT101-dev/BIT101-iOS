import CommunityTransport
import BIT101TestSupport
import Combine
import TransportCore
@testable import MineFeature
@testable import PaperFeature
@testable import CourseFeature
@testable import GalleryFeature
import CommunityCore
import CommunityPersistence
import CommunityUI
import StorageCore
@testable import MediaKit
import Foundation
import Testing
import os

@MainActor
struct CommunityDependencyBoundaryTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func courseSearchCancelsReplacedRequestsAndOwnerExit(leavesPage: Bool) async throws {
        let service = PageAdvancementService()
        let subject = CourseListViewModel(service: service)
        service.suspendedCourseSearches = ["first"]
        let first = Task { await subject.search(for: "first") }
        defer { first.cancel(); subject.cancelRefreshOperations() }
        try await waitForTestEvent { service.enteredCourseSearches.contains("first") }
        if leavesPage { subject.cancelRefreshOperations() }
        else { await subject.search(for: "second") }
        await first.value
        #expect(service.cancelledCourseSearches == ["first"])
        service.suspendedCourseSearches = []
        await subject.bootstrapIfNeeded()
        #expect(subject.state.status == .loaded && !subject.state.items.isEmpty)
        #expect(service.requests == [0, 0])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func uncertainFollowReadsTheCurrentRelationshipBeforeAnotherToggle(committed: Bool, readFails: Bool) async {
        let service = PagingMineService()
        let subject = UserProfileViewModel(userID: 1, service: service)
        await subject.refreshProfile()
        service.follow = { throw CommunityToggleOutcomeUnknown(underlying: URLError(.networkConnectionLost)) }
        let current = MineUserInfo(user: .placeholder(id: 1, nickname: "用户"), followingNum: 2, followerNum: 3,
            following: committed, follower: false, own: false)
        service.profile = { if readFails { throw URLError(.timedOut) }; return current }
        await subject.followUser()
        #expect(service.followingRequests == 1)
        if readFails {
            await subject.followUser()
            #expect(service.followingRequests == 1)
            service.profile = { current }
            await subject.refreshProfile()
        }
        #expect(subject.userInfo?.following == committed)
        service.follow = { MineFollowResult(following: !committed, follower: false, followingNum: 2, followerNum: committed ? 2 : 4) }
        await subject.followUser()
        #expect(service.followingRequests == 2 && subject.userInfo?.following == !committed)
    }

    @Test(.timeLimit(.minutes(1))) func fileProtectionFailuresPreserveBothComposerDrafts() async throws {
        let files = ModuleScoreFiles()
        let store = ComposerDraftStore(files: files, applicationSupport: URL(fileURLWithPath: "/protected-draft"),
            session: { AppStorageSession(accountIdentifier: "protected") }, prepareImageData: { $0 })
        let gallery = GalleryComposerDraftSnapshot(title: "已保存", text: "正文", selectedTags: [], customTags: [],
            anonymous: false, isPublic: false, selectedClaimID: 0, images: [])
        let suggestion = DeveloperSuggestionDraftSnapshot(text: "已保存", images: [])
        #expect(await store.saveGallery(gallery))
        #expect(await store.saveSuggestion(suggestion))
        let original = files.storedData
        files.setFailures(protection: true)
        #expect(await store.loadGallery().allowsWrite == false)
        #expect(await store.loadSuggestion().allowsWrite == false)
        #expect(await store.saveGallery(gallery) == false)
        #expect(await store.saveSuggestion(suggestion) == false)
        #expect(files.storedData == original)
        files.setFailures()
        #expect(await store.loadGallery().snapshot?.title == gallery.title)
        #expect(await store.loadSuggestion().snapshot?.text == suggestion.text)
    }

    private final class RecoverableUnreadService: GalleryMessageServicing {
        var error: (any Error)? = URLError(.notConnectedToInternet)
        var counts = GalleryMessageUnreadCounts(comment: 1)
        var cursors: [Int?] = []
        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts {
            if let error { throw error }
            return counts
        }
        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
            cursors.append(lastID)
            if lastID == nil { counts = .init(); return [] }
            return try RecordingMessageService.messages([42])
        }
    }

    @Test(.timeLimit(.minutes(1))) func failedUnreadSummariesKeepReadStateAndRecoverBeforeAcknowledgingMessages() async {
        let service = RecoverableUnreadService(), store = RecordingMessageReadStore()
        store.latestIDs = [99]
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.bootstrapIfNeeded()
        #expect(model.unreadCountsFailure != nil && model.alert != nil)
        #expect(store.latestIDs == [99] && service.cursors == [Int.max])
        #expect(model.state(for: .comment).status == .loaded && model.state(for: .comment).items.map(\.id) == [42])
        service.error = nil
        await model.refreshSelectedType()
        #expect(model.unreadCountsFailure == nil && model.state(for: .comment).items.map(\.id) == [42])
        #expect(service.cursors == [Int.max, Int.max, Int.max, nil, Int.max])
    }

    @Test(arguments: [#"{"comment":-1}"#, #"{"follow":-1}"#, #"{"like":-1}"#, #"{"system":-1}"#,
                      #"{"comment":9223372036854775807,"follow":1}"#])
    func invalidUnreadCountsFailAtTheNetworkBoundary(_ source: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(GalleryMessageUnreadCounts.self, from: Data(source.utf8)) }
    }

    @Test(.timeLimit(.minutes(1))) func unreadTotalsRemainRepresentableAcrossServerAndLocalCounts() async throws {
        let counts = try JSONDecoder().decode(GalleryMessageUnreadCounts.self, from: Data(#"{"follow":9223372036854775807}"#.utf8))
        let service = RecoverableUnreadService(), store = RecordingMessageReadStore()
        service.error = nil; service.counts = counts
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        #expect(model.totalUnreadCount == Int.max)
    }

    @Test(.timeLimit(.minutes(1))) func refreshedServerCountsRemainVisibleAlongsideOlderLocalUnreadMessages() async {
        let service = RecoverableUnreadService(), store = RecordingMessageReadStore()
        service.error = nil; store.unread = 1
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        #expect(model.unreadCount(for: .comment) == 1)
        service.counts = GalleryMessageUnreadCounts(comment: 10)
        await model.refreshUnreadCounts()
        #expect(model.unreadCount(for: .comment) == 10)
        service.counts = GalleryMessageUnreadCounts(comment: 0)
        await model.refreshUnreadCounts()
        #expect(model.unreadCount(for: .comment) == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func draftWritesFinishBeforeCleanupAndPauseFurtherAccess(suggestion: Bool) async throws {
        let started = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            if started.withLock({ value in defer { value = true }; return !value }) {
                #expect(gate.wait(timeout: .now() + 5) == .success)
            }
        })
        let operations = StorageOperationTracker()
        let root = URL(fileURLWithPath: "/cleanup-draft")
        let store = ComposerDraftStore(files: files, applicationSupport: root, session: { AppStorageSession(accountIdentifier: "cleanup") },
            prepareImageData: { $0 }, storageOperations: operations)
        func save() async -> Bool {
            if suggestion { return await store.saveSuggestion(.init(text: "功能验收", images: [])) }
            return await store.saveGallery(.init(title: "功能验收", text: "功能验收", selectedTags: [], customTags: [],
                anonymous: false, isPublic: false, selectedClaimID: 0, images: []))
        }
        let ownedCleanup = suggestion ? await store.captureSuggestionCleanup() : await store.captureGalleryCleanup()
        let pending = Task { await save() }
        try await waitForTestEvent { !(!started.withLock({ $0 })) }
        var cleanupStarted = false
        let cleanup = Task { @MainActor in
            cleanupStarted = true
            await operations.suspendAndDrain()
            return files.removeContents(of: root)
        }
        try await waitForTestEvent { !(!cleanupStarted) }
        #expect(await save() == false)
        gate.signal()
        let saved = await pending.value
        let cleaned = await cleanup.value
        #expect(saved && cleaned)
        #expect(files.storedData.isEmpty)
        #expect(await store.loadGallery().snapshot == nil)
        #expect(await store.loadSuggestion().snapshot == nil)
        #expect(await store.removeGallery() == false)
        #expect(await store.removeSuggestion() == false)
        #expect(await ownedCleanup() == false)
        let suspendedCleanup = await store.captureGalleryCleanup()
        #expect(await suspendedCleanup() == false && files.storedData.isEmpty)
        operations.resume()
        #expect(await save())
    }

    private final class PageAdvancementService: CourseListServicing, PaperListServicing {
        var pages = [0: [1, 2], 1: [1, 2], 2: [1, 2], 3: [3]]
        var requests: [Int] = []
        var suspendedOrder: PaperSortOrder?
        var enteredOrders: Set<PaperSortOrder> = []
        var cancelledOrders: Set<PaperSortOrder> = []
        var paperFailure: (any Error)?
        var metadataFailure: (any Error)?
        var repeatsForever = false
        var suspendedCourseSearches: Set<String> = []
        var enteredCourseSearches: Set<String> = []
        var cancelledCourseSearches: Set<String> = []
        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            requests.append(page)
            if suspendedCourseSearches.contains(search) {
                enteredCourseSearches.insert(search)
                do { try await Task.sleep(for: .seconds(30)) }
                catch { cancelledCourseSearches.insert(search); throw error }
            }
            return try (pages[repeatsForever ? 0 : page] ?? []).map { id in
                try JSONDecoder().decode(CourseSummary.self, from: Data("""
                {"id":\(id),"name":"功能验收","number":"C-\(id)","credit":2,
                 "likeNum":0,"commentNum":0,"rate":0,"teachersName":"","teachersNumber":""}
                """.utf8))
            }
        }
        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
            requests.append(page)
            if let paperFailure { throw paperFailure }
            if suspendedOrder == order {
                enteredOrders.insert(order)
                do { try await Task.sleep(for: .seconds(30)) }
                catch { cancelledOrders.insert(order); throw error }
            }
            return (pages[repeatsForever ? 0 : page] ?? []).map { PaperSummary(id: $0, title: "功能验收", intro: "", likeNum: 0, commentNum: 0, updateTime: "") }
        }
        func fetchPaper(id: Int) async throws -> PaperDetail {
            if let metadataFailure { throw metadataFailure }
            return PaperDetail(id: id, title: "功能验收", intro: "", content: "", createTime: "", updateTime: "",
                updateUser: .placeholder(id: 1, nickname: "作者"), anonymous: false, likeNum: 0, commentNum: 0,
                publicEdit: false, like: false, own: false)
        }
        func fetchPreviewMetadata(id: Int) async throws -> PaperPreviewMetadata { try await fetchPaper(id: id).previewMetadata }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["course", "paper", "search"], [false, true])
    func repeatedPagesAdvanceUntilNewItemsOrTheEnd(scene: String, endsAfterDuplicates: Bool) async {
        let service = PageAdvancementService()
        if endsAfterDuplicates { service.pages[3] = [] }
        let course = CourseListViewModel(service: service)
        let paper = PaperListViewModel(service: service)
        let search = PaperSearchViewModel(service: service)
        search.searchText = "功能验收"
        func refresh() async {
            switch scene {
            case "course": await course.refresh()
            case "paper": await paper.refresh()
            default: await search.performSearch()
            }
        }
        func next() async {
            switch scene {
            case "course": await course.loadMoreIfNeeded(currentCourse: course.state.items.last)
            case "paper": await paper.loadMoreIfNeeded(currentPaper: paper.state.items.last)
            default: await search.loadMoreIfNeeded(currentPaper: search.state.items.last)
            }
        }
        await refresh(); await next()
        let ids = scene == "course" ? course.state.items.map(\.id) : scene == "paper" ? paper.state.items.map(\.id) : search.state.items.map(\.id)
        #expect(ids == (endsAfterDuplicates ? [1, 2] : [1, 2, 3]))
        #expect(service.requests == [0, 1, 2, 3])
        if !endsAfterDuplicates { await next() }
        #expect(!(scene == "course" ? course.state.canLoadMore : scene == "paper" ? paper.state.canLoadMore : search.state.canLoadMore))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellingArticleRefreshRetainsItsSuccessfulPagination(searching: Bool) async throws {
        let service = PageAdvancementService()
        let list = PaperListViewModel(service: service)
        let search = PaperSearchViewModel(service: service)
        search.searchText = "功能验收"
        await (searching ? search.enqueueSearch() : list.enqueueRefresh()).value
        let original = list.state.items.first ?? search.state.items.first
        if let original {
            if searching { await search.loadPreviewMetadataIfNeeded(for: original) }
            else { await list.loadPreviewMetadataIfNeeded(for: original) }
        }
        service.suspendedOrder = .newest
        let pending = searching ? search.enqueueSearch() : list.enqueueRefresh()
        try await waitForTestEvent { !(!service.enteredOrders.contains(.newest)) }
        if searching { search.cancelSearchOperations() } else { list.cancelRefreshOperations() }
        await pending.value
        let state = searching ? search.state : list.state
        #expect(state.status == .loaded && state.nextPage == 1 && state.items.map(\.id) == [1, 2])
        #expect((searching ? search.previewMetadata(for: 1) : list.previewMetadata(for: 1))?.authorName == "作者")
        service.suspendedOrder = nil
        if searching { await search.loadMoreIfNeeded(currentPaper: state.items.last) }
        else { await list.loadMoreIfNeeded(currentPaper: state.items.last) }
        #expect(service.requests == [0, 0, 1, 2, 3])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func failedArticleReadsKeepTheirLoadedAuthorMetadata(searching: Bool, cancelled: Bool) async throws {
        let service = PageAdvancementService()
        let list = PaperListViewModel(service: service)
        let search = PaperSearchViewModel(service: service)
        search.searchText = "功能验收"
        await (searching ? search.enqueueSearch() : list.enqueueRefresh()).value
        let paper = try #require((searching ? search.state : list.state).items.first)
        if searching { await search.loadPreviewMetadataIfNeeded(for: paper) }
        else { await list.loadPreviewMetadataIfNeeded(for: paper) }
        service.paperFailure = cancelled ? CancellationError() : URLError(.notConnectedToInternet)
        service.metadataFailure = URLError(.notConnectedToInternet)
        await (searching ? search.enqueueSearch() : list.enqueueRefresh()).value
        let state = searching ? search.state : list.state
        #expect(state.status == .loaded && state.nextPage == 1 && state.items.map(\.id) == [1, 2])
        #expect((searching ? search.previewMetadata(for: paper.id) : list.previewMetadata(for: paper.id))?.authorName == "作者")
        #expect(cancelled ? (searching ? search.alert == nil : list.alert == nil) : (searching ? search.alert != nil : list.alert != nil))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["course", "paper", "search"])
    func aRepeatingSourceStopsTheBatchAndKeepsTheNextPageAvailableForRetry(scene: String) async {
        let service = PageAdvancementService()
        service.repeatsForever = true
        let course = CourseListViewModel(service: service)
        let paper = PaperListViewModel(service: service)
        let search = PaperSearchViewModel(service: service)
        search.searchText = "功能验收"
        switch scene {
        case "course": await course.refresh()
        case "paper": await paper.refresh()
        default: await search.performSearch()
        }
        func next() async {
            switch scene {
            case "course": await course.loadMoreIfNeeded(currentCourse: course.state.items.last)
            case "paper": await paper.loadMoreIfNeeded(currentPaper: paper.state.items.last)
            default: await search.loadMoreIfNeeded(currentPaper: search.state.items.last)
            }
        }
        await next()
        #expect(service.requests == [0, 1, 2, 3, 4])
        #expect(scene == "course" ? course.alert != nil : scene == "paper" ? paper.alert != nil : search.alert != nil)
        service.repeatsForever = false
        service.pages[4] = [3]
        await next()
        let ids = scene == "course" ? course.state.items.map(\.id) : scene == "paper" ? paper.state.items.map(\.id) : search.state.items.map(\.id)
        #expect(ids == [1, 2, 3] && service.requests.last == 4)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func articleReadsCancelWhenReplacedOrClosed(searching: Bool, closing: Bool) async throws {
        let service = PageAdvancementService()
        service.suspendedOrder = .newest
        let list = PaperListViewModel(service: service)
        let search = PaperSearchViewModel(service: service)
        search.searchText = "功能验收"
        let first = searching ? search.enqueueSearch() : list.enqueueRefresh()
        try await waitForTestEvent { !(!service.enteredOrders.contains(.newest)) }
        if closing {
            if searching { search.cancelSearchOperations() } else { list.cancelRefreshOperations() }
        } else {
            if searching { search.selectedOrder = .like } else { list.selectedOrder = .like }
            let replacement = searching ? search.enqueueSearch() : list.enqueueRefresh()
            await replacement.value
        }
        await first.value
        #expect(service.cancelledOrders == [.newest])
        #expect((searching ? search.state.status : list.state.status) == (closing ? .idle : .loaded))
        #expect(searching ? search.alert == nil : list.alert == nil)
        if closing {
            service.suspendedOrder = nil
            let reopened = searching ? search.enqueueSearch() : list.enqueueRefresh()
            await reopened.value
            #expect((searching ? search.state.status : list.state.status) == .loaded)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func profileRefreshAndFollowConvergeInEitherCompletionOrder(followFinishesFirst: Bool) async throws {
        let service = PagingMineService()
        let model = UserProfileViewModel(userID: 1, service: service)
        await model.refreshProfile()
        var pendingFollow: CheckedContinuation<Void, Never>?
        var pendingRead: CheckedContinuation<Void, Never>?
        let refreshed = MineUserInfo(user: .placeholder(id: 1, nickname: "已刷新"), followingNum: 2, followerNum: 3, following: false, follower: false, own: false)
        service.profile = { await withCheckedContinuation { pendingRead = $0 }; return refreshed }
        service.follow = { await withCheckedContinuation { pendingFollow = $0 }; return MineFollowResult(following: true, follower: true, followingNum: 4, followerNum: 5) }
        let following = Task { await model.followUser() }
        try await waitForTestEvent { !(pendingFollow == nil) }
        let refresh = Task { await model.refreshProfile() }
        try await waitForTestEvent { !(pendingRead == nil) }
        if followFinishesFirst { pendingFollow?.resume(); await following.value; pendingRead?.resume(); await refresh.value }
        else { pendingRead?.resume(); await refresh.value; pendingFollow?.resume(); await following.value }
        #expect(model.userInfo?.user.nickname == "已刷新")
        #expect(model.userInfo?.following == true && model.userInfo?.followerNum == 5)
        #expect(model.isFollowingUser == false && model.alert == nil)
        service.follow = { MineFollowResult(following: false, follower: true, followingNum: 4, followerNum: 4) }
        await model.followUser()
        #expect(service.followingRequests == 2 && model.userInfo?.following == false)
    }

    @Test func cursorMessagePagesDeduplicateAndRetireStalledOrRevisitedCursors() throws {
        var state = GalleryMessageListState()
        state.applyFirstCursorPage(try RecordingMessageService.messages([10, 10, 9]))
        #expect(state.items.map(\.id) == [10, 9] && state.nextCursor == 9)
        state.appendCursorPage(try RecordingMessageService.messages([9, 8, 8]))
        #expect(state.items.map(\.id) == [10, 9, 8] && state.nextCursor == 8 && state.canLoadMore)
        state.isLoadingMore = true
        state.appendCursorPage(try RecordingMessageService.messages([8]))
        #expect(state.items.map(\.id) == [10, 9, 8] && !state.canLoadMore && !state.isLoadingMore)
        state.resetCursorPagination()
        state.applyFirstCursorPage(try RecordingMessageService.messages([10, 9]))
        state.appendCursorPage(try RecordingMessageService.messages([10]))
        #expect(state.items.map(\.id) == [10, 9] && state.nextCursor == 10 && !state.canLoadMore)
        state.resetCursorPagination()
        state.applyFirstCursorPage(try RecordingMessageService.messages([10, 9]))
        state.appendCursorPage([])
        #expect(state.nextCursor == 9 && !state.canLoadMore)
    }

    @Test(.timeLimit(.minutes(1)), .serialized, arguments: GalleryMessageType.allCases)
    func messagesCaptureTheUnreadWindowAcrossSourcePagesAndRetainHistoricalPaging(type: GalleryMessageType) async throws {
        let domain = "BIT101ModulesTests.message-window"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "message-window")
        let files = ModuleScoreFiles()
        let store = GalleryMessageReadStore(files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults, session: { session })
        let service = PagedMessageService()
        service.messageType = type
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        await model.refresh(type: type)
        #expect(service.cursors == [Int.max, 5, 3, nil, Int.max])
        #expect(model.state(for: type).items.map(\.id) == [6, 5])
        #expect(model.unreadCount(for: type) == 5)
        #expect(store.isUnread(id: 2, for: type) && !store.isUnread(id: 1, for: type))
        await model.loadMoreIfNeeded(for: type, currentMessage: model.state(for: type).items.last)
        await model.loadMoreIfNeeded(for: type, currentMessage: model.state(for: type).items.last)
        await model.loadMoreIfNeeded(for: type, currentMessage: model.state(for: type).items.last)
        #expect(service.cursors == [Int.max, 5, 3, nil, Int.max, 5, 3, 1])
        #expect(!model.state(for: type).canLoadMore)
        await model.refresh(type: type)
        #expect(store.unreadCount(for: type) == 5)
        model.selectedType = type
        await model.markCurrentTypeAsRead()
        #expect(model.unreadCount(for: type) == 0)
        #expect(model.state(for: type).items.map(\.id) == [6, 5])
        let reopened = GalleryMessageReadStore(files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults, session: { session })
        #expect(await reopened.prepareSnapshot())
        #expect(reopened.unreadCount(for: type) == 0 && !reopened.isUnread(id: 2, for: type))
        await model.markCurrentTypeAsRead()
        #expect(model.unreadCount(for: type) == 0)
        let before = model.state(for: type)
        for error in [URLError(.timedOut) as any Error, CancellationError()] {
            model.alert = nil
            service.failure = error
            await model.refresh(type: type)
            let current = model.state(for: type)
            #expect(current.status == .loaded && current.items.map(\.id) == before.items.map(\.id))
            #expect(current.nextCursor == before.nextCursor && current.canLoadMore == before.canLoadMore)
            #expect(!current.isLoadingMore)
            #expect(model.alert?.title == (error is CancellationError ? nil : "加载消息失败"))
        }
        service.failure = nil
        await model.refresh(type: type)
        #expect(model.state(for: type).status == .loaded)
        service.identifiers = []
        await model.refresh(type: type)
        #expect(model.state(for: type).items.isEmpty && model.state(for: type).status == .loaded)
        #expect(!model.state(for: type).canLoadMore && !model.state(for: type).isLoadingMore)
        #expect(service.requestedTypes.allSatisfy { $0 == type })
        for other in GalleryMessageType.allCases where other != type {
            #expect(model.state(for: other).items.isEmpty && store.unreadCount(for: other) == 0)
        }
    }

    @Test(.timeLimit(.minutes(1))) func messagesDisplayFirstPageWhileUnreadRecoveryWaits() async throws {
        let service = PagedMessageService(), store = RecordingMessageReadStore()
        var pending: CheckedContinuation<Void, Never>?
        service.beforeLaterPage = { await withCheckedContinuation { pending = $0 } }
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        let refresh = Task { await model.refresh(type: .comment) }
        try await waitForTestEvent { pending != nil }
        #expect(model.state(for: .comment).status == .loaded)
        #expect(model.state(for: .comment).items.map(\.id) == [6, 5])
        #expect(model.state(for: .comment).isLoadingMore && service.unread == 5)
        service.beforeLaterPage = nil
        pending?.resume()
        await refresh.value
        #expect(!model.state(for: .comment).isLoadingMore && service.unread == 0)
    }

    @Test(.timeLimit(.minutes(1)), .serialized, arguments: [false, true]) func unreadWindowSurvivesInterruptedPaging(cancelled: Bool) async throws {
        let domain = "BIT101ModulesTests.message-interruption"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let files = ModuleScoreFiles()
        let store = GalleryMessageReadStore(files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults, session: { session })
        let service = PagedMessageService()
        service.laterPageFailure = cancelled ? CancellationError() : URLError(.timedOut)
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        await model.refresh(type: .comment)
        #expect(service.unread == 5 && service.cursors == [Int.max, 5])
        #expect(store.unreadCount(for: .comment) == 0)
        service.laterPageFailure = nil
        let reopened = GalleryMessageReadStore(files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults, session: { session })
        service.beforeAcknowledgement = { #expect(reopened.unreadCount(for: .comment) == 5) }
        let retry = GalleryMessageViewModel(service: service, readStore: reopened)
        await retry.bootstrapIfNeeded()
        #expect(retry.state(for: .comment).status == .loaded)
        #expect(service.unread == 0 && reopened.unreadCount(for: .comment) == 5)
    }

    @Test(.timeLimit(.minutes(1)), .serialized, arguments: ["before-first", "after-first", "during-confirm", "lost-confirm", "interrupted-recovery", "large-window", "large-recovery"])
    func unreadWindowRecoversConcurrentArrivalsAndAcknowledgementFailures(stage: String) async throws {
        let domain = "BIT101ModulesTests.message-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain), files = ModuleScoreFiles(), root = URL(fileURLWithPath: "/messages")
        let service = PagedMessageService()
        let store = GalleryMessageReadStore(files: files, storageRoot: root, defaults: defaults, session: { session })
        var saves = 0
        let saveObservation = store.localSaves.sink { _ in saves += 1 }
        defer { withExtendedLifetime(saveObservation) {} }
        if stage == "large-window" { service.unread = 2_000; service.identifiers = Array((1...2_000).reversed()) }
        if stage == "before-first" {
            service.beforeFirstPage = { service.identifiers.insert(7, at: 0); service.unread += 1 }
        } else if stage == "after-first" {
            service.unread = 1; service.identifiers = [100, 99]
            service.beforeUnreadSummary = { service.identifiers.insert(101, at: 0); service.unread += 1 }
        } else if stage == "large-recovery" {
            service.beforeAcknowledgement = { service.identifiers = Array((1...2_000).reversed()) }
        } else if stage != "large-window" {
            service.beforeAcknowledgement = { service.identifiers = Array((1...12).reversed()) }
        }
        if stage == "lost-confirm" { service.acknowledgementFailure = URLError(.networkConnectionLost) }
        if stage == "interrupted-recovery" { service.postAcknowledgementFailure = URLError(.timedOut) }
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        await model.refresh(type: .comment)
        #expect(service.unread == 0)
        if stage == "lost-confirm" || stage == "interrupted-recovery" {
            #expect(store.pendingUnreadAfterID(for: .comment) == 6)
            service.acknowledgementFailure = nil; service.postAcknowledgementFailure = nil
            defaults.removePersistentDomain(forName: domain)
            let reopened = GalleryMessageReadStore(files: files, storageRoot: root, defaults: defaults, session: { session })
            let retry = GalleryMessageViewModel(service: service, readStore: reopened)
            await retry.bootstrapIfNeeded()
            #expect(reopened.unreadCount(for: .comment) == 11 && reopened.pendingUnreadAfterID(for: .comment) == nil)
            #expect(reopened.isUnread(id: 2, for: .comment) && reopened.isUnread(id: 7, for: .comment))
        } else {
            #expect(store.unreadCount(for: .comment) == (stage == "large-window" ? 2_000 : stage == "large-recovery" ? 1_999 : stage == "before-first" ? 6 : stage == "after-first" ? 2 : 11))
            #expect(store.isUnread(id: stage == "large-window" ? 1 : stage == "after-first" ? 100 : 2, for: .comment))
            if stage == "after-first" { #expect(!store.isUnread(id: 99, for: .comment)) }
            #expect(store.pendingUnreadAfterID(for: .comment) == nil)
            if stage == "large-recovery" { #expect(saves == 5) }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func unavailableReadStorageKeepsServerUnreadAndReportsFailure(damaged: Bool) async throws {
        let store = RecordingMessageReadStore()
        store.hasUnreadableSnapshot = damaged
        store.saveSucceeds = false
        let service = PagedMessageService()
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        await model.refresh(type: .comment)
        #expect(service.unread == 5 && !service.cursors.contains(nil))
        if damaged { #expect(service.cursors == [Int.max]) }
        #expect(model.state(for: .comment).status == .loaded && !model.state(for: .comment).items.isEmpty)
        #expect(model.alert?.title == "消息状态同步受阻")
        #expect(model.alert?.message.contains(damaged ? "读取失败" : "保存失败") == true)
        model.alert = nil
        await model.markMessageAsRead(try #require(RecordingMessageService.messages([42]).first), in: .comment)
        #expect(model.alert?.title == "保存消息状态失败")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["replacement", "cancel", "account", "error"])
    func messageNavigationKeepsTheLatestIntentAndReportsTheActualFailure(boundary: String) async throws {
        let store = RecordingMessageReadStore()
        let model = GalleryMessageViewModel(service: RecordingMessageService(), readStore: store)
        let details = SuspendedMessageDetails()
        let messages = try RecordingMessageService.messages([1, 2])
        let first = Task { await model.openMessage(messages[0], in: .comment, using: details) }
        try await waitForTestEvent { !(details.pending[1] == nil) }
        if boundary == "replacement" {
            let second = Task { await model.openMessage(messages[1], in: .comment, using: details) }
            try await waitForTestEvent { !(details.pending[2] == nil) }
            details.pending.removeValue(forKey: 2)?.resume(returning: details.poster(2))
            await second.value
        } else if boundary == "cancel" { first.cancel() }
        else if boundary == "account" { store.currentSession = AppStorageSession(accountIdentifier: "replacement") }
        let failure = URLError(.notConnectedToInternet)
        if boundary == "error" { details.pending.removeValue(forKey: 1)?.resume(throwing: failure) }
        else { details.pending.removeValue(forKey: 1)?.resume(returning: details.poster(1)) }
        await first.value
        #expect(model.selectedPoster?.id == (boundary == "replacement" ? 2 : nil))
        #expect(model.alert?.message == (boundary == "error" ? failure.localizedDescription : nil))
    }

    private var session: CommunitySession {
        CommunitySession(
            httpClient: HTTPClient(transport: OfflineCommunityTransport(), observer: nil),
            baseURL: AppURL.required("https://example.invalid"), credentials: { CommunityCredentials(identity: CommunitySessionIdentity(accountIdentifier: "test-account"), cookie: "module-cookie") }, refresh: { _ in }
        )
    }

    private var preferences: CommunityPreferences {
        CommunityPreferences(
            snapshot: CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false),
            saveMakeupFilter: { _ in }
        )
    }

    @Test(.timeLimit(.minutes(1))) func courseEvaluationFactoryUsesTheInjectedListService() async throws {
        let list = RecordingCourseList()
        let dependencies = CourseDependencies(
            list: list, detail: CourseService(session: session), preferences: preferences, loadCourseCredits: { [] }
        )
        let result = try await dependencies.makeEvaluationResolver().resolve(courseName: "高等数学", courseNumber: "MATH")
        #expect(result == nil)
        #expect(Set(list.requests) == ["MATH", "高等数学"])
    }

    private final class LargeCourseLookup: CourseListServicing {
        var pages = 0
        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            pages += 1
            let course = CourseDetail(id: page + 1, name: String(repeating: "中", count: HTTPResponseResourceLimits.maximumStructuredBytes / 3),
                number: "C1", credit: 1, likeNum: 0, commentNum: 0, rate: 0, teachersName: "教师", teachersNumber: "", like: false)
            return [CourseSummary(detail: course)]
        }
    }

    @Test(.timeLimit(.minutes(1))) func automaticCourseLookupStopsAtItsCumulativeCandidateBudget() async throws {
        let service = LargeCourseLookup()
        do {
            _ = try await CourseEvaluationResolver(service: service).resolve(courseName: "课程", courseNumber: "")
            Issue.record("自动消歧达到候选容量后应提示使用课程搜索")
        } catch {
            #expect(error.localizedDescription.contains("课程搜索"))
            #expect(service.pages == 1)
        }
    }

    @Test(.timeLimit(.minutes(1))) func automaticCourseLookupDeadlineCancelsBothInFlightSearches() async throws {
        let service = PageAdvancementService()
        service.suspendedCourseSearches = ["number", "name"]
        let entered = OSAllocatedUnfairLock(initialState: false)
        let lookup = CourseEvaluationResolver(service: service, waitForDeadline: { _ in
            while !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
        })
        let task = Task { try await lookup.resolve(courseName: "name", courseNumber: "number") }
        defer { task.cancel() }
        try await waitForTestEvent { service.enteredCourseSearches == ["number", "name"] }
        entered.withLock { $0 = true }
        do {
            _ = try await task.value
            Issue.record("检索总时限需要结束两路在途请求")
        } catch {
            #expect(error.localizedDescription.contains("课程搜索"))
            #expect(service.cancelledCourseSearches == ["number", "name"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func galleryFeedUsesTheInjectedSceneService() async {
        let feed = RecordingGalleryFeed()
        let viewModel = GalleryViewModel(service: feed)
        await viewModel.refresh(feed: .newest)

        #expect(feed.requests == [.newest])
        #expect(viewModel.state(for: .newest).status == .loaded)
    }

    @Test(.timeLimit(.minutes(1))) func galleryMessagesUseIndependentReadPortsAndScopedChanges() async throws {
        let store = RecordingMessageReadStore()
        let otherStore = RecordingMessageReadStore()
        let model = GalleryMessageViewModel(service: RecordingMessageService(), readStore: store)
        var refreshes = 0
        let subscription = model.objectWillChange.sink { refreshes += 1 }
        otherStore.changeSubject.send(store.currentSession)
        store.changeSubject.send(AppStorageSession(accountIdentifier: "other-account"))
        #expect(refreshes == 0)
        store.changeSubject.send(store.currentSession)
        #expect(refreshes == 1)
        #expect(model.unreadCount(for: .comment) == 7)
        await model.refresh(type: .comment)
        #expect(store.latestIDs.isEmpty)
        await model.markCurrentTypeAsRead()
        #expect(store.seenIDs == [42])
        #expect(otherStore.seenIDs.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    private final class DelayedUnreadService: GalleryMessageServicing {
        var pending: CheckedContinuation<GalleryMessageUnreadCounts, Never>?
        var delay = true
        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts {
            if delay { return await withCheckedContinuation { pending = $0 } }
            return .init()
        }
        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] { [] }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["newer", "list", "cancel"])
    func unreadSummaryRejectsLateResponsesAfterReplacementClearOrCancellation(boundary: String) async throws {
        let service = DelayedUnreadService()
        let store = RecordingMessageReadStore()
        store.unread = 0
        let model = GalleryMessageViewModel(service: service, readStore: store)
        let old = Task { await model.refreshUnreadCounts() }
        try await waitForTestEvent { !(service.pending == nil) }
        service.delay = false
        switch boundary {
        case "newer": await model.refreshUnreadCounts()
        case "list": await model.refresh(type: .comment)
        default: old.cancel()
        }
        service.pending?.resume(returning: .init(comment: 9))
        await old.value
        #expect(model.unreadCounts.comment == 0)
        #expect(model.totalUnreadCount == 0)
        #expect(model.alert == nil)
    }

    @Test(.timeLimit(.minutes(1))) func courseListAndCreditQueryUseIndependentInjections() async {
        let detail = CourseService(session: session)
        let list = RecordingCourseList()
        let dependencies = CourseDependencies(
            list: list, detail: detail, preferences: preferences,
            loadCourseCredits: { [CommunityCourseCredit(number: "MATH", name: "高等数学", credit: 3)] }
        )
        let viewModel = dependencies.makeListViewModel()
        await viewModel.search(for: "高等数学")
        let credits = await dependencies.loadCourseCredits()

        #expect(list.requests == ["高等数学"])
        #expect(viewModel.state.status == .loaded)
        #expect(credits.map(\.number) == ["MATH"])
        #expect(credits.map(\.credit) == [3])
    }

    @Test(.timeLimit(.minutes(1))) func paperListAndComposerUseSeparateSceneServices() async throws {
        let detail = PaperService(session: session)
        let list = RecordingPaperList()
        let composer = RecordingPaperComposer()
        let dependencies = PaperDependencies(list: list, detail: detail, composer: composer,
            networkPath: NetworkPathState(snapshot: NetworkPathSnapshot(status: .connected)))
        let viewModel = PaperListViewModel(service: dependencies.list)
        await viewModel.refresh()
        let id = try await dependencies.composer.createPaper(
            title: "标题", intro: "简介", content: "正文", anonymous: false, publicEdit: true
        )
        try await dependencies.composer.updatePaper(
            id: id, title: "编辑标题", intro: "简介", content: "编辑正文", anonymous: true, publicEdit: false, lastUpdatedAt: "2026-10-01T08:00:00Z"
        )

        #expect(list.requests == 1)
        #expect(viewModel.state.status == .loaded)
        #expect(composer.createdTitles == ["标题"])
        #expect(composer.updatedIDs == [42])
        #expect(composer.publicEditValues == [true, false])
    }

    @Test(.timeLimit(.minutes(1))) func mineOverviewPreservesInjectedCancellationSemantics() async {
        let overview = RecordingMineOverview()
        let dependencies = MineDependencies(
            overview: overview, profile: MineService(session: session, preferences: { self.preferences.snapshot }),
            deletePoster: { _ in }
        )
        let viewModel = MineViewModel(service: dependencies.overview)
        await viewModel.bootstrapIfNeeded()

        #expect(overview.requests == 1)
        #expect(viewModel.profileStatus == .idle)
        #expect(viewModel.alert == nil)
        await viewModel.bootstrapIfNeeded()
        #expect(overview.requests == 2)
    }

    @Test(.timeLimit(.minutes(1))) func mineDeletionUsesItsInjectedBusinessAction() async throws {
        var deletedIDs: [Int] = []
        let dependencies = MineDependencies(
            overview: RecordingMineOverview(),
            profile: MineService(session: session, preferences: { self.preferences.snapshot }),
            deletePoster: { deletedIDs.append($0) }
        )
        try await dependencies.deletePoster(42)
        #expect(deletedIDs == [42])
    }
    @Test func mediaProjectionPreservesOriginalThumbnailAndSingleAddressImages() throws {
        let original = "https://example.com/original.png"
        let thumbnail = "https://example.com/thumbnail.png"
        let images = [
            CommunityImage(mid: "both", url: original, lowUrl: thumbnail),
            CommunityImage(mid: "original", url: original, lowUrl: ""),
            CommunityImage(mid: "thumbnail", url: "", lowUrl: thumbnail)
        ]
        let projected = images.map(\.previewImage)
        #expect(projected[0].originalURL == URL(string: original))
        #expect(projected[0].thumbnailURL == URL(string: thumbnail))
        #expect(projected[1].originalURL == projected[1].thumbnailURL)
        #expect(projected[2].originalURL == projected[2].thumbnailURL)

    }
}

private final class RecordingMessageReadStore: GalleryMessageReadStoring {
    var currentSession = AppStorageSession(accountIdentifier: "message-port")
    var hasUnreadableSnapshot = false
    func prepareSnapshot() async -> Bool { !hasUnreadableSnapshot }
    var saveSucceeds = true
    let changeSubject = PassthroughSubject<AppStorageSession, Never>()
    var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
    var latestIDs: [Int] = []
    var seenIDs: [Int] = []
    var pendingUnreadAfter: Int?
    func pendingUnreadAfterID(for type: GalleryMessageType) -> Int? { pendingUnreadAfter }
    func setPendingUnreadAfterID(_ id: Int?, for type: GalleryMessageType) -> Bool {
        guard saveSucceeds && !hasUnreadableSnapshot else { return false }
        pendingUnreadAfter = id
        return true
    }
    var unread = 7
    @discardableResult func replaceLatestIDs(_ ids: [Int], unreadCount: Int, for type: GalleryMessageType) -> Bool {
        guard saveSucceeds && !hasUnreadableSnapshot else { return false }
        latestIDs = ids
        changeSubject.send(currentSession)
        return true
    }
    @discardableResult func markSeen(ids: [Int], for type: GalleryMessageType) -> Bool {
        guard saveSucceeds && !hasUnreadableSnapshot else { return false }
        seenIDs = ids
        changeSubject.send(currentSession)
        return true
    }
    @discardableResult func markAllSeen(including ids: [Int], for type: GalleryMessageType) -> Bool {
        markSeen(ids: Array(Set(ids + latestIDs)).sorted(), for: type)
    }
    func unreadCount(for type: GalleryMessageType) -> Int { type == .comment ? unread : 0 }
    func isUnread(id: Int, for type: GalleryMessageType) -> Bool { id == 42 }
}

private struct RecordingMessageService: GalleryMessageServicing {
    func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts { .init() }
    func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
        try Self.messages([42])
    }
    static func messages(_ ids: [Int]) throws -> [GalleryMessage] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let rows = ids.map { "{\"from_user\":{},\"id\":\($0),\"link_obj\":\"poster\($0)\",\"obj\":\"poster\($0)\",\"text\":\"message\",\"update_time\":\"\"}" }
        return try decoder.decode([GalleryMessage].self, from: Data(("[" + rows.joined(separator: ",") + "]").utf8))
    }
}

private final class PagedMessageService: GalleryMessageServicing {
    var unread = 5
    var messageType: GalleryMessageType = .comment
    var requestedTypes: [GalleryMessageType] = []
    var failure: (any Error)?
    var laterPageFailure: (any Error)?
    var beforeLaterPage: (() async -> Void)?
    var beforeAcknowledgement: (() -> Void)?
    var beforeFirstPage: (() -> Void)?
    var beforeUnreadSummary: (() -> Void)?
    var identifiers = Array((1...6).reversed())
    var acknowledgementFailure: (any Error)?
    var postAcknowledgementFailure: (any Error)?
    private var hasAcknowledged = false
    var cursors: [Int?] = []
    func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts {
        if cursors.contains(Int.max), let beforeUnreadSummary { self.beforeUnreadSummary = nil; beforeUnreadSummary() }
        return .init(comment: messageType == .comment ? unread : 0, follow: messageType == .follow ? unread : 0,
            like: messageType == .like ? unread : 0, system: messageType == .system ? unread : 0,
            subscription: messageType == .subscription ? unread : 0)
    }
    func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
        cursors.append(lastID)
        requestedTypes.append(type)
        if let failure { throw failure }
        if lastID == Int.max, let beforeFirstPage { self.beforeFirstPage = nil; beforeFirstPage() }
        if lastID == nil {
            beforeAcknowledgement?(); unread = 0; hasAcknowledged = true
            if let acknowledgementFailure { throw acknowledgementFailure }
        } else if hasAcknowledged, let postAcknowledgementFailure { throw postAcknowledgementFailure }
        if lastID != nil && lastID != Int.max { await beforeLaterPage?() }
        if lastID != nil && lastID != Int.max, let laterPageFailure { throw laterPageFailure }
        return try RecordingMessageService.messages(Array(identifiers.filter { lastID == nil || $0 < (lastID ?? Int.max) }.prefix(2)))
    }
}

private final class SuspendedMessageDetails: GalleryPosterDetailServicing {
    func setSubscription(objectID: String, level: GallerySubscriptionLevel) async throws { throw URLError(.unsupportedURL) }
    var pending: [Int: CheckedContinuation<GalleryPosterDetail, Error>] = [:]
    func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
        try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func poster(_ id: Int) -> GalleryPosterDetail {
        GalleryPosterDetail(poster: CommunityPoster(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0,
            createTime: "", editTime: "", id: id, images: [], likeNum: 0, public: true, tags: [], text: "", title: "",
            updateTime: "", user: .init(id: 1, createTime: "", nickname: "", avatar: .init(mid: "", url: "", lowUrl: ""),
                motto: "", identity: .init(id: 0, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))))
    }
    func fetchComments(objectID: String, order: CommunityCommentOrder, page: Int?) async throws -> GalleryPageBatch<CommunityComment> { .init(items: [], nextSourcePage: 0, canLoadMore: false) }
    func like(objectID: String) async throws -> CommunityLikeResult { throw CancellationError() }
    func createComment(objectID: String, text: String, replyObjectID: String?, replyUID: Int?, anonymous: Bool, imageMids: [String]) async throws -> CommunityComment { throw CancellationError() }
    func deleteComment(id: Int) async throws {}
    func deletePoster(id: Int) async throws {}
}

private final class RecordingGalleryFeed: GalleryFeedServicing {
    var requests: [GalleryFeedKind] = []
    func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
        requests.append(kind)
        return .init(items: [], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
    }
    func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
        GalleryPageBatch<CommunityPoster>(items: [], nextSourcePage: sourcePage + 1, canLoadMore: false)
    }
    func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
        GalleryPageBatch<CommunityPoster>(items: [], nextSourcePage: startPage + 1, canLoadMore: false)
    }
    func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
        .init(items: [], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
    }
}

private final class RecordingCourseList: CourseListServicing {
    var requests: [String] = []
    func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
        requests.append(search)
        return []
    }
}

private final class RecordingPaperList: PaperListServicing {
    var requests = 0
    func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
        requests += 1
        return []
    }
    func fetchPaper(id: Int) async throws -> PaperDetail { throw CancellationError() }
    func fetchPreviewMetadata(id: Int) async throws -> PaperPreviewMetadata { throw CancellationError() }
}

private final class RecordingPaperComposer: PaperComposerServicing {
    var createdTitles: [String] = []
    var updatedIDs: [Int] = []
    var publicEditValues: [Bool] = []
    func createPaper(title: String, intro: String, content: String, anonymous: Bool, publicEdit: Bool) async throws -> Int {
        createdTitles.append(title)
        publicEditValues.append(publicEdit)
        return 42
    }
    func updatePaper(id: Int, title: String, intro: String, content: String, anonymous: Bool, publicEdit: Bool, lastUpdatedAt: String) async throws {
        updatedIDs.append(id)
        publicEditValues.append(publicEdit)
    }
}

private final class RecordingMineOverview: MineOverviewServicing {
    var requests = 0
    func fetchMyInfo() async throws -> MineUserInfo {
        requests += 1
        throw CancellationError()
    }
    func fetchFollowers(page: Int) async throws -> [CommunityUser] { [] }
    func fetchFollowings(page: Int) async throws -> [CommunityUser] { [] }
    func fetchMyPosters(page: Int) async throws -> [CommunityPoster] { [] }
}

private struct OfflineCommunityTransport: HTTPTransport {
    func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
        let result = try await data(for: request)
        if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
        return result
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw CancellationError()
    }
}
