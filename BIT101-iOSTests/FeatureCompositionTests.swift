@testable import BIT101_iOS
import CommunityPersistence
import ScheduleDomain
@testable import ScheduleFeature
@testable import GalleryFeature
@testable import MineFeature
@testable import PaperFeature
import StorageCore
import CommunityUI
@testable import MediaKit
import CommunityCore
import CommunityTransport
@testable import CourseFeature
import DesignSystemKit
import Foundation
import TransportCore
import SwiftUI
import Testing
import UIKit
import WebKit
import Combine
import ClientCore
import ScoreDomain
import ScorePorts
import ScoreInfrastructure
@testable import ScoreFeature

@MainActor
@Suite(.serialized)
struct FeatureCompositionTests {
    @Test func orientationAndWindowLayoutFollowAvailableSpace() {
        for (idiom, horizontal, vertical, mask) in [
            (UIUserInterfaceIdiom.phone, UIUserInterfaceSizeClass.compact, UIUserInterfaceSizeClass.regular, UIInterfaceOrientationMask.portrait),
            (.phone, .regular, .compact, .portrait), (.phone, .regular, .regular, .allButUpsideDown),
            (.pad, .compact, .regular, .all), (.pad, .regular, .regular, .all)
        ] {
            let traits = UITraitCollection { traits in
                traits.userInterfaceIdiom = idiom
                traits.horizontalSizeClass = horizontal; traits.verticalSizeClass = vertical
            }
            #expect(AppInterfaceOrientationPolicy.supportedOrientations(for: traits) == mask)
        }
        let wide = AppWindowLayout(size: CGSize(width: 1_194, height: 834), isRegularWidth: true, interfaceIdiom: .pad)
        #expect(wide.isLandscape && wide.gridColumns.count == 2)
        #expect(!AppWindowLayout(size: CGSize(width: 834, height: 1_194), isRegularWidth: true).isLandscape)
        #expect(!AppWindowLayout(size: wide.size, isRegularWidth: false).isLandscape)
        #expect(!AppWindowLayout(size: wide.size, isRegularWidth: true, usesAccessibilityText: true).isLandscape)
        #expect(!AppWindowLayout(size: wide.size, isRegularWidth: true, availableWidth: 540).isLandscape)
        #expect(AppWindowLayout(size: wide.size, isRegularWidth: true, availableWidth: 760).gridColumns.count == 2)
        for height: CGFloat in [640, 744, 960] {
            let layout = AppWindowLayout(size: wide.size, isRegularWidth: true, availableHeight: height, interfaceIdiom: .pad)
            #expect(layout.sidebarWidth == height * 9 / 16)
            #expect(layout.singleColumn.sidebarWidth == layout.sidebarWidth)
        }
        let duo = AppWindowLayout(size: CGSize(width: 1_046, height: 744), isRegularWidth: true,
            availableWidth: 962, availableHeight: 724, interfaceIdiom: .phone,
            safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 84), divisionX: 523)
        #expect(duo.isLandscape && duo.hasLandscapeDivision && duo.contentTopInset == 16)
        #expect(!duo.usesBottomTabBar && !wide.usesBottomTabBar && !wide.singleColumn.usesBottomTabBar)
        #expect(duo.sidebarWidth == 523 && duo.singleColumn.sidebarWidth == 523)
        let closed = AppWindowLayout(size: CGSize(width: 466, height: 678),
            safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84))
        #expect(!closed.hasLandscapeDivision && closed.contentTopInset == 16)
        #expect(!closed.usesBottomTabBar)
#if targetEnvironment(macCatalyst)
        #expect(!closed.usesSideToolbar)
#else
        if #available(iOS 27.1, *) { #expect(closed.usesSideToolbar && closed.singleColumn.usesSideToolbar) }
