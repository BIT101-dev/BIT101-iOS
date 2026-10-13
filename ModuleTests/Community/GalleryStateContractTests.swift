import BIT101TestSupport
import CommunityCore
import CommunityTransport
import Foundation
import os
import Testing
@testable import GalleryFeature
@testable import MineFeature

@MainActor
struct GalleryStateContractTests {
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
        var pending: CheckedContinuation<Void, Never>?
        var failure: (any Error)?
        func fetchReportTypes() async throws -> [GalleryReportType] {
            if failed { throw URLError(.notConnectedToInternet) }
            return types
        }
        func report(objectID: String, typeID: Int, text: String) async throws {
            submissions += 1
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
        #expect(model.searchState.nextPage == previous.nextPage && model.searchState.canLoadMore)
        service.failed = false
        await model.loadMoreSearchResultsIfNeeded(currentPoster: previous.posters.last)
        #expect(service.queryLog.last?.text == "原查询" && model.searchState.posters.map(\.id) == [1, 2])
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
        service.types = try JSONDecoder().decode([GalleryReportType].self, from: Data(#"[{"id":42,"text":"服务端类型"}]"#.utf8))
        await model.loadReportTypes()
        #expect(model.selectedTypeID == 42 && model.errorMessage == nil)
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
