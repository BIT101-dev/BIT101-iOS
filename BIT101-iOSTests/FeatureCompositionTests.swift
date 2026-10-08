import CommunityPersistence
import ScheduleDomain
@testable import ScheduleFeature
import GalleryFeature
@testable import MineFeature
import PaperFeature
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
@testable import ScoreFeature

@MainActor
@Suite(.serialized)
struct FeatureCompositionTests {
    private final class ScoreCache: ScoreCaching {
        var changes: AnyPublisher<AppStorageSession, Never> { Empty().eraseToAnyPublisher() }
        var loads = 0
        func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot? {
            loads += 1
            return ScoreCacheSnapshot(rows: [ScoreRow(index: 0, headers: ["课程名称", "成绩", "开课学期", "课程性质"],
                values: ["composition-score", "90", "fixture", "必修"])], updatedAt: Date(), detailedUpdatedAt: Date())
        }
        func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
        func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
    }
    private final class ScorePreferences: ScoreFilterPreferencesStoring {
        var changes: AnyPublisher<AppStorageSession, Never> { Empty().eraseToAnyPublisher() }
        func load() -> ScoreFilterPreferenceSnapshot? { nil }
        func save(selectedTerms: Set<String>, selectedCourseTypes: Set<String>, sortIndex: ScoreSortIndex, sortOrder: ScoreSortOrder) {}
    }
    private final class Scores: ScoreListServicing, TrustedTranscriptServicing {
        var schoolRequests = 0
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge { schoolRequests += 1; throw URLError(.notConnectedToInternet) }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] { schoolRequests += 1; return [] }
        func submitScoreSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { schoolRequests += 1; return challenge }
        func fetchTrustedTranscriptPages() async throws -> [Data] { schoolRequests += 1; return [] }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> [Data] { schoolRequests += 1; return [] }
    }

    @Test(.timeLimit(.minutes(1)))
    func scoreEntryRestoresItsSelectedCacheAndLeavesSchoolRequestsToUserActions() async throws {
        let selected = ScoreCache()
        let service = Scores()
        let viewModel = ScoreViewModel(service: service, cacheStore: selected, preferenceStore: ScorePreferences(),
            currentScoreCacheSession: { AppStorageSession(accountIdentifier: "composition-score") },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        try await host(ScoreListPage(viewModel: viewModel, transcriptService: service, onSearchCourse: { _ in })) {
            while viewModel.filteredRows.isEmpty { try Task.checkCancellation(); await Task.yield() }
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
        while first.schoolRequests == 0 { try Task.checkCancellation(); await Task.yield() }
        controller.rootView = NavigationStack { TrustedTranscriptDestination(service: second).environment(selectedMedia) }
        while second.schoolRequests == 0 { try Task.checkCancellation(); await Task.yield() }
        #expect(first.schoolRequests == 1)
        #expect(second.schoolRequests == 1)
        #expect(first.transcriptServiceIdentity != second.transcriptServiceIdentity)
    }

    private final class CourseList: CourseListServicing {
        var requests: [String] = []
        private var waiter: CheckedContinuation<Void, Never>?

        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            requests.append(search)
            if requests.count == 2 { waiter?.resume(); waiter = nil }
            return []
        }

        func waitForLookup() async {
            if requests.count == 2 { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    private struct OfflineTransport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
    }

    private func media() -> MediaEnvironment {
        let files = PreferenceMemoryFiles()
        let client = HTTPClient(transport: OfflineTransport(), observer: nil)
        return MediaEnvironment(files: files, previewFiles: files, defaults: UserDefaults.standard,
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
        await selected.waitForLookup()
        #expect(Set(selected.requests) == ["课程", "COURSE-1"])
        #expect(surrounding.requests.isEmpty)
    }
    private final class TraceTransport: HTTPTransport {
        var requests: [URLRequest] = []
        var response: ((URLRequest) throws -> Data)?
        private var waiter: CheckedContinuation<Void, Never>?
        private var expectedRequests = 1
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            if requests.count >= expectedRequests { waiter?.resume(); waiter = nil }
            if let response {
                let url = try #require(request.url)
                return (try response(request), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            }
            throw URLError(.notConnectedToInternet)
        }
        func waitForRequest(count: Int = 1) async {
            if requests.count >= count { return }
            expectedRequests = count
            await withCheckedContinuation { waiter = $0 }
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
        return GalleryDependencies(session: session, feed: service, messageService: service, posterDetail: service,
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
        try await host(view) { await paperTransport.waitForRequest() }
        #expect(routedIDs.contains(42))
        #expect(surroundingTransport.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func paperRootLoadsUsingItsConstructorService() async throws {
        let selected = TraceTransport()
        let surrounding = TraceTransport()
        try await host(PaperRootView(dependencies: paper(selected), media: media())
            .environment(paper(surrounding)).environment(media())) { await selected.waitForRequest() }
        #expect(surrounding.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func mineAndProfileRootsOwnTheirServiceAndPosterCapabilities() async throws {
        let selected = TraceTransport()
        let surrounding = TraceTransport()
        let poster = CommunityPosterDestination { _, _ in AnyView(Text("poster")) }
        let settings = CommunitySettingsDestinations(settingsEntries: [], settings: { _ in AnyView(Text("settings")) },
                                                    suggestion: { AnyView(Text("suggestion")) })
        try await host(MineRootView(dependencies: mine(selected), media: media(), posters: poster, settings: settings,
            fallbackStudentID: "fixture", onLogout: {}).environment(mine(surrounding))) { await selected.waitForRequest() }
        #expect(surrounding.requests.isEmpty)
        let profile = TraceTransport()
        try await host(UserProfileRootView(dependencies: mine(profile), media: media(), posters: poster, userID: 42)
            .environment(mine(surrounding))) { await profile.waitForRequest() }
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
                while !selected.isCacheWritable { try Task.checkCancellation(); await Task.yield() }
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
        await firstTransport.waitForRequest(count: initialRequests)
        let firstCount = firstTransport.requests.count
        controller.rootView = NavigationStack { second }
        await secondTransport.waitForRequest(count: initialRequests)
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
        await first.waitForLookup()
        controller.rootView = NavigationStack {
            CourseEvaluationDestination(dependencies: dependencies(list: second), media: selectedMedia, profiles: profiles, request: request)
        }
        await second.waitForLookup()
        #expect(first.requests.count == 2)
        #expect(Set(second.requests) == ["课程", "COURSE-1"])
    }

}