#endif
        #expect(!duo.usesSideToolbar && !wide.usesSideToolbar)
        #expect(AppWindowLayout(size: CGSize(width: 402, height: 874), interfaceIdiom: .phone,
            safeAreaInsets: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)).usesBottomTabBar)
        #expect(AppWindowLayout(size: duo.size, isRegularWidth: true,
            safeAreaInsets: UIEdgeInsets(top: 0, left: 84, bottom: 20, right: 0), divisionX: 523).sidebarWidth == 439)
        #expect(AppWindowLayout(size: wide.size, safeAreaInsets: UIEdgeInsets(top: 32, left: 0, bottom: 20, right: 0)).contentTopInset == 0)
    }

    @Test func fixedColumnRowsContainScaledBodyText() {
        let values = ["长课程名称与完整的课程信息", "12345.6789"]
        let items = values.map { AppFixedColumnItem(text: $0, ratio: 1, font: .body, color: .primary) }
        func measured(_ view: AnyView, size: DynamicTypeSize) -> CGFloat {
            UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
                .sizeThatFits(in: CGSize(width: 320, height: 10_000)).height
        }
        let row = AnyView(AppFixedColumnRow(items: items, height: AppDesignSystem.Size.CompactRow.primaryHeight))
        let expandedTextHeight = values.reduce(CGFloat.zero) {
            $0 + measured(AnyView(Text($1).font(.body)), size: .accessibility5)
        }
        #expect(measured(row, size: .accessibility5) >= expandedTextHeight)
        #expect(measured(row, size: .large) >= measured(AnyView(Text(values[0]).font(.body)), size: .large))
    }

    @Test(.timeLimit(.minutes(1))) func repeatedAnimationFramesParticipateInTheDisplayMemoryBudget() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let first = renderer.image { UIColor.systemRed.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let last = renderer.image { UIColor.systemBlue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let image = try #require(UIImage.animatedImage(with: Array(repeating: first, count: 9_999) + [last], duration: 100))
        #expect(image.images?.count == 10_000)
        let pixels = MediaDisplayBudget.pixelBytes(image), bytes = MediaDisplayBudget.decodedBytes(image)
        #expect(bytes >= pixels + 80_000)
        let owner = UUID(), insufficient = MediaDisplayBudget(maximumBytes: pixels)
        #expect(insufficient.retain(image, owner: owner) == false && insufficient.usedBytes == 0)
        let sufficient = MediaDisplayBudget(maximumBytes: bytes)
        #expect(sufficient.retain(image, owner: owner) && sufficient.usedBytes == bytes)
        sufficient.release(owner: owner)
        #expect(sufficient.usedBytes == 0)
    }

    @Test(.timeLimit(.minutes(1))) func defaultMediaStorageEnforcesTheSharedQuotaOnce() async throws {
        let domain = "BIT101Tests.shared-media-quota", files = PreferenceMemoryFiles()
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let client = HTTPClient(transport: TraceTransport(), observer: nil)
        let media = AppMedia.makeEnvironment(previewStorage: MediaPreviewStorage(files: files), defaults: defaults,
            imageHTTPClient: client, avatarHTTPClient: client)
        media.cacheLimitMB = 1
        let scans = files.metadataScanCount
        await media.enforceCurrentLimit()
        #expect(files.metadataScanCount == scans + media.cacheDirectories.count)
    }

    private final class StreamingMessages: GalleryMessageServicing {
        var growing = true, unread = 5, identifiers = Array((1...6).reversed())
        var acknowledgementIDs: [Int]?
        var recoveryFailure: (any Error)?
        private var hasAcknowledged = false
        var cursors: [Int?] = []
        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts {
            if growing && !cursors.isEmpty { identifiers.insert((identifiers.first ?? 0) + 1, at: 0); unread += 1 }
            return .init(comment: unread)
        }
        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
            cursors.append(lastID)
            if lastID == nil {
                if let acknowledgementIDs { identifiers = acknowledgementIDs }
                unread = 0; hasAcknowledged = true
            } else if hasAcknowledged, let recoveryFailure { throw recoveryFailure }
            let rows = identifiers.filter { $0 < (lastID ?? Int.max) }.prefix(2).map {
                "{\"from_user\":{},\"id\":\($0),\"link_obj\":\"\",\"obj\":\"\",\"text\":\"message\",\"update_time\":\"\"}"
            }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode([GalleryMessage].self, from: Data(("[" + rows.joined(separator: ",") + "]").utf8))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func messageRecoveryBatchesPersistentWritesAndSurvivesInterruption(interrupted: Bool) async throws {
        let domain = "BIT101Tests.message-recovery-writes"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let files = PreferenceMemoryFiles(), root = URL(fileURLWithPath: "/message-recovery-writes")
        let session = AppStorageSession(accountIdentifier: domain)
        let store = GalleryMessageReadStore(files: files, storageRoot: root, defaults: defaults, session: { session })
        let service = StreamingMessages()
        service.growing = false; service.acknowledgementIDs = Array((1...2_000).reversed())
        if interrupted { service.recoveryFailure = URLError(.timedOut) }
        var saves = 0
        let observation = store.localSaves.sink { _ in saves += 1 }
        defer { withExtendedLifetime(observation) {} }
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts(); await model.refresh(type: .comment)
        if interrupted {
            #expect(store.pendingUnreadAfterID(for: .comment) == 6 && service.unread == 0)
            service.recoveryFailure = nil
            let reopened = GalleryMessageReadStore(files: files, storageRoot: root, defaults: defaults, session: { session })
            let retry = GalleryMessageViewModel(service: service, readStore: reopened)
            await retry.bootstrapIfNeeded()
            #expect(reopened.pendingUnreadAfterID(for: .comment) == nil && reopened.unreadCount(for: .comment) == 1_999)
            #expect(reopened.isUnread(id: 7, for: .comment) && reopened.isUnread(id: 2, for: .comment))
        } else {
            #expect(model.state(for: .comment).status == .loaded && store.pendingUnreadAfterID(for: .comment) == nil)
            #expect(store.unreadCount(for: .comment) == 1_999 && saves == 5)
        }
    }

    @Test(.timeLimit(.minutes(1))) func continuouslyGrowingMessagesRetainUnreadStateAndAllowRefreshRetry() async throws {
        let domain = "BIT101Tests.streaming-messages"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = GalleryMessageReadStore(files: PreferenceMemoryFiles(), storageRoot: URL(fileURLWithPath: "/streaming-messages"),
            defaults: defaults, session: { AppStorageSession(accountIdentifier: "streaming-messages") })
        let service = StreamingMessages(), model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts(); await model.refresh(type: .comment)
        #expect(service.cursors == [Int.max, Int.max] && service.unread == 7)
        #expect(model.alert?.title == "消息状态同步受阻" && store.unreadCount(for: .comment) == 0)
        #expect(store.pendingUnreadAfterID(for: .comment) == nil)
        service.growing = false; model.alert = nil
        await model.refreshSelectedType()
        #expect(model.state(for: .comment).status == .loaded && model.alert == nil)
        #expect(service.unread == 0 && store.unreadCount(for: .comment) == 7)
    }

    private final class ScoreCache: ScoreCaching {
        func recover(rows: [ScoreRow], for session: AppStorageSession) async -> Date? { nil }
        var changes: AnyPublisher<AppStorageSession, Never> { Empty().eraseToAnyPublisher() }
        var loads = 0
        var rows = [ScoreRow(index: 0, headers: ["课程名称", "成绩", "开课学期", "课程性质"],
            values: ["composition-score", "90", "fixture", "专业教育"])]
        func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot? {
            loads += 1
            return ScoreCacheSnapshot(rows: rows, updatedAt: Date(), detailedUpdatedAt: Date())
        }
        func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
        func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
    }
    private final class ScorePreferences: ScoreFilterPreferencesStoring {
        func reset() {}
        var changes: AnyPublisher<AppStorageSession, Never> { Empty().eraseToAnyPublisher() }
        var hasUnreadableSnapshot: Bool { false }
        func load() -> ScoreFilterPreferenceSnapshot? { nil }
        func save(selectedTerms: Set<String>, selectedCourseTypes: Set<String>, sortIndex: ScoreSortIndex, sortOrder: ScoreSortOrder) -> Bool { true }
    }
    private final class Scores: ScoreListServicing, TrustedTranscriptServicing {
        var schoolRequests = 0
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge { schoolRequests += 1; throw URLError(.notConnectedToInternet) }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] { schoolRequests += 1; return [] }
        func submitScoreVerificationCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { schoolRequests += 1; return challenge }
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages { schoolRequests += 1; return .init([]) }
        func submitTranscriptVerificationCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { schoolRequests += 1; return challenge }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages { schoolRequests += 1; return .init([]) }
    }

    @Test(.timeLimit(.minutes(1))) func scoreFiltersInitializeAfterScheduleOnlyCacheAndPreserveExplicitEmptySelection() async throws {
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
        #expect(model.selectedCourseTypes.isEmpty && preferences.load() == nil)
        cache.rows = rows
        await model.applySyncedScoreCacheIfAvailable()
        #expect(model.filteredRows == rows && model.selectedCourseTypes == ["专业教育"])
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
        return AppMedia.makeEnvironment(files: files, previewStorage: MediaPreviewStorage(files: files), defaults: AppFileDirectories.defaults,
                                imageHTTPClient: client, avatarHTTPClient: client)
    }

    private func dependencies(list: CourseList) -> CourseDependencies {
        let session = CommunitySession(httpClient: HTTPClient(transport: OfflineTransport(), observer: nil), baseURL: AppURL.required("https://example.invalid"), credentials: { CommunityCredentials(identity: CommunitySessionIdentity(accountIdentifier: "composition-test"), cookie: "fixture") }, refresh: { _ in })
        return CourseDependencies(list: list, detail: CourseService(session: session), preferences: CommunityPreferences(snapshot: CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false), saveMakeupFilter: { _ in }), networkPath: .init(), loadCourseCredits: { [] })
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
            feed: service, messageService: service, posterDetail: service, subscriptions: service,
            reporting: service, composer: service, images: service, preferences: preferences,
            messages: GalleryMessageReadStore(files: PreferenceMemoryFiles(), storageRoot: URL(fileURLWithPath: "/preference-sync"), defaults: AppFileDirectories.defaults, session: { AppStorageSession(accountIdentifier: "composition") }),
            drafts: ComposerDraftStore(files: PreferenceMemoryFiles(), applicationSupport: URL(fileURLWithPath: "/preference-sync"),
                session: { AppStorageSession(accountIdentifier: "composition") }, prepareImageData: ComposerDraftImageCompressor.compress),
            networkPath: NetworkPathState(snapshot: NetworkPathSnapshot(status: .connected)))
    }

    private func paper(_ transport: TraceTransport) -> PaperDependencies {
        let paperSession = session(transport)
        let service = PaperService(session: paperSession)
        return PaperDependencies(list: service, detail: service, composer: service,
            drafts: ComposerDraftStore(files: PreferenceMemoryFiles(), applicationSupport: URL(fileURLWithPath: "/paper-draft"), session: { AppStorageSession(accountIdentifier: "composition") }, prepareImageData: { $0 }), networkPath: NetworkPathState(snapshot: NetworkPathSnapshot(status: .connected)), currentIdentity: { paperSession.currentCredentials.identity })
    }

    private func mine(_ transport: TraceTransport) -> MineDependencies {
        let preferences = preferences()
        let service = MineService(session: session(transport), preferences: { preferences.snapshot })
        return MineDependencies(overview: service, profile: service, deletePoster: { _ in }, networkPath: .init(snapshot: .init(status: .connected)))
    }

    private func host<V: View>(_ view: V, navigation: Bool = true, operation: () async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: Group {
            if navigation { NavigationStack { view } }
            else { view }
        })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        try await operation()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        window.layoutIfNeeded()
    }

    @Test(.timeLimit(.minutes(1)))
    func galleryRootRoutesToItsExplicitPaperConsumer() async throws {
        let galleryTransport = TraceTransport()
        let paperTransport = TraceTransport()
        let surroundingTransport = TraceTransport()
        let selectedMedia = media()
        var routedIDs: [Int] = []
        let paperRoute = CommunityPaperDestination(papers: { requestedID, onShowFeed in
            if let id = requestedID.wrappedValue { routedIDs.append(id) }
            return AnyView(PaperRootView(dependencies: paper(paperTransport), media: selectedMedia,
                                        requestedPaperID: requestedID, onShowFeed: onShowFeed))
        }, detail: { AnyView(Text("paper \($0)")) })
        let view = GalleryRootView(dependencies: gallery(galleryTransport), media: selectedMedia,
            profiles: CommunityProfileDestination { AnyView(Text("profile \($0)")) }, papers: paperRoute,
            courses: CommunityCourseDestination { AnyView(Text("course \($0)")) },
            requestedPaperID: .constant(42))
            .environment(gallery(surroundingTransport)).environment(media())
        try await host(view) { try await paperTransport.waitForRequest() }
        #expect(routedIDs.contains(42))
        #expect(surroundingTransport.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func galleryWebPreferenceTakesEffectAfterNativePaperRoute() async throws {
        let dependencies = gallery(TraceTransport())
        var paperAppearances = 0
        let papers = CommunityPaperDestination(papers: { _, _ in
            AnyView(Text("paper").onAppear { paperAppearances += 1 })
        }, detail: { _ in AnyView(Text("paper")) })
        let view = GalleryRootView(dependencies: dependencies, media: media(),
            profiles: CommunityProfileDestination { _ in AnyView(Text("profile")) }, papers: papers,
            courses: CommunityCourseDestination { _ in AnyView(Text("course")) }, requestedPaperID: .constant(42))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), controller = UIHostingController(rootView: NavigationStack { view })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func webViews(in view: UIView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
        }
        try await waitForTestEvent { paperAppearances > 0 }
        #expect(webViews(in: controller.view).isEmpty)
        var snapshot = dependencies.preferences.snapshot
        snapshot.galleryUseWebView = true
        dependencies.preferences.apply(snapshot)
        try await waitForTestEvent { webViews(in: controller.view).count == 1 }
        webViews(in: controller.view).forEach { $0.stopLoading() }
        snapshot.galleryUseWebView = false
        dependencies.preferences.apply(snapshot)
        try await waitForTestEvent { webViews(in: controller.view).isEmpty }
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
        var paperDisappeared = false
    }

    private struct PaperTabs: View {
        @ObservedObject var route: TabRoute
        let dependencies: PaperDependencies
        let media: MediaEnvironment
        var body: some View {
            TabView(selection: $route.selection) {
                PaperRootView(dependencies: dependencies, media: media)
                    .onDisappear { route.paperDisappeared = true }
                    .tabItem { Text("文章") }.tag(0)
                Text("其他页面").onAppear { route.otherAppeared = true }
                    .tabItem { Text("其他") }.tag(1)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func paperTabReturnRetriesTheCancelledAuthorPreviewWithItsExistingList() async throws {
        let service = PaperPreviewService()
        defer {
            service.pending?.resume(returning: PaperPreviewMetadata(authorName: "迟到的作者", avatarURL: nil, isAnonymous: false))
            service.pending = nil
        }
        let routes = TabRoute()
        let paperSession = session(TraceTransport())
        let details = PaperService(session: paperSession)
        let dependencies = PaperDependencies(list: service, detail: details, composer: details,
            drafts: ComposerDraftStore(files: PreferenceMemoryFiles(), applicationSupport: URL(fileURLWithPath: "/paper-draft"), session: { AppStorageSession(accountIdentifier: "composition") }, prepareImageData: { $0 }), networkPath: NetworkPathState(snapshot: NetworkPathSnapshot(status: .connected)), currentIdentity: { paperSession.currentCredentials.identity })
        var phase = "首屏"
        do { try await host(PaperTabs(route: routes, dependencies: dependencies, media: media()), navigation: false) {
            try await waitForTestEvent { !(service.pending == nil || service.pages.count < 2) }
            phase = "切出文章"
            routes.selection = 1
            try await waitForTestEvent { routes.otherAppeared && routes.paperDisappeared }
            phase = "返回文章"
            routes.selection = 0
            try await waitForTestEvent { !(service.previewRequests < 2) }
            service.pending?.resume(returning: PaperPreviewMetadata(authorName: "迟到的作者", avatarURL: nil, isAnonymous: false))
            service.pending = nil
        } } catch {
            Issue.record("文章恢复阶段：\(phase)，页面请求：\(service.pages)，作者请求：\(service.previewRequests)，其他页：\(routes.otherAppeared)，文章离开：\(routes.paperDisappeared)。")
            throw error
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
        defer {
            refresh.cancel()
            service.pending?.resume(returning: .init(items: [], nextSourcePage: 1, canLoadMore: false)); service.pending = nil
        }
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

    @Test(.timeLimit(.minutes(1)))
    func authenticatedPaperReadsKeepTheirBusinessRoutes() async throws {
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
        #expect(transport.requests.map { $0.url?.path } == ["/papers/17", "/reaction/comments", "/reaction/comments"])
        let url = try #require(transport.requests.last?.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }) == ["obj": "paper17", "order": "new", "page": "1"])
    }

    @Test(.timeLimit(.minutes(1)))
    func mineAndProfileRootsOwnTheirServiceAndPosterCapabilities() async throws {
        let selected = TraceTransport()
        let surrounding = TraceTransport()
        let poster = CommunityPosterDestination { _ in AnyView(Text("poster")) }
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

    @Test(.timeLimit(.minutes(1))) func profileFollowUsesItsInjectedCommunitySessionAndUpdatesTheDisplayedCard() async throws {
        let transport = TraceTransport(); var following = false
        transport.response = { request in
            #expect(request.value(forHTTPHeaderField: "fake-cookie") == "fixture")
            if request.url?.path == "/user/info/42" {
                #expect(request.httpMethod == "GET")
                return Data(#"{"user":{"id":42,"createTime":"","nickname":"profile","avatar":{"mid":"","url":"","lowUrl":""},"motto":"","identity":{"id":0,"color":"","text":"","createTime":"","updateTime":"","deleteTime":null}},"followingNum":2,"followerNum":3,"following":false,"follower":false,"own":false}"#.utf8)
            }
            #expect(request.url?.path == "/user/follow/42")
            #expect(request.httpMethod == "POST")
            following.toggle(); return Data(#"{"following":\#(following),"follower":true,"followingNum":4,"followerNum":\#(following ? 5 : 4)}"#.utf8)
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
        #expect(transport.requests.count == 3 && model.userInfo?.following == false && model.userInfo?.followerNum == 4)
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
            .environmentObject(surrounding).environment(media())) {
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
        let papers = CommunityPaperDestination(papers: { _, _ in AnyView(Text("paper")) },
            detail: { AnyView(Text("paper \($0)")) })
        let courses = CommunityCourseDestination { AnyView(Text("course \($0)")) }
        try await replace(GalleryRootView(dependencies: gallery(first), media: selectedMedia, profiles: profiles, papers: papers, courses: courses),
            with: GalleryRootView(dependencies: gallery(second), media: selectedMedia, profiles: profiles, papers: papers, courses: courses),
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

@Suite("Schedule academic course matching")
@MainActor
struct CourseLookupMatcherTests {
    private final class ServiceStub: CourseListServicing {
        let results: [String: [CourseSummary]]
        var laterPages: [Int: [CourseSummary]] = [:]
        var repeatsFirstPage = false
        private var searches: [String] = []

        init(results: [String: [CourseSummary]]) {
            self.results = results
        }

        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            searches.append(search)
            return page == 0 || repeatsFirstPage ? results[search] ?? [] : laterPages[page] ?? []
        }

        func recordedSearches() -> [String] {
            searches
        }
    }

    @Test("Course number matching ignores formatting differences")
    func matchesCourseNumber() {
        let expected = makeSummary(id: 1, name: "高等数学", number: "MATH-1001", teacher: "张老师")
        let other = makeSummary(id: 2, name: "高等数学", number: "MATH-1002", teacher: "张老师")
        #expect(CourseLookupMatcher.bestMatch(
            courseNumber: " math 1001 ",
            courseName: "", teacher: "",
            candidates: [other, expected]
        )?.id == expected.id)
    }

    @Test func completeTeacherGroupsPrecedePartialMatches() {
        let partial = makeSummary(id: 1, name: "课程", number: "C1", teacher: "张、李")
        let complete = makeSummary(id: 2, name: "课程", number: "C1", teacher: "李、王")
        #expect(CourseLookupMatcher.bestMatch(courseNumber: "C1", courseName: "课程", teacher: "李、王",
            candidates: [partial, complete])?.id == 2)
        let another = makeSummary(id: 3, name: "课程", number: "C1", teacher: "王、赵")
        #expect(CourseLookupMatcher.bestMatch(courseNumber: "C1", courseName: "课程", teacher: "李、王",
            candidates: [partial, another]) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func resolverReadsLaterPagesAndPreservesTheNumberQueryFirstPage() async throws {
        let first = makeSummary(id: 1, name: "课程", number: "C1", teacher: "张")
        let second = makeSummary(id: 2, name: "课程", number: "C1", teacher: "王")
        let expected = makeSummary(id: 3, name: "课程", number: "C1", teacher: "李")
        let service = ServiceStub(results: ["C1": [first, second]])
        service.laterPages[1] = [expected]
        let result = try #require(await CourseEvaluationResolver(service: service).resolve(
            courseName: "", courseNumber: "C1", teacher: "李"))
        #expect(result.selectedCourse.id == 3 && result.searchQuery == "C1")
        #expect(result.searchResults.map(\.id) == [3, 1, 2])
        service.repeatsFirstPage = true
        do {
            _ = try await CourseEvaluationResolver(service: service).resolve(courseName: "", courseNumber: "C1", teacher: "李")
            Issue.record("重复后页需要保留首屏和协议错误")
        } catch {
            let recovery = try #require(error as? CourseEvaluationSearchRecovery)
            #expect(recovery.items.map(\.id) == [1, 2])
            #expect((recovery.underlying as? URLError)?.code == .badServerResponse)
        }
    }

    @Test("Teacher disambiguates courses with the same name")
    func disambiguatesByTeacher() {
        let first = makeSummary(id: 1, name: "大学物理", number: "PHY-1", teacher: "张老师")
        let second = makeSummary(id: 2, name: "大学物理", number: "PHY-2", teacher: "李老师")
        #expect(CourseLookupMatcher.bestMatch(
            courseNumber: "",
            courseName: "大学 物理",
            teacher: "李老师",
            candidates: [first, second]
        )?.id == second.id)
        #expect(CourseLookupMatcher.bestMatch(
            courseNumber: "",
            courseName: "大学物理",
            teacher: "",
            candidates: [first, second]
        ) == nil)
    }

    @Test("Teacher also disambiguates records sharing one course number")
    func disambiguatesSameNumberByTeacher() {
        let first = makeSummary(id: 1, name: "线性代数", number: "MATH-1", teacher: "张老师")
        let second = makeSummary(id: 2, name: "线性代数", number: "MATH-1", teacher: "李老师、王老师")
        #expect(CourseLookupMatcher.bestMatch(
            courseNumber: "MATH-1",
            courseName: "",
            teacher: "李老师",
            candidates: [first, second]
        )?.id == second.id)
    }

    @Test("Records sharing the same course identity can be opened without a teacher")
    func resolvesSameIdentityWithoutTeacher() {
        let first = makeSummary(id: 1, name: "线性代数", number: "MATH-1", teacher: "张老师")
        let second = makeSummary(id: 2, name: "线性代数", number: "MATH-1", teacher: "李老师")
        #expect(CourseLookupMatcher.bestMatch(
            courseNumber: "MATH-1",
            courseName: "线性代数",
            teacher: "",
            candidates: [first, second]
        )?.id == first.id)
    }

    @Test("Evaluation lookup searches both identity fields and normalizes punctuation", .timeLimit(.minutes(1)))
    @MainActor
    func evaluationLookupFallsBackToCourseName() async throws {
        let expected = makeSummary(
            id: 7,
            name: "自动控制理论II（双语）",
            number: "AUTO-1",
            teacher: ""
        )
        let service = ServiceStub(results: [
            "AUTO 1": [],
            "自动控制理论II(双语)": [expected],
        ])

        let result = try #require(await CourseEvaluationResolver(service: service).resolve(
            courseName: "自动控制理论II(双语)",
            courseNumber: "AUTO 1"
        ))

        #expect(result.selectedCourse.id == expected.id)
        #expect(result.searchQuery == "自动控制理论II(双语)")
        #expect(result.searchResults.map(\.id) == [expected.id])
        let searches = service.recordedSearches()
        #expect(Set(searches) == ["AUTO 1", "自动控制理论II(双语)"])
    }

    @Test("Unknown evaluation course resolves to a failure result", .timeLimit(.minutes(1)))
    @MainActor
    func evaluationLookupReturnsNilWhenNoCourseMatches() async throws {
        let service = ServiceStub(results: [:])
        let result = try await CourseEvaluationResolver(service: service).resolve(
            courseName: "不存在的课程",
            courseNumber: "UNKNOWN-1"
        )
        #expect(result == nil)
    }

    @Test("Resolver queries both identities while selecting the current teacher", .timeLimit(.minutes(1)))
    @MainActor
    func resolvesBothIdentitiesAndSelectsTeacher() async throws {
        let first = makeSummary(id: 1, name: "大学物理", number: "PHY-1", teacher: "张老师")
        let second = makeSummary(id: 2, name: "大学物理", number: "PHY-1", teacher: "李老师")
        let service = ServiceStub(results: [
            "PHY-1": [first, second],
            "大学物理": [first, second],
        ])
        let resolver = ScheduleAcademicCourseResolver(service: service)

        let resolution = try #require(await resolver.resolve(makeCourse(
            name: "大学物理",
            number: "PHY-1",
            teacher: "李老师"
        )))

        let searches = service.recordedSearches()
        #expect(Set(searches) == ["PHY-1", "大学物理"])
        #expect(resolution.selectedCourse.id == second.id)
    }

    private func makeSummary(
        id: Int,
        name: String,
        number: String,
        teacher: String
    ) -> CourseSummary {
        CourseSummary(detail: CourseDetail(
            id: id,
            name: name,
            number: number,
            credit: 2,
            likeNum: 0,
            commentNum: 0,
            rate: 0,
            teachersName: teacher,
            teachersNumber: "",
            like: false
        ))
    }

    private func makeCourse(name: String, number: String, teacher: String) -> CourseRecord {
        CourseRecord(
            id: "schedule-course",
            term: "2026-2027-1",
            name: name,
            teacher: teacher,
            classroom: "",
            description: "",
            weeks: [1],
            weekday: 1,
            startSection: 1,
            endSection: 2,
            campus: "",
            number: number,
            credit: 2,
            hour: 32,
            type: "",
            category: "",
            department: ""
        )
    }
}


// 内存响应替身沿测试模块提供接收完成后的预算适配。
extension HTTPTransport {
    func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
        let result = try await data(for: request)
        if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
        return result
    }
}

extension ExperimentalPreferenceCloudSyncTests {
    final class ExternalDisplays: AppExternalDisplayCoordinating {
        var activationCount = 0
        var resetCount = 0
        var refreshes: [(String, AppStorageSession)] = []
        func activate() { activationCount += 1 }
        func resetAccountPresentation() { resetCount += 1 }
        func refresh(trigger: String, syncWidgetSnapshot: Bool, session: AppStorageSession) async {
            #expect(syncWidgetSnapshot)
            refreshes.append((trigger, session))
        }
        func waitForRefreshes(_ count: Int) async throws {
            try await waitForTestEvent { refreshes.count >= count }
        }
    }

    struct OfflineTransport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
    }
    struct OfflineScoreService: ScoreListServicing, TrustedTranscriptServicing {
        let transcriptServiceIdentity: AnyHashable = UUID()
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge { throw URLError(.notConnectedToInternet) }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] { [] }
        func submitScoreVerificationCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { challenge }
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages { .init([]) }
        func submitTranscriptVerificationCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { return challenge }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages { .init([]) }
    }

}
