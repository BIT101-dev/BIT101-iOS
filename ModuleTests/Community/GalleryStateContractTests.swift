import CommunityCore
import Foundation
import os
import Testing
@testable import GalleryFeature

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
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            .init(items: [GalleryStateContractTests.poster((page ?? 0) + 1)], nextSourcePage: (page ?? 0) + 1, canLoadMore: true)
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
            if failed { throw URLError(.notConnectedToInternet) }
            return try await fetchFeed(kind: .newest, page: page)
        }
    }

    private final class Report: GalleryReportServicing {
        var types: [GalleryReportType] = []
        var failed = false
        var submissions = 0
        var pending: CheckedContinuation<Void, Never>?
        func fetchReportTypes() async throws -> [GalleryReportType] {
            if failed { throw URLError(.notConnectedToInternet) }
            return types
        }
        func report(objectID: String, typeID: Int, text: String) async throws {
            submissions += 1
            await withCheckedContinuation { pending = $0 }
            try Task.checkCancellation()
        }
    }

    private static func poster(_ id: Int) -> CommunityPoster {
        .init(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0, createTime: "", editTime: "", id: id,
            images: [], likeNum: 0, public: true, tags: [], text: "", title: "帖子", updateTime: "",
            user: .placeholder(id: 1, nickname: "作者"))
    }

    @Test func failedSearchKeepsTheSuccessfulQueryAndPaginationSnapshot() async {
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

    @Test func memoryPressureReleasesInactiveFeedsAndRetainsTheActiveCursor() async {
        let model = GalleryViewModel(service: Feed())
        await model.refresh(feed: .newest)
        await model.refresh(feed: .follow)
        model.selectedFeed = .newest
        model.releaseInactiveFeeds()
        #expect(model.state(for: .follow).posters.isEmpty && model.state(for: .follow).status == .idle)
        #expect(model.state(for: .newest).posters.map(\.id) == [1] && model.state(for: .newest).nextPage == 1)
    }

    @Test func reportCategoriesRespectRemoteEmptyAndFailureResults() async throws {
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

    @Test(.timeLimit(.minutes(1)))
    func closingReportCancelsTheOwnedSubmissionAndItsLateCompletion() async throws {
        let service = Report()
        service.types = try JSONDecoder().decode([GalleryReportType].self, from: Data(#"[{"id":42,"text":"类型"}]"#.utf8))
        let model = GalleryReportViewModel(service: service)
        await model.loadReportTypes()
        let task = Task { await model.submit(objectID: "poster1") }
        while service.pending == nil { await Task.yield() }
        #expect(await model.submit(objectID: "poster1") == false && service.submissions == 1)
        model.cancel()
        service.pending?.resume()
        #expect(await task.value == false && model.errorMessage == nil && model.isSubmitting == false)
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
