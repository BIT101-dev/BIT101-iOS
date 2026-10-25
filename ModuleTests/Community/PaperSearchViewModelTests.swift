import TransportCore
import CommunityCore
import DesignSystemKit
@testable import PaperFeature
@testable import CourseFeature
@testable import GalleryFeature
@testable import MineFeature
import Foundation
import Testing

@Suite("Paper search state machine")
struct PaperSearchViewModelTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
    func refreshReusesAuthorsUntilTheArticleVersionChanges(search: Bool) async throws {
        let paper = PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "version-a")
        let service = ServiceStub(result: .success([paper]))
        let model: PaperCollectionViewModel = search ? PaperSearchViewModel(service: service) : PaperListViewModel(service: service)
        model.searchText = "fixture"
        service.metadata = { _ in
            PaperDetail(id: 1, title: "fixture", intro: "", content: "", createTime: "", updateTime: "version-a",
                updateUser: listUser(1), anonymous: false, likeNum: 0, commentNum: 0, publicEdit: true, like: false, own: true)
        }
        await model.refresh(); await model.loadPreviewMetadataIfNeeded(for: paper)
        let author = try #require(model.previewMetadata(for: paper.id))
        await model.refresh(); await model.loadPreviewMetadataIfNeeded(for: paper)
        #expect(model.previewMetadata(for: paper.id) == author && service.metadataRequests == 1)
        service.result = .failure(URLError(.timedOut))
        await model.refresh()
        #expect(model.previewMetadata(for: paper.id) == author)
        service.result = .success([.init(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "version-b")])
        await model.refresh()
        #expect(model.previewMetadata(for: paper.id) == nil)
        await model.loadPreviewMetadataIfNeeded(for: paper)
        #expect(service.metadataRequests == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
    func refreshingKeepsDisplayedAuthorsUntilTheNewFirstPageArrives(search: Bool) async throws {
        let paper = PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        let service = ServiceStub(result: .success([paper]))
        let model: PaperCollectionViewModel = search ? PaperSearchViewModel(service: service) : PaperListViewModel(service: service)
        model.searchText = "fixture"
        service.metadata = { _ in
            return PaperDetail(id: 1, title: "fixture", intro: "", content: "", createTime: "", updateTime: "",
                updateUser: listUser(1), anonymous: false, likeNum: 0, commentNum: 0, publicEdit: true, like: false, own: true)
        }
        await model.refresh()
        await model.loadPreviewMetadataIfNeeded(for: paper)
        let author = try #require(model.previewMetadata(for: paper.id))
        let gate = ListRequestGate<[PaperSummary]>()
        service.fetch = { try await gate.request() }
        let refreshing = Task { await model.refresh() }
        try await gate.waitUntilRequested()
        #expect(model.previewMetadata(for: paper.id) == author)
        await model.loadPreviewMetadataIfNeeded(for: paper)
        #expect(service.metadataRequests == 1)
        gate.finish([paper])
        await refreshing.value
        #expect(model.previewMetadata(for: paper.id) == nil)
        await model.loadPreviewMetadataIfNeeded(for: paper)
        #expect(service.metadataRequests == 2)
    }

    private final class ServiceStub: PaperListServicing {
        private(set) var requests: [(search: String?, order: PaperSortOrder, page: Int)] = []
        private(set) var metadataRequests = 0
        var result: Result<[PaperSummary], Error>
        var fetch: (() async throws -> [PaperSummary])?
        var metadata: (Int) async throws -> PaperDetail = { _ in throw URLError(.unsupportedURL) }

        init(result: Result<[PaperSummary], Error>) { self.result = result }

        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
            requests.append((search, order, page))
            if let fetch { return try await fetch() }
            return try result.get()
        }

        func fetchPaper(id: Int) async throws -> PaperDetail {
            try await metadata(id)
        }
        func fetchPreviewMetadata(id: Int) async throws -> PaperPreviewMetadata {
            metadataRequests += 1
            return try await fetchPaper(id: id).previewMetadata
        }
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func listPaginationKeepsTheSuccessfulConditionsAfterEditingAndRefreshFailure() async {
        let paper = PaperSummary(id: 1, title: "A", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        let service = ServiceStub(result: .success([paper]))
        let model = PaperListViewModel(service: service)
        model.searchText = "A"; model.selectedOrder = .like
        await model.refresh()
        model.searchText = "B"; model.selectedOrder = .newest
        service.result = .failure(URLError(.timedOut))
        await model.refresh()
        #expect(model.displayedQueryDescription == "“A”的文章 · 高赞")
        service.result = .success([])
        await model.loadMoreIfNeeded(currentPaper: paper)
        #expect(service.requests.last?.search == "A" && service.requests.last?.order == .like)
        #expect(service.requests.last?.page == 1 && model.state.items == [paper])
        await model.refresh()
        #expect(model.displayedQueryDescription == nil)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func searchPaginationKeepsItsSubmittedConditionsWhileEditing() async {
        let paper = PaperSummary(id: 1, title: "A", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        let service = ServiceStub(result: .success([paper]))
        let model = PaperSearchViewModel(service: service)
        model.searchText = "A"; model.selectedOrder = .like
        await model.performSearch()
        model.searchText = "B"; model.selectedOrder = .newest
        #expect(model.displayedQueryDescription == "“A”的文章 · 高赞")
        service.result = .success([])
        await model.loadMoreIfNeeded(currentPaper: paper)
        #expect(service.requests.last?.search == "A" && service.requests.last?.order == .like)
        #expect(service.requests.last?.page == 1 && model.state.items == [paper])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true]) @MainActor
    func metadataRefreshRejectsEarlierRequestsAndReflectsAnonymity(search: Bool, staleFailure: Bool) async throws {
        let paper = PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        let service = ServiceStub(result: .success([paper]))
        let original = PaperDetail(id: 1, title: "fixture", intro: "", content: "", createTime: "", updateTime: "",
            updateUser: listUser(1), anonymous: false, likeNum: 0, commentNum: 0, publicEdit: true, like: false, own: true)
        let edited = PaperDetail(id: 1, title: "fixture", intro: "", content: "", createTime: "", updateTime: "",
            updateUser: listUser(2), anonymous: true, likeNum: 0, commentNum: 0, publicEdit: true, like: false, own: true)
        let list = PaperListViewModel(service: service)
        let results = PaperSearchViewModel(service: service)
        results.searchText = "fixture"
        let refresh: @MainActor () async -> Void
        let load: @MainActor () async -> Void
        let preview: @MainActor () -> PaperPreviewMetadata?
        if search {
            refresh = { await results.performSearch() }
            load = { await results.loadPreviewMetadataIfNeeded(for: paper) }
            preview = { results.previewMetadata(for: paper.id) }
        } else {
            refresh = { await list.refresh() }
            load = { await list.loadPreviewMetadataIfNeeded(for: paper) }
            preview = { list.previewMetadata(for: paper.id) }
        }
        service.metadata = { _ in original }
        await refresh(); await load()
        #expect(preview()?.authorName == original.updateUser.nickname)
        await refresh()
        #expect(preview() == nil)
        let gate = ListRequestGate<PaperDetail>()
        service.metadata = { _ in
            let detail = try await gate.request()
            if staleFailure { throw URLError(.timedOut) }
            return detail
        }
        let earlier = Task { await load() }
        try await gate.waitUntilRequested()
        await refresh()
        service.metadata = { _ in edited }
        await load()
        gate.finish(original)
        await earlier.value
        #expect(preview()?.isAnonymous == true)
        #expect(preview()?.avatarURL == nil)
        #expect(preview()?.avatarFallbackURL == nil)
        #expect(preview()?.authorName == edited.previewMetadata.authorName)
        #expect(search ? results.previewFailedIDs.isEmpty : list.previewFailedIDs.isEmpty)
        if search { results.reset(); #expect(preview() == nil) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
    func leavingThePageReleasesPreviewRequestsForTheSamePaper(search: Bool) async throws {
        let paper = PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        let service = ServiceStub(result: .success([paper]))
        let list = PaperListViewModel(service: service)
        let results = PaperSearchViewModel(service: service)
        results.searchText = "fixture"
        func load() async {
            if search { await results.loadPreviewMetadataIfNeeded(for: paper) }
            else { await list.loadPreviewMetadataIfNeeded(for: paper) }
        }
        func preview() -> PaperPreviewMetadata? {
            search ? results.previewMetadata(for: paper.id) : list.previewMetadata(for: paper.id)
        }
        if search { await results.performSearch() } else { await list.refresh() }
        let earlierGate = ListRequestGate<PaperDetail>()
        let old = PaperDetail(id: 1, title: "fixture", intro: "", content: "", createTime: "", updateTime: "",
            updateUser: listUser(1), anonymous: false, likeNum: 0, commentNum: 0, publicEdit: true, like: false, own: true)
        let fresh = PaperDetail(id: 1, title: "fixture", intro: "", content: "", createTime: "", updateTime: "",
            updateUser: listUser(2), anonymous: false, likeNum: 0, commentNum: 0, publicEdit: true, like: false, own: true)
        var requests = 0
        service.metadata = { _ in
            requests += 1
            return requests == 1 ? try await earlierGate.request() : fresh
        }
        let earlier = Task { await load() }
        try await earlierGate.waitUntilRequested()
        earlier.cancel()
        if search { results.cancelSearchOperations() } else { list.cancelRefreshOperations() }
        await load()
        #expect(requests == 2 && preview()?.authorName == fresh.updateUser.nickname)
        earlierGate.finish(old)
        await earlier.value
        await load()
        #expect(requests == 2 && preview()?.authorName == fresh.updateUser.nickname)
        #expect(service.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
    func failedPreviewLeavesALoadResultAndRefreshAllowsRetry(search: Bool) async {
        let paper = PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        let service = ServiceStub(result: .success([paper]))
        let list = PaperListViewModel(service: service)
        let results = PaperSearchViewModel(service: service)
        results.searchText = "fixture"
        func refresh() async { if search { await results.performSearch() } else { await list.refresh() } }
        func load() async { if search { await results.loadPreviewMetadataIfNeeded(for: paper) } else { await list.loadPreviewMetadataIfNeeded(for: paper) } }
        func failures() -> Set<Int> { search ? results.previewFailedIDs : list.previewFailedIDs }
        await refresh(); await load()
        #expect(failures() == [paper.id])
        service.metadata = { _ in throw CancellationError() }
        await refresh(); await load()
        #expect(failures().isEmpty)
        service.metadata = { _ in
            PaperDetail(id: 1, title: "fixture", intro: "", content: "", createTime: "", updateTime: "",
                updateUser: listUser(1), anonymous: false, likeNum: 0, commentNum: 0, publicEdit: true, like: false, own: true)
        }
        await refresh(); await load()
        #expect(failures().isEmpty)
        #expect(search ? results.previewMetadata(for: paper.id) != nil : list.previewMetadata(for: paper.id) != nil)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func returningBeforeTheCancelledBootstrapEndsStartsAFreshRequest() async throws {
        let paper = PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        let service = ServiceStub(result: .success([paper]))
        let gate = ListRequestGate<[PaperSummary]>()
        service.fetch = { try await gate.request() }
        let model = PaperListViewModel(service: service)
        let earlier = Task { await model.bootstrapIfNeeded() }
        try await gate.waitUntilRequested()
        model.cancelRefreshOperations()
        service.fetch = nil
        await model.bootstrapIfNeeded()
        #expect(service.requests.count == 2 && model.state.items == [paper])
        gate.finish([])
        await earlier.value
        #expect(model.state.status == .loaded && model.state.items == [paper])
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func paperListRetriesItsCancelledBootstrapWhenThePageReturns() async {
        let paper = PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        let service = ServiceStub(result: .failure(CancellationError()))
        let model = PaperListViewModel(service: service)
        await model.bootstrapIfNeeded()
        #expect(model.state.status == .idle)
        service.result = .success([paper])
        await model.bootstrapIfNeeded()
        await model.bootstrapIfNeeded()
        #expect(model.state.items == [paper] && model.state.status == .loaded)
        #expect(service.requests.count == 2)
    }

    @Test("Blank searches reset populated results locally", .timeLimit(.minutes(1)))
    @MainActor
    func blankSearchResetsLocally() async {
        let paper = PaperSummary(
            id: 1,
            title: "标题",
            intro: "摘要",
            likeNum: 1,
            commentNum: 1,
            updateTime: "2026-08-09"
        )
        let service = ServiceStub(result: .success([paper]))
        let viewModel = PaperSearchViewModel(service: service)
        viewModel.searchText = "Swift"

        await viewModel.performSearch()

        viewModel.searchText = "   "

        await viewModel.performSearch()

        #expect(service.requests.count == 1)
        #expect(viewModel.state.status == .idle)
        #expect(viewModel.state.items.isEmpty)
    }

    @Test("Cancellation restores the idle search state with alert clear", .timeLimit(.minutes(1)))
    @MainActor
    func cancellationIsSilent() async {
        let service = ServiceStub(result: .failure(CancellationError()))
        let viewModel = PaperSearchViewModel(service: service)
        viewModel.searchText = "Swift"

        await viewModel.performSearch()

        #expect(viewModel.state.status == .idle)
        #expect(viewModel.state.items.isEmpty)
        #expect(viewModel.alert == nil)
    }

    @Test("Search parameters are normalized and forwarded", .timeLimit(.minutes(1)))
    @MainActor
    func forwardsNormalizedSearch() async {
        let paper = PaperSummary(
            id: 7,
            title: "标题",
            intro: "摘要",
            likeNum: 1,
            commentNum: 2,
            updateTime: "2026-08-09"
        )
        let service = ServiceStub(result: .success([paper]))
        let viewModel = PaperSearchViewModel(service: service)
        viewModel.searchText = "  Swift  "
        viewModel.selectedOrder = .like

        await viewModel.performSearch()

        #expect(service.requests.count == 1)
        #expect(service.requests.first?.search == "Swift")
        #expect(service.requests.first?.order == .like)
        #expect(service.requests.first?.page == 0)
        #expect(viewModel.state.items == [paper])
        #expect(viewModel.state.status == .loaded)
    }
}
