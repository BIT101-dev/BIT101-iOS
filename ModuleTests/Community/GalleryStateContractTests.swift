import BIT101TestSupport
import CommunityCore
import CommunityTransport
import CommunityUI
import Foundation
import os
import Testing
@testable import GalleryFeature
@testable import MineFeature

@MainActor
struct GalleryStateContractTests {
    @Test(.timeLimit(.minutes(1))) func detailReappearancePreservesCommentsAndWriteReview() async {
        let service = SubscriptionDetails()
        let user = CommunityUser.placeholder(id: 7, nickname: "用户")
        service.comments = [.init(id: 1, obj: "poster1", images: [], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: false, rate: 0,
            replyUser: user, replyObj: "", text: "已加载评论", sub: [])]
        let model = GalleryPosterDetailViewModel(initialPoster: listPoster(1), service: service)
        var preferences = CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
            useWebView: false, hideMakeupOutliers: false)
        await model.loadContent(filter: .init(preferences: preferences))
        service.creationFailure = CommunityCreateOutcomeUnknown(underlying: URLError(.networkConnectionLost))
        let target = CommunityCommentComposerTarget.poster(posterID: 1)
        #expect(await model.submitComment(text: "待确认评论", anonymous: false, target: target) == false)
        let submission = CommunityCommentSubmission(objectID: "poster1", text: "待确认评论", anonymous: false,
            replyObjectID: nil, replyUID: nil)
        #expect(model.commentReview.needsReview(submission))
        service.commentFailure = URLError(.notConnectedToInternet)
        let requests = service.commentRequests
        preferences.galleryUseWebView = true
        await model.loadContent(filter: .init(preferences: preferences))
        #expect(model.commentState.items.map(\.id) == [1] && model.commentReview.needsReview(submission))
        #expect(service.commentRequests == requests)
        preferences.galleryHiddenUserIDs = [7]
        await model.loadContent(filter: .init(preferences: preferences))
        #expect(model.commentState.items.isEmpty && model.commentReview.needsReview(submission))
        service.commentFailure = nil
        service.comments = []
        let posterRequests = service.posterRequests
        await model.retryFailedContentIfNeeded()
        #expect(model.commentState.status == .loaded && service.posterRequests == posterRequests)
    }

    @Test(.timeLimit(.minutes(1))) func returningToSubscriptionsPreservesTheLoadedPages() async {
        let service = Subscriptions()
        service.pages = [0: [subscription(1)], 1: [subscription(2)]]
        let model = GallerySubscriptionsViewModel(service: service)
        await model.bootstrapIfNeeded()
        await model.loadMore()
        await model.bootstrapIfNeeded()
        #expect(service.requests == [0, 1] && model.items.map(\.id) == [1, 2])
    }

    private final class Subscriptions: GallerySubscriptionServicing {
        var pages: [Int: [GallerySubscription]] = [:]
        var failedPage: Int?
        var gate: ListRequestGate<[GallerySubscription]>?
        var requests: [Int] = []
        func fetchSubscriptions(page: Int) async throws -> [GallerySubscription] {
            requests.append(page)
            if failedPage == page { throw URLError(.notConnectedToInternet) }
            if page > 0, let gate { return try await gate.request() }
            return pages[page] ?? []
        }
    }

    private func subscription(_ id: Int) -> GallerySubscription {
        .init(id: id, subscriptionTime: "", obj: "poster\(id)", level: .silent, text: "话题\(id)")
    }

    private final class SubscriptionDetails: GalleryPosterDetailServicing {
        var poster = GalleryPosterDetail(poster: listPoster(1)).updatingSubscription(.none)
        var failure: (any Error)?
        var writeGate: ListRequestGate<Void>?
        var readGate: ListRequestGate<GalleryPosterDetail>?
        var writes = 0
        var readFailure: (any Error)?
        var comments: [CommunityComment] = []
        var commentFailure: (any Error)?
        var creationFailure: any Error = URLError(.unsupportedURL)
        var commentRequests = 0
        var posterRequests = 0
        func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
            posterRequests += 1
            if let readFailure { throw readFailure }
            if let readGate { return try await readGate.request() }
            return poster
        }
        func setSubscription(objectID: String, level: GallerySubscriptionLevel) async throws {
            writes += 1
            if let failure { throw failure }
            if let writeGate { try await writeGate.request() }
            poster = poster.updatingSubscription(level)
        }
        func fetchComments(objectID: String, order: CommunityCommentOrder, page: Int?) async throws -> GalleryPageBatch<CommunityComment> {
            commentRequests += 1
            if let commentFailure { throw commentFailure }
            return .init(items: comments, nextSourcePage: 0, canLoadMore: false)
        }
        func like(objectID: String) async throws -> CommunityLikeResult { throw URLError(.unsupportedURL) }
        func createComment(objectID: String, text: String, replyObjectID: String?, replyUID: Int?, anonymous: Bool, imageMids: [String]) async throws -> CommunityComment { throw creationFailure }
        func deleteComment(id: Int) async throws { throw URLError(.unsupportedURL) }
        func deletePoster(id: Int) async throws { throw URLError(.unsupportedURL) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func detailRefreshFailurePreservesConfirmedSubscriptionActions(loaded: Bool) async {
        let service = SubscriptionDetails()
        let model = GalleryPosterDetailViewModel(initialPoster: listPoster(1), service: service)
        if loaded { await model.refreshAll() }
        service.readFailure = URLError(.timedOut)
        await model.refreshAll()
        #expect(model.alert?.title == "加载帖子失败")
        #expect(model.posterStatus == (loaded ? .loaded : .failed(URLError(.timedOut).localizedDescription)))
        #expect(await model.setSubscription(.comment) == loaded)
        #expect(service.writes == (loaded ? 1 : 0))
        service.readFailure = nil
        await model.refreshAll()
        #expect(model.posterStatus == .loaded)
        #expect(await model.setSubscription(.update))
    }

    @Test(.timeLimit(.minutes(1)))
    func subscriptionWriteFailuresKeepConfirmedStateAndCanBeRetried() async {
        let service = SubscriptionDetails()
        let model = GalleryPosterDetailViewModel(initialPoster: listPoster(1), service: service)
        await model.refreshAll()
        #expect(await model.setSubscription(.silent))
        service.failure = URLError(.networkConnectionLost)
        #expect(await model.setSubscription(.update) == false)
        #expect(model.poster.subscription == .silent && !model.isSavingSubscription && model.alert != nil)
        service.failure = nil
        #expect(await model.setSubscription(.update))
        #expect(model.poster.subscription == .update && service.writes == 3)
        #expect(model.poster.updatingLike(true, likeNum: 1).subscription == .update)
    }

    @Test(.timeLimit(.minutes(1)))
    func subscriptionSaveSurvivesAnOlderRefreshAndSerializesRepeatedTaps() async throws {
        let service = SubscriptionDetails()
        let model = GalleryPosterDetailViewModel(initialPoster: listPoster(1), service: service)
        await model.refreshAll()
        let oldPoster = service.poster
        let write = ListRequestGate<Void>(), read = ListRequestGate<GalleryPosterDetail>()
        service.writeGate = write
        let saving = Task { await model.setSubscription(.comment) }
        try await write.waitUntilRequested()
        #expect(await model.setSubscription(.silent) == false && service.writes == 1)
        service.readGate = read
        let refresh = Task { await model.refreshAll() }
        try await read.waitUntilRequested()
        write.finish(())
        #expect(await saving.value)
        read.finish(oldPoster)
        await refresh.value
        #expect(model.poster.subscription == .comment && model.posterStatus == .loaded)
    }

    @Test(.timeLimit(.minutes(1)))
    func subscriptionPaginationDeduplicatesAndRetainsFailedPageForRetry() async {
        let service = Subscriptions()
        service.pages = [0: [subscription(1)], 1: [subscription(1), subscription(2)]]
        let model = GallerySubscriptionsViewModel(service: service)
        await model.refresh()
        service.failedPage = 1
        await model.loadMore()
        #expect(model.items.map(\.id) == [1] && model.canLoadMore && !model.isLoadingMore && model.alert != nil)
        service.failedPage = nil
        await model.loadMore()
        #expect(model.items.map(\.id) == [1, 2] && service.requests == [0, 1, 1])
        await model.loadMore()
        #expect(!model.canLoadMore && model.status == .loaded)
        service.pages[0] = []
        await model.refresh()
        #expect(model.items.isEmpty && !model.canLoadMore && model.status == .loaded)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func subscriptionDuplicatePagesAdvanceWithinTheSharedProgressBound(stalled: Bool) async {
        let service = Subscriptions()
        service.pages = Dictionary(uniqueKeysWithValues: (0...4).map { ($0, [subscription(1)]) })
        if !stalled { service.pages[3] = [subscription(2)] }
        let model = GallerySubscriptionsViewModel(service: service)
        await model.refresh()
        await model.loadMore()
        #expect(service.requests == (stalled ? [0, 1, 2, 3, 4] : [0, 1, 2, 3]))
        #expect(model.items.map(\.id) == (stalled ? [1] : [1, 2]))
        if stalled {
            #expect(model.alert != nil && !model.isLoadingMore && model.canLoadMore)
            service.pages[4] = [subscription(2)]
            await model.loadMore()
            #expect(service.requests.last == 4 && model.items.map(\.id) == [1, 2])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func subscriptionRefreshSupersedesAnOlderNextPage() async throws {
        let service = Subscriptions()
        service.pages[0] = [subscription(1)]
        let model = GallerySubscriptionsViewModel(service: service)
        await model.refresh()
        let gate = ListRequestGate<[GallerySubscription]>()
        service.gate = gate
        let page = Task { await model.loadMore() }
        try await gate.waitUntilRequested()
        service.pages[0] = [subscription(2)]
        await model.refresh()
        gate.finish([subscription(3)])
        await page.value
        #expect(model.items.map(\.id) == [2] && model.status == .loaded && !model.isLoadingMore)
        service.failedPage = 0
        await model.refresh()
        #expect(model.items.map(\.id) == [2] && model.alert != nil && model.status == .loaded)
    }

    private nonisolated struct IndexedItem: Identifiable {
        let value: Int
        let reads: OSAllocatedUnfairLock<Int>
        var id: Int { reads.withLock { $0 += 1 }; return value }
    }
    private final class Feed: GalleryFeedServicing {
        var queryLog: [GallerySearchQuery] = []
        var failed = false
        var repeated = false
        var recommendRequests: [Int] = []
        var searchRequests: [Int] = []
        var searchPages: [Int: GalleryPageBatch<CommunityPoster>] = [:]
        var failedSearchPage: Int?
        var totalPages: Int?
        var body = ""
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            let page = page ?? 0
            if let totalPages {
                let items = (page * 100 + 1 ... (page + 1) * 100).map { GalleryStateContractTests.poster($0, text: body) }
                return .init(items: items, nextSourcePage: page + 1, canLoadMore: page + 1 < totalPages)
            }
            return .init(items: [GalleryStateContractTests.poster(page + 1)], nextSourcePage: page + 1, canLoadMore: true)
        }
        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            recommendRequests.append(sourcePage)
            return .init(items: [GalleryStateContractTests.poster(repeated ? 1 : sourcePage + 1)], nextSourcePage: sourcePage + 1, canLoadMore: true)
        }
        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            try await fetchFeed(kind: .bot, page: startPage)
        }
        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            queryLog.append(query)
            let sourcePage = page ?? 0
            searchRequests.append(sourcePage)
            if failed || failedSearchPage == sourcePage { throw URLError(.notConnectedToInternet) }
            if let batch = searchPages[sourcePage] { return batch }
            return try await fetchFeed(kind: .newest, page: page)
        }
    }

    private final class Report: GalleryReportServicing {
        var types: [GalleryReportType] = []
        var failed = false
        var submissions = 0
        var submitted: (objectID: String, typeID: Int, text: String)?
        var pending: CheckedContinuation<Void, Never>?
        var failure: (any Error)?
        func fetchReportTypes() async throws -> [GalleryReportType] {
            if failed { throw URLError(.notConnectedToInternet) }
            return types
        }
        func report(objectID: String, typeID: Int, text: String) async throws {
            submissions += 1
            submitted = (objectID, typeID, text)
            if let failure { throw failure }
            await withCheckedContinuation { pending = $0 }
            try Task.checkCancellation()
        }
    }

    private static func poster(_ id: Int, text: String = "") -> CommunityPoster {
        .init(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0, createTime: "", editTime: "", id: id,
            images: [], likeNum: 0, public: true, tags: [], text: text, title: "帖子", updateTime: "",
            user: .placeholder(id: 1, nickname: "作者"))
    }

    @Test(.timeLimit(.minutes(1))) func failedSearchKeepsTheSuccessfulQueryAndPaginationSnapshot() async {
        let service = Feed()
        let model = GalleryViewModel(service: service)
        model.searchQuery.text = "原查询"
        await model.performSearch()
        let previous = model.searchState
        model.searchQuery.text = "新查询"
        service.failed = true
        await model.performSearch()
        #expect(model.searchState.posters == previous.posters && model.searchState.status == .loaded)
        #expect(model.displayedQueryDescription == "“原查询”的话题 · 最新")
        #expect(model.searchState.nextPage == previous.nextPage && model.searchState.canLoadMore)
        service.failed = false
        await model.loadMoreSearchResultsIfNeeded(currentPoster: previous.posters.last)
        #expect(service.queryLog.last?.text == "原查询" && model.searchState.posters.map(\.id) == [1, 2])
        await model.performSearch()
        #expect(model.displayedQueryDescription == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func feedAndSearchAppendLongBodiesThroughTheirActualViewModel(search: Bool) async {
        let service = Feed()
        service.totalPages = 200
        service.body = String(repeating: "正文", count: 4_096)
        let model = GalleryViewModel(service: service)
        if search { await model.performSearch() }
        else { await model.refresh(feed: .newest) }
        for _ in 1..<200 {
            if search { await model.loadMoreSearchResultsIfNeeded(currentPoster: model.searchState.posters.last) }
            else { await model.loadMoreIfNeeded(for: .newest, currentPoster: model.state(for: .newest).posters.last) }
        }
        let state = search ? model.searchState : model.state(for: .newest)
        #expect(state.posters.map(\.id) == Array(1...20_000))
        #expect(state.nextPage == 200 && !state.canLoadMore && !state.isLoadingMore && model.alert == nil)
        #expect(state.posters.first?.text == service.body && state.posters.last?.text == service.body)
    }

    @Test(.timeLimit(.minutes(1)))
    func searchPaginationCrossesDuplicatePagesAndStopsAtTheEnd() async {
        let service = Feed()
        service.searchPages = [0: .init(items: [Self.poster(1)], nextSourcePage: 1, canLoadMore: true),
            1: .init(items: [Self.poster(1)], nextSourcePage: 2, canLoadMore: true),
            2: .init(items: [Self.poster(2)], nextSourcePage: 3, canLoadMore: true),
            3: .init(items: [], nextSourcePage: 4, canLoadMore: false)]
        let model = GalleryViewModel(service: service)
        model.searchQuery.text = "搜索"
        await model.performSearch()
        await model.loadMoreSearchResultsIfNeeded(currentPoster: Self.poster(1))
        #expect(model.searchState.posters.map(\.id) == [1, 2] && model.searchState.nextPage == 3)
        #expect(service.searchRequests == [0, 1, 2] && model.alert == nil)
        await model.loadMoreSearchResultsIfNeeded(currentPoster: Self.poster(2))
        #expect(service.searchRequests == [0, 1, 2, 3])
        #expect(model.searchState.posters.map(\.id) == [1, 2] && !model.searchState.canLoadMore && !model.searchState.isLoadingMore)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["repeated", "stalled", "failed"])
    func searchPaginationFailuresKeepTheRetryPosition(scenario: String) async {
        let service = Feed()
        for page in 0...4 {
            service.searchPages[page] = .init(items: [Self.poster(1)],
                nextSourcePage: scenario == "stalled" && page == 1 ? 1 : page + 1, canLoadMore: true)
        }
        if scenario == "failed" { service.failedSearchPage = 2 }
        let model = GalleryViewModel(service: service)
        model.searchQuery.text = "搜索"
        await model.performSearch()
        await model.loadMoreSearchResultsIfNeeded(currentPoster: Self.poster(1))
        #expect(model.searchState.posters.map(\.id) == [1] && model.searchState.nextPage == 1)
        #expect(!model.searchState.isLoadingMore && model.searchState.canLoadMore && model.alert != nil)
        #expect(service.searchRequests == (scenario == "repeated" ? [0, 1, 2, 3, 4] : scenario == "stalled" ? [0, 1] : [0, 1, 2]))
        service.failedSearchPage = nil
        service.searchPages[1] = .init(items: [Self.poster(2)], nextSourcePage: 2, canLoadMore: false)
        await model.loadMoreSearchResultsIfNeeded(currentPoster: Self.poster(1))
        #expect(model.searchState.posters.map(\.id) == [1, 2] && model.searchState.nextPage == 2)
        #expect(service.searchRequests.last == 1 && !model.searchState.canLoadMore && !model.searchState.isLoadingMore)
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedRecommendPagesPreserveTheRetryPosition() async {
        let service = Feed()
        service.repeated = true
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .recommend)
        await model.loadMoreIfNeeded(for: .recommend, currentPoster: Self.poster(1))
        let state = model.state(for: .recommend)
        #expect(state.posters.map(\.id) == [1] && state.isLoadingMore == false && state.nextPage == 1)
        #expect(model.alert != nil && service.recommendRequests.allSatisfy { $0 <= 4 })
        model.cancelPendingOperations()
    }

    @Test(.timeLimit(.minutes(1))) func memoryPressureReleasesInactiveFeedsAndRetainsTheActiveCursor() async {
        let model = GalleryViewModel(service: Feed())
        await model.refresh(feed: .newest)
        await model.refresh(feed: .follow)
        model.selectedFeed = .newest
        model.releaseInactiveFeeds()
        #expect(model.state(for: .follow).posters.isEmpty && model.state(for: .follow).status == .idle)
        #expect(model.state(for: .newest).posters.map(\.id) == [1] && model.state(for: .newest).nextPage == 1)
    }

    @Test(.timeLimit(.minutes(1))) func reportCategoriesRespectRemoteEmptyAndFailureResults() async throws {
        let service = Report()
        let model = GalleryReportViewModel(service: service)
        await model.loadReportTypes()
        #expect(model.reportTypes.isEmpty && model.selectedTypeID == nil)
        #expect(await model.submit(objectID: "poster1") == false && service.submissions == 0)
        service.failed = true
        await model.loadReportTypes()
        #expect(model.errorMessage != nil && model.selectedTypeID == nil)
        service.failed = false
        service.types = try JSONDecoder().decode([GalleryReportType].self,
            from: Data(#"[{"id":42,"text":" 服务端类型\n"},{"id":42,"text":"重复类型"},{"id":7,"text":" "},{"id":7,"text":"其他类型"}]"#.utf8))
        await model.loadReportTypes()
        #expect(model.reportTypes.map(\.id) == [42, 7] && model.selectedTypeID == 42 && model.errorMessage == nil)
        #expect(model.reportTypes.map(\.text) == ["服务端类型", "其他类型"])
        #expect(!model.isLoading && !model.isSubmitting)
        model.selectedTypeID = 999
        #expect(await model.submit(objectID: "poster1") == false && service.submissions == 0)
        model.selectedTypeID = 7
        model.text = "  举报说明\n"
        let submission = Task { await model.submit(objectID: "poster1") }
        try await waitForTestEvent { service.pending != nil }
        #expect(model.isSubmitting && service.submissions == 1)
        let pending = try #require(service.pending)
        service.pending = nil
        pending.resume()
        #expect(await submission.value)
        #expect(service.submitted?.objectID == "poster1" && service.submitted?.typeID == 7)
        #expect(service.submitted?.text == "举报说明" && !model.isSubmitting && model.errorMessage == nil)
    }

    @Test(.timeLimit(.minutes(1))) func reportResponseLossPausesRepeatedSubmission() async throws {
        let service = Report()
        service.types = try JSONDecoder().decode([GalleryReportType].self, from: Data(#"[{"id":42,"text":"类型"}]"#.utf8))
        service.failure = CommunityCreateOutcomeUnknown(underlying: URLError(.networkConnectionLost))
        let model = GalleryReportViewModel(service: service)
        await model.loadReportTypes()
        #expect(await model.submit(objectID: "poster1") == false)
        #expect(model.resultNeedsReview && model.errorMessage == CommunityCreateOutcomeUnknown.reportReviewMessage)
        #expect(await model.submit(objectID: "poster1") == false && service.submissions == 1)
        await model.loadReportTypes()
        #expect(model.resultNeedsReview && model.errorMessage != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func closingReportCancelsTheOwnedSubmissionAndItsLateCompletion() async throws {
        let service = Report()
        service.types = try JSONDecoder().decode([GalleryReportType].self, from: Data(#"[{"id":42,"text":"类型"}]"#.utf8))
        let model = GalleryReportViewModel(service: service)
        await model.loadReportTypes()
        let task = Task { await model.submit(objectID: "poster1") }
        try await waitForTestEvent { !(service.pending == nil) }
        #expect(await model.submit(objectID: "poster1") == false && service.submissions == 1)
        model.cancel()
        service.pending?.resume()
        #expect(await task.value == false && model.errorMessage == nil && model.isSubmitting == false)
    }

    @Test func minePaginationReadsEachIncomingIDOnce() {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        var state = MinePagedState<IndexedItem>()
        for page in 0..<1_000 {
            state.appendPage((page * 100 ..< (page + 1) * 100).map { IndexedItem(value: $0, reads: reads) })
        }
        #expect(reads.withLock { $0 } == 100_000 && state.items.count == 100_000)
        state.resetPagination()
        state.applyFirstPage([IndexedItem(value: 1, reads: reads), IndexedItem(value: 1, reads: reads)])
        state.appendPage([IndexedItem(value: 2, reads: reads)])
        #expect(state.items.map(\.id) == [1, 2])
    }

    @Test(.timeLimit(.minutes(1)))
    func largePaginationKeepsAnIncrementalIndexAndStableOrder() {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        func item(_ value: Int) -> IndexedItem { .init(value: value, reads: reads) }
        var storage = CommunityPagedItems<IndexedItem>()
        for page in 0..<1_000 { storage.append((page * 100 ..< (page + 1) * 100).map(item)) }
        storage.append((0..<100_000).map(item))
        #expect(reads.withLock { $0 } == 200_000)
        #expect(storage.items.map(\.id) == Array(0..<100_000) && storage.ids.count == 100_000)
        storage.replace(with: [item(5)])
        storage.append([item(0), item(5)])
        #expect(storage.items.map(\.id) == [5, 0] && storage.ids == [0, 5])
    }
}
