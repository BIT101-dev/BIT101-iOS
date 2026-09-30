import CommunityTransport
import TransportCore
@testable import MineFeature
@testable import PaperFeature
@testable import CourseFeature
@testable import GalleryFeature
import CommunityCore
import CommunityUI
import StorageCore
@testable import MediaKit
import Foundation
import Testing

@MainActor
struct CommunityDependencyBoundaryTests {
    private var session: CommunitySession {
        CommunitySession(
            httpClient: HTTPClient(transport: OfflineCommunityTransport(), observer: nil),
            baseURL: URL(string: "https://example.invalid")!, cookie: { "module-cookie" }, refresh: { _ in }
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
        let dependencies = PaperDependencies(list: list, detail: detail, composer: composer)
        let viewModel = PaperListViewModel(service: dependencies.list)
        await viewModel.refresh()
        let id = try await dependencies.composer.createPaper(
            title: "标题", intro: "简介", content: "正文", anonymous: false, publicEdit: true
        )
        try await dependencies.composer.updatePaper(
            id: id, title: "编辑标题", intro: "简介", content: "编辑正文", anonymous: true, publicEdit: false
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

private final class RecordingGalleryFeed: GalleryFeedServicing {
    var requests: [GalleryFeedKind] = []
    func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> [CommunityPoster] {
        requests.append(kind)
        return []
    }
    func fetchRecommendPage(sourcePage: Int) async throws -> GalleryRecommendFeedBatch {
        GalleryRecommendFeedBatch(posters: [], nextSourcePage: sourcePage + 1, canLoadMore: false)
    }
    func fetchBotFeed(startPage: Int) async throws -> GalleryBotFeedBatch {
        GalleryBotFeedBatch(posters: [], nextSourcePage: startPage + 1, canLoadMore: false)
    }
    func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> [CommunityPoster] { [] }
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
    func updatePaper(id: Int, title: String, intro: String, content: String, anonymous: Bool, publicEdit: Bool) async throws {
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
