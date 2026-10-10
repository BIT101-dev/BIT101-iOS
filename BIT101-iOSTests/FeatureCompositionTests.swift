import CommunityPersistence
import ScheduleDomain
@testable import ScheduleFeature
@testable import GalleryFeature
@testable import MineFeature
@testable import PaperFeature
import StorageCore
import CommunityUI
import MediaKit
import CommunityCore
import CommunityTransport
import CourseFeature
import DesignSystemKit
import Foundation
import SwiftUI
import Testing
import TransportCore
import UIKit
import Combine
import ClientCore
import ScoreDomain
import ScorePorts
import ScoreInfrastructure
@testable import ScoreFeature

@MainActor
@Suite(.serialized)
struct FeatureCompositionTests {
    private final class ScoreCache: ScoreCaching {
        var changes: AnyPublisher<AppStorageSession, Never> { Empty().eraseToAnyPublisher() }
        var loads = 0
        var rows = [ScoreRow(index: 0, headers: ["课程名称", "成绩", "开课学期", "课程性质"],
            values: ["composition-score", "90", "fixture", "必修"])]
        func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot? {
            loads += 1
            return ScoreCacheSnapshot(rows: rows, updatedAt: Date(), detailedUpdatedAt: Date())
        }
        func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
        func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
    }
    private final class ScorePreferences: ScoreFilterPreferencesStoring {
        var changes: AnyPublisher<AppStorageSession, Never> { Empty().eraseToAnyPublisher() }
        var hasUnreadableSnapshot: Bool { false }
        func load() -> ScoreFilterPreferenceSnapshot? { nil }
        func save(selectedTerms: Set<String>, selectedCourseTypes: Set<String>, sortIndex: ScoreSortIndex, sortOrder: ScoreSortOrder) -> Bool { true }
    }
    private final class Scores: ScoreListServicing, TrustedTranscriptServicing {
        var schoolRequests = 0
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge { schoolRequests += 1; throw URLError(.notConnectedToInternet) }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] { schoolRequests += 1; return [] }
        func submitScoreSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { schoolRequests += 1; return challenge }
        func fetchTrustedTranscriptPages() async throws -> [Data] { schoolRequests += 1; return [] }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> [Data] { schoolRequests += 1; return [] }
    }

    @Test func scoreFiltersInitializeAfterScheduleOnlyCacheAndPreserveExplicitEmptySelection() async throws {
        let suite = "BIT101.ScoreFilterInitialization"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppStorageSession(accountIdentifier: "composition-score")
        let preferences = ScoreFilterPreferenceStore(defaults: defaults, session: { session })
        let cache = ScoreCache()
        let rows = cache.rows
        cache.rows = []
        let course = ScoreCourseSummary(id: "pending", term: "fixture", name: "pending", number: "pending", type: "必修",
            teacher: "", classroom: "", campus: "", description: "", creditText: "3", scheduleText: "", weeksText: "", hourText: "")
        let model = ScoreViewModel(service: Scores(), cacheStore: cache, preferenceStore: preferences,
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in ["fixture": [course]] })
        await model.restoreCachedDataIfNeeded()
        model.setSortIndex(.score)
        #expect(model.selectedTerms == ["fixture"] && model.availableCourseTypes.isEmpty)
        #expect(preferences.load() == nil)
        cache.rows = rows
        await model.applySyncedScoreCacheIfAvailable()
        #expect(model.filteredRows == rows && model.selectedCourseTypes == ["必修"])
        #expect(preferences.load()?.sortIndex == ScoreSortIndex.score.rawValue)
        model.toggleAllCourseTypes()
        await model.applySyncedScoreCacheIfAvailable()
        #expect(model.filteredRows.isEmpty && preferences.load()?.selectedCourseTypes == [])
    }

    @Test(.timeLimit(.minutes(1)))
    func scoreEntryRestoresItsSelectedCacheAndLeavesSchoolRequestsToUserActions() async throws {
        let selected = ScoreCache()
        let service = Scores()
        let viewModel = ScoreViewModel(service: service, cacheStore: selected, preferenceStore: ScorePreferences(),
            currentScoreCacheSession: { AppStorageSession(accountIdentifier: "composition-score") },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        try await host(ScoreListPage(viewModel: viewModel, transcriptService: service, onSearchCourse: { _ in })) {
            try await waitForTestEvent { !(viewModel.filteredRows.isEmpty) }
            #expect(viewModel.filteredRows.first?.courseName == "composition-score")
        }
        #expect(selected.loads == 1)
        #expect(service.schoolRequests == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func mountedTranscriptPageUsesItsReplacementService() async throws {
        let first = Scores(), second = Scores()
        let selectedMedia = media()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack { TrustedTranscriptDestination(service: first).environment(selectedMedia) })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForTestEvent { !(first.schoolRequests == 0) }
        controller.rootView = NavigationStack { TrustedTranscriptDestination(service: second).environment(selectedMedia) }
        try await waitForTestEvent { !(second.schoolRequests == 0) }
        #expect(first.schoolRequests == 1)
        #expect(second.schoolRequests == 1)
        #expect(first.transcriptServiceIdentity != second.transcriptServiceIdentity)
    }

    private final class CourseList: CourseListServicing {
        var requests: [String] = []

        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            requests.append(search)
            return []
        }

        func waitForLookup() async throws {
            try await waitForTestEvent { requests.count >= 2 }
        }
    }

    private struct OfflineTransport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
    }

    private func media() -> MediaEnvironment {
        let files = PreferenceMemoryFiles()
        let client = HTTPClient(transport: OfflineTransport(), observer: nil)
        return MediaEnvironment(files: files, previewStorage: MediaPreviewStorage(files: files), defaults: UserDefaults.standard,
                                imageHTTPClient: client, avatarHTTPClient: client)
    }

    private func dependencies(list: CourseList) -> CourseDependencies {
        let session = CommunitySession(httpClient: HTTPClient(transport: OfflineTransport(), observer: nil), baseURL: AppURL.required("https://example.invalid"), credentials: { CommunityCredentials(identity: CommunitySessionIdentity(accountIdentifier: "composition-test"), cookie: "fixture") }, refresh: { _ in })
        return CourseDependencies(list: list, detail: CourseService(session: session), preferences: CommunityPreferences(snapshot: CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false), saveMakeupFilter: { _ in }), loadCourseCredits: { [] })
    }

    @Test(.timeLimit(.minutes(1)))
    func courseEntryUsesItsConstructorDependenciesAcrossEnvironmentComposition() async throws {
        let selected = CourseList()
        let surrounding = CourseList()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack {
            CourseEvaluationDestination(dependencies: dependencies(list: selected), media: media(), profiles: CommunityProfileDestination { AnyView(Text("profile \($0)")) }, request: .lookup(courseName: "课程", courseNumber: "COURSE-1"))
        }.environment(dependencies(list: surrounding)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await selected.waitForLookup()
        #expect(Set(selected.requests) == ["课程", "COURSE-1"])
        #expect(surrounding.requests.isEmpty)
    }
    private final class TraceTransport: HTTPTransport {
        var requests: [URLRequest] = []
        var response: ((URLRequest) throws -> Data)?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            if let response {
                let url = try #require(request.url)
                return (try response(request), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            }
            throw URLError(.notConnectedToInternet)
        }
        func waitForRequest(count: Int = 1) async throws {
            try await waitForTestEvent { requests.count >= count }
        }
    }

    private func session(_ transport: TraceTransport) -> CommunitySession {
        CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { CommunityCredentials(identity: CommunitySessionIdentity(accountIdentifier: "composition"), cookie: "fixture") },
            refresh: { _ in })
    }

    private func preferences() -> CommunityPreferences {
        CommunityPreferences(snapshot: CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
            useWebView: false, hideMakeupOutliers: false), saveMakeupFilter: { _ in })
    }

    private func gallery(_ transport: TraceTransport) -> GalleryDependencies {
        let session = session(transport)
        let preferences = preferences()
        let service = GalleryService(session: session, preferences: { preferences.snapshot })
        return GalleryDependencies(webCredentials: .init(cookie: { session.fakeCookie }, changes: session.credentialsChanges.map { _ in () }.eraseToAnyPublisher()),
            currentIdentity: { session.currentCredentials.identity },
            feed: service, messageService: service, posterDetail: service,
            reporting: service, composer: service, images: service, preferences: preferences,
            messages: GalleryMessageReadStore(defaults: UserDefaults.standard, session: { AppStorageSession(accountIdentifier: "composition") }),
            drafts: ComposerDraftStore(files: PreferenceMemoryFiles(), applicationSupport: URL(fileURLWithPath: "/preference-sync"),
                session: { AppStorageSession(accountIdentifier: "composition") }, prepareImageData: ComposerDraftImageCompressor.compress),
            networkPath: NetworkPathState(snapshot: NetworkPathSnapshot(status: .connected)))
    }

    private func paper(_ transport: TraceTransport) -> PaperDependencies {
        let service = PaperService(session: session(transport))
        return PaperDependencies(list: service, detail: service, composer: service,
            networkPath: NetworkPathState(snapshot: NetworkPathSnapshot(status: .connected)))
    }

    private func mine(_ transport: TraceTransport) -> MineDependencies {
        let preferences = preferences()
        let service = MineService(session: session(transport), preferences: { preferences.snapshot })
        return MineDependencies(overview: service, profile: service, deletePoster: { _ in }, isRunningUITest: false)
    }

    private func host<V: View>(_ view: V, operation: () async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack { view })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await operation()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        window.layoutIfNeeded()
    }

    @Test(.timeLimit(.minutes(1)))
    func galleryRootRoutesToItsExplicitPaperConsumer() async throws {
        let galleryTransport = TraceTransport()
        let paperTransport = TraceTransport()
        let surroundingTransport = TraceTransport()
        let selectedMedia = media()
        var routedIDs: [Int] = []
        let paperRoute = CommunityPaperDestination { requestedID, onShowFeed in
            if let id = requestedID.wrappedValue { routedIDs.append(id) }
            return AnyView(PaperRootView(dependencies: paper(paperTransport), media: selectedMedia,
                                        requestedPaperID: requestedID, onShowFeed: onShowFeed))
        }
        let view = GalleryRootView(dependencies: gallery(galleryTransport), media: selectedMedia,
            profiles: CommunityProfileDestination { AnyView(Text("profile \($0)")) }, papers: paperRoute,
            requestedPaperID: .constant(42))
            .environment(gallery(surroundingTransport)).environment(media())
        try await host(view) { try await paperTransport.waitForRequest() }
        #expect(routedIDs.contains(42))
        #expect(surroundingTransport.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func paperRootLoadsUsingItsConstructorService() async throws {
        let selected = TraceTransport()
        let surrounding = TraceTransport()
        try await host(PaperRootView(dependencies: paper(selected), media: media())
            .environment(paper(surrounding)).environment(media())) { try await selected.waitForRequest() }
        #expect(surrounding.requests.isEmpty)
    }

    private final class PaperPreviewService: PaperListServicing {
        let summary = PaperSummary(id: 1, title: "页面返回验收", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        var pages: [Int] = []
        var previewRequests = 0
        var pending: CheckedContinuation<PaperPreviewMetadata, Never>?
        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
            pages.append(page)
            return page == 0 ? [summary] : []
        }
        func fetchPaper(id: Int) async throws -> PaperDetail { throw URLError(.unsupportedURL) }
        func fetchPreviewMetadata(id: Int) async throws -> PaperPreviewMetadata {
            previewRequests += 1
            if previewRequests == 1 { return await withCheckedContinuation { pending = $0 } }
            return PaperPreviewMetadata(authorName: "返回后的作者", avatarURL: nil, isAnonymous: false)
        }
    }

    private final class TabRoute: ObservableObject {
        @Published var selection = 0
        var otherAppeared = false
    }

    private struct PaperTabs: View {
        @ObservedObject var route: TabRoute
        let dependencies: PaperDependencies
        let media: MediaEnvironment
        var body: some View {
            TabView(selection: $route.selection) {
                NavigationStack { PaperRootView(dependencies: dependencies, media: media) }
                    .tabItem { Text("文章") }.tag(0)
                Text("其他页面").onAppear { route.otherAppeared = true }
                    .tabItem { Text("其他") }.tag(1)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func paperTabReturnRetriesTheCancelledAuthorPreviewWithItsExistingList() async throws {
        let service = PaperPreviewService()
        let routes = TabRoute()
        let details = PaperService(session: session(TraceTransport()))
        let dependencies = PaperDependencies(list: service, detail: details, composer: details,
            networkPath: NetworkPathState(snapshot: NetworkPathSnapshot(status: .connected)))
        try await host(PaperTabs(route: routes, dependencies: dependencies, media: media())) {
            try await waitForTestEvent { !(service.pending == nil || service.pages.count < 2) }
            routes.selection = 1
            try await waitForTestEvent { !(!routes.otherAppeared) }
            routes.selection = 0
            try await waitForTestEvent { !(service.previewRequests < 2) }
            service.pending?.resume(returning: PaperPreviewMetadata(authorName: "迟到的作者", avatarURL: nil, isAnonymous: false))
            service.pending = nil
        }
        #expect(service.previewRequests == 2 && service.pages == [0, 1])
    }

    private final class GalleryFeed: GalleryFeedServicing {
        var pages: [Int] = []
        var pending: CheckedContinuation<GalleryPageBatch<CommunityPoster>, Never>?
        var suspend = false
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            let page = page ?? 0
            pages.append(page)
            if suspend { return await withCheckedContinuation { pending = $0 } }
            let poster = CommunityPoster(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0,
                createTime: "", editTime: "", id: page + 1, images: [], likeNum: 0, public: true,
                tags: [], text: "", title: "分页验收", updateTime: "", user: .placeholder(id: 1, nickname: "作者"))
            return .init(items: page < 2 ? [poster] : [], nextSourcePage: page + 1, canLoadMore: page < 2)
        }
        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> { try await fetchFeed(kind: .recommend, page: sourcePage) }
        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> { try await fetchFeed(kind: .bot, page: startPage) }
        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> { try await fetchFeed(kind: .newest, page: page) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func galleryOwnerExitRestoresPaginationDuringRefresh(exhausted: Bool) async throws {
        let service = GalleryFeed()
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .newest)
        await model.loadMoreIfNeeded(for: .newest, currentPoster: model.state(for: .newest).posters.last)
        if exhausted { await model.loadMoreIfNeeded(for: .newest, currentPoster: model.state(for: .newest).posters.last) }
        let previous = model.state(for: .newest)
        service.suspend = true
        let refresh = model.enqueueRefresh(for: .newest)
        try await waitForTestEvent { !(service.pending == nil) }
        model.cancelPendingOperations()
        #expect(model.state(for: .newest).nextPage == previous.nextPage)
        #expect(model.state(for: .newest).canLoadMore == previous.canLoadMore)
        service.pending?.resume(returning: .init(items: [], nextSourcePage: 1, canLoadMore: false))
        service.pending = nil
        await refresh.value
        service.suspend = false
        await model.loadMoreIfNeeded(for: .newest, currentPoster: previous.posters.last)
        #expect(service.pages == (exhausted ? [0, 1, 2, 0] : [0, 1, 0, 2]))
        #expect(model.state(for: .newest).posters == previous.posters && model.alert == nil)
    }

    @Test
    func authenticatedPaperReadsSendTheSmokePreflightAndBusinessRoutes() async throws {
        let transport = TraceTransport()
        transport.response = { request in
            switch request.url?.path {
            case "/user/check": return Data("{}".utf8)
            case "/papers/17":
                return Data(#"{"id":17,"title":"文章","intro":"","content":"","create_time":"","update_time":"","update_user":{"id":1,"create_time":"","nickname":"作者","avatar":{"mid":"","url":"","low_url":""},"motto":"","identity":{"id":0,"color":"","text":"","create_time":"","update_time":"","delete_time":null}},"anonymous":false,"like_num":0,"comment_num":0,"public_edit":false,"like":false,"own":false}"#.utf8)
            case "/reaction/comments": return Data("[]".utf8)
            default: throw URLError(.unsupportedURL)
            }
        }
        let service = PaperService(session: session(transport))
        _ = try await service.fetchPaper(id: 17)
        _ = try await service.fetchComments(paperID: 17, order: .newest, page: 0)
        _ = try await service.fetchComments(paperID: 17, order: .newest, page: 1)
        #expect(transport.requests.map { $0.url?.path } == ["/user/check", "/papers/17", "/user/check", "/reaction/comments", "/user/check", "/reaction/comments"])
        let url = try #require(transport.requests.last?.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }) == ["obj": "paper17", "order": "new", "page": "1"])
    }

    @Test(.timeLimit(.minutes(1)))
    func mineAndProfileRootsOwnTheirServiceAndPosterCapabilities() async throws {
        let selected = TraceTransport()
        let surrounding = TraceTransport()
        let poster = CommunityPosterDestination { _, _ in AnyView(Text("poster")) }
        let settings = CommunitySettingsDestinations(settingsEntries: [], settings: { _ in AnyView(Text("settings")) },
                                                    suggestion: { AnyView(Text("suggestion")) })
        try await host(MineRootView(dependencies: mine(selected), media: media(), posters: poster, settings: settings,
            fallbackStudentID: "fixture", onLogout: {}).environment(mine(surrounding))) { try await selected.waitForRequest() }
        #expect(surrounding.requests.isEmpty)
        let profile = TraceTransport()
        try await host(UserProfileRootView(dependencies: mine(profile), media: media(), posters: poster, userID: 42)
            .environment(mine(surrounding))) { try await profile.waitForRequest() }
        #expect(surrounding.requests.isEmpty)
    }

    @Test func profileFollowUsesItsInjectedCommunitySessionAndUpdatesTheDisplayedCard() async throws {
        let transport = TraceTransport()
        transport.response = { request in
            #expect(request.value(forHTTPHeaderField: "fake-cookie") == "fixture")
            if request.url?.path == "/user/info/42" {
                #expect(request.httpMethod == "GET")
                return Data(#"{"user":{"id":42,"createTime":"","nickname":"profile","avatar":{"mid":"","url":"","lowUrl":""},"motto":"","identity":{"id":0,"color":"","text":"","createTime":"","updateTime":"","deleteTime":null}},"followingNum":2,"followerNum":3,"following":false,"follower":false,"own":false}"#.utf8)
            }
            #expect(request.url?.path == "/user/follow/42")
            #expect(request.httpMethod == "POST")
            return Data(#"{"following":true,"follower":true,"followingNum":4,"followerNum":5}"#.utf8)
        }
        let model = UserProfileViewModel(userID: 42, service: mine(transport).profile)
        await model.refreshProfile()
        #expect(model.profileStatus == .loaded)
        await model.followUser()
        #expect(model.userInfo?.user.id == 42)
        #expect(model.userInfo?.following == true && model.userInfo?.follower == true)
        #expect(model.userInfo?.followingNum == 4 && model.userInfo?.followerNum == 5)
        #expect(model.isFollowingUser == false && model.alert == nil)
        await model.followUser()
        #expect(transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [ScheduleSection.courses, .ddl, .classroom])
    func scheduleRootOwnsItsConstructorViewModel(section: ScheduleSection) async throws {
        var selectedLoads = 0
        var surroundingLoads = 0
        var continuation: CheckedContinuation<Void, Never>?
        let term = "2026-2027-1"
        let course = CourseRecord(id: "composition-course", term: term, name: "composition-course", teacher: "fixture", classroom: "fixture",
            description: "", weeks: Array(1...20), weekday: 1, startSection: 1, endSection: 2, campus: "fixture", number: "fixture", credit: 1,
            hour: 16, type: "必修", category: "fixture", department: "fixture")
        var cache = ScheduleCache()
        cache.courseData.currentTerm = term
        cache.courseData.schedulesByTerm[term] = TermScheduleSnapshot(term: term, firstDayString: "2026-09-07", courses: [course], exams: [], updatedAt: Date())
        func viewModel(load: @escaping (AppStorageSession) async -> ScheduleCacheLoadResult) -> ScheduleViewModel {
            let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "composition") }, load: load, save: { _, _, _ in })
            let service = SemesterStartDateService()
            return ScheduleViewModel(service: service, repository: repository, ddlService: service, classroomService: service,
                                     platformActions: RecordingSchedulePlatformActions(), newCustomScheduleDraft: { CustomScheduleDraft() })
        }
        let selected = viewModel { _ in
            selectedLoads += 1
            continuation?.resume(); continuation = nil
            return .loaded(cache)
        }
        let surrounding = viewModel { _ in surroundingLoads += 1; return .missing }
        let destinations = ScheduleDestinations(appStoreURL: AppURL.required("https://example.invalid"),
            academicCourse: { _, _ in AnyView(Text("course")) }, openCourseLocation: { _ in true }, resolveCourseShare: { _ in nil })
        try await host(ScheduleRootView(viewModel: selected, requestedSection: .constant(section), destinations: destinations)
            .environmentObject(surrounding)) {
                if selectedLoads == 0 { await withCheckedContinuation { continuation = $0 } }
                try await waitForTestEvent { !(!selected.isCacheWritable) }
                #expect(selected.courseState.courses.map(\.id) == [course.id])
                #expect(selected.selectedSection == section)
            }
        #expect(selectedLoads > 0)
        #expect(surroundingLoads == 0)
    }

    private func replace<V: View>(_ first: V, with second: V, firstTransport: TraceTransport, secondTransport: TraceTransport, initialRequests: Int = 1) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack { first })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await firstTransport.waitForRequest(count: initialRequests)
        let firstCount = firstTransport.requests.count
        controller.rootView = NavigationStack { second }
        try await secondTransport.waitForRequest(count: initialRequests)
        #expect(firstTransport.requests.count == firstCount)
        #expect(secondTransport.requests.count > 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func paperDependencyReplacementRebuildsTheOwnedStateObject() async throws {
        let first = TraceTransport(), second = TraceTransport()
        let selectedMedia = media()
        try await replace(PaperRootView(dependencies: paper(first), media: selectedMedia),
            with: PaperRootView(dependencies: paper(second), media: selectedMedia), firstTransport: first, secondTransport: second)
    }

    @Test(.timeLimit(.minutes(1)))
    func galleryDependencyReplacementRebuildsTheOwnedScene() async throws {
        let first = TraceTransport(), second = TraceTransport()
        let selectedMedia = media()
        let profiles = CommunityProfileDestination { AnyView(Text("profile \($0)")) }
        let papers = CommunityPaperDestination { _, _ in AnyView(Text("paper")) }
        try await replace(GalleryRootView(dependencies: gallery(first), media: selectedMedia, profiles: profiles, papers: papers),
            with: GalleryRootView(dependencies: gallery(second), media: selectedMedia, profiles: profiles, papers: papers),
            firstTransport: first, secondTransport: second, initialRequests: 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func courseLookupDependencyReplacementRestartsTheOwnedTask() async throws {
        let first = CourseList(), second = CourseList()
        let selectedMedia = media()
        let profiles = CommunityProfileDestination { AnyView(Text("profile \($0)")) }
        let request = CourseNavigationRequest.lookup(courseName: "课程", courseNumber: "COURSE-1")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack {
            CourseEvaluationDestination(dependencies: dependencies(list: first), media: selectedMedia, profiles: profiles, request: request)
        })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await first.waitForLookup()
        controller.rootView = NavigationStack {
            CourseEvaluationDestination(dependencies: dependencies(list: second), media: selectedMedia, profiles: profiles, request: request)
        }
        try await second.waitForLookup()
        #expect(first.requests.count == 2)
        #expect(Set(second.requests) == ["课程", "COURSE-1"])
    }

}
