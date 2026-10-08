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
    func draftWritesFinishBeforeCleanupAndPauseFurtherAccess(suggestion: Bool) async {
        let started = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            if started.withLock({ value in defer { value = true }; return !value }) { gate.wait() }
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
        let pending = Task { await save() }
        while !started.withLock({ $0 }) { await Task.yield() }
        var cleanupStarted = false
        let cleanup = Task { @MainActor in
            cleanupStarted = true
            await operations.suspendAndDrain()
            return files.removeContents(of: root)
        }
        while !cleanupStarted { await Task.yield() }
        #expect(await save() == false)
        gate.signal()
        let saved = await pending.value
        let cleaned = await cleanup.value
        #expect(saved && cleaned)
        #expect(files.storedData.isEmpty)
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
        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            requests.append(page)
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
    func cancellingArticleRefreshRetainsItsSuccessfulPagination(searching: Bool) async {
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
        while !service.enteredOrders.contains(.newest) { await Task.yield() }
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

    @Test(arguments: [false, true], [false, true])
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
    func articleReadsCancelWhenReplacedOrClosed(searching: Bool, closing: Bool) async {
        let service = PageAdvancementService()
        service.suspendedOrder = .newest
        let list = PaperListViewModel(service: service)
        let search = PaperSearchViewModel(service: service)
        search.searchText = "功能验收"
        let first = searching ? search.enqueueSearch() : list.enqueueRefresh()
        while !service.enteredOrders.contains(.newest) { await Task.yield() }
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
        while pendingFollow == nil { await Task.yield() }
        let refresh = Task { await model.refreshProfile() }
        while pendingRead == nil { await Task.yield() }
        if followFinishesFirst { pendingFollow?.resume(); await following.value; pendingRead?.resume(); await refresh.value }
        else { pendingRead?.resume(); await refresh.value; pendingFollow?.resume(); await following.value }
        #expect(model.userInfo?.user.nickname == "已刷新")
        #expect(model.userInfo?.following == true && model.userInfo?.followerNum == 5)
        #expect(model.isFollowingUser == false && model.alert == nil)
        await model.followUser()
        #expect(service.followingRequests == 1)
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

    @Test func messagesCaptureTheUnreadWindowAcrossSourcePagesAndRetainHistoricalPaging() async throws {
        let domain = "BIT101ModulesTests.message-window"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "message-window")
        let store = GalleryMessageReadStore(defaults: defaults, session: { session })
        let service = PagedMessageService()
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        await model.refresh(type: .comment)
        #expect(service.cursors == [nil, 5, 3])
        #expect(model.state(for: .comment).items.map(\.id) == [6, 5, 4, 3, 2, 1])
        #expect(model.unreadCount(for: .comment) == 5)
        #expect(model.isUnread(try #require(model.state(for: .comment).items.first(where: { $0.id == 2 })), in: .comment))
        #expect(!model.isUnread(try #require(model.state(for: .comment).items.last), in: .comment))
        await model.loadMoreIfNeeded(for: .comment, currentMessage: model.state(for: .comment).items.last)
        #expect(service.cursors == [nil, 5, 3, 1])
        #expect(!model.state(for: .comment).canLoadMore)
        await model.refresh(type: .comment)
        #expect(store.unreadCount(for: .comment) == 5)
        let before = model.state(for: .comment)
        for error in [URLError(.timedOut) as any Error, CancellationError()] {
            model.alert = nil
            service.failure = error
            await model.refresh(type: .comment)
            let current = model.state(for: .comment)
            #expect(current.status == .loaded && current.items.map(\.id) == before.items.map(\.id))
            #expect(current.nextCursor == before.nextCursor && current.canLoadMore == before.canLoadMore)
            #expect(!current.isLoadingMore)
            #expect(model.alert?.title == (error is CancellationError ? nil : "加载消息失败"))
        }
        service.failure = nil
        await model.refresh(type: .comment)
        #expect(model.state(for: .comment).status == .loaded)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["replacement", "cancel", "account", "error"])
    func messageNavigationKeepsTheLatestIntentAndReportsTheActualFailure(boundary: String) async throws {
        let store = RecordingMessageReadStore()
        let model = GalleryMessageViewModel(service: RecordingMessageService(), readStore: store)
        let details = SuspendedMessageDetails()
        let messages = try RecordingMessageService.messages([1, 2])
        let first = Task { await model.openMessage(messages[0], in: .comment, using: details) }
        while details.pending[1] == nil { await Task.yield() }
        if boundary == "replacement" {
            let second = Task { await model.openMessage(messages[1], in: .comment, using: details) }
            while details.pending[2] == nil { await Task.yield() }
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

    @Test func courseEvaluationFactoryUsesTheInjectedListService() async throws {
        let list = RecordingCourseList()
        let dependencies = CourseDependencies(
            list: list, detail: CourseService(session: session), preferences: preferences, loadCourseCredits: { [] }
        )
        let result = try await dependencies.makeEvaluationResolver().resolve(courseName: "高等数学", courseNumber: "MATH")
        #expect(result == nil)
        #expect(Set(list.requests) == ["MATH", "高等数学"])
    }

    @Test func galleryFeedUsesTheInjectedSceneService() async {
        let feed = RecordingGalleryFeed()
        let viewModel = GalleryViewModel(service: feed)
        await viewModel.refresh(feed: .newest)

        #expect(feed.requests == [.newest])
        #expect(viewModel.state(for: .newest).status == .loaded)
    }

    @Test func galleryMessagesUseIndependentReadPortsAndScopedChanges() async throws {
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
        #expect(store.latestIDs == [42])
        model.markCurrentTypeAsRead()
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
    func unreadSummaryRejectsLateResponsesAfterReplacementClearOrCancellation(boundary: String) async {
        let service = DelayedUnreadService()
        let store = RecordingMessageReadStore()
        store.unread = 0
        let model = GalleryMessageViewModel(service: service, readStore: store)
        let old = Task { await model.refreshUnreadCounts() }
        while service.pending == nil { await Task.yield() }
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

    @Test func courseListAndCreditQueryUseIndependentInjections() async {
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

    @Test func paperListAndComposerUseSeparateSceneServices() async throws {
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

    @Test func mineOverviewPreservesInjectedCancellationSemantics() async {
        let overview = RecordingMineOverview()
        let dependencies = MineDependencies(
            overview: overview, profile: MineService(session: session, preferences: { self.preferences.snapshot }),
            deletePoster: { _ in }, isRunningUITest: true
        )
        let viewModel = MineViewModel(service: dependencies.overview)
        await viewModel.refreshProfile()

        #expect(overview.requests == 1)
        #expect(viewModel.profileStatus == .idle)
        #expect(viewModel.alert == nil)
        #expect(dependencies.isRunningUITest)
    }

    @Test func mineDeletionUsesItsInjectedBusinessAction() async throws {
        var deletedIDs: [Int] = []
        let dependencies = MineDependencies(
            overview: RecordingMineOverview(),
            profile: MineService(session: session, preferences: { self.preferences.snapshot }),
            deletePoster: { deletedIDs.append($0) }, isRunningUITest: true
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
    let changeSubject = PassthroughSubject<AppStorageSession, Never>()
    var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
    var latestIDs: [Int] = []
    var seenIDs: [Int] = []
    var unread = 7
    func replaceLatestIDs(_ ids: [Int], unreadCount: Int, for type: GalleryMessageType) {
        latestIDs = ids
        changeSubject.send(currentSession)
    }
    func markSeen(ids: [Int], for type: GalleryMessageType) {
        seenIDs = ids
        changeSubject.send(currentSession)
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
    var failure: (any Error)?
    var cursors: [Int?] = []
    func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts { .init(comment: unread) }
    func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
        cursors.append(lastID)
        if let failure { throw failure }
        unread = 0
        return try RecordingMessageService.messages(lastID == nil ? [6, 5] : lastID == 5 ? [4, 3] : lastID == 3 ? [2, 1] : [])
    }
}

private final class SuspendedMessageDetails: GalleryPosterDetailServicing {
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
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw CancellationError()
    }
}
