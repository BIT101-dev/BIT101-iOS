import ClientCore
import Combine
import CommunityCore
import CommunityPersistence
import CommunityTransport
import CommunityUI
import DesignSystemKit
import Foundation
import ScheduleDomain
import ScoreDomain
import ScoreInfrastructure
import ScorePorts
import StorageCore
import SwiftUI
import Testing
import TransportCore
import UIKit
import WebKit

@testable import BIT101_iOS
@testable import CourseFeature
@testable import GalleryFeature
@testable import MediaKit
@testable import MineFeature
@testable import PaperFeature
@testable import ScheduleFeature
@testable import ScoreFeature

@MainActor
@Suite(.serialized)
struct FeatureCompositionTests {

    @Test func fixedColumnRowsContainScaledBodyText() {
        let values = ["长课程名称与完整的课程信息", "12345.6789"]
        let items = values.map {
            AppFixedColumnItem(text: $0, ratio: 1, font: .body, color: .primary)
        }
        func measured(_ view: AnyView, size: DynamicTypeSize) -> CGFloat {
            UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
                .sizeThatFits(in: CGSize(width: 320, height: 10_000)).height
        }
        let row = AnyView(
            AppFixedColumnRow(items: items, height: AppDesignSystem.Size.CompactRow.primaryHeight))
        let expandedTextHeight = values.reduce(CGFloat.zero) {
            $0 + measured(AnyView(Text($1).font(.body)), size: .accessibility5)
        }
        #expect(measured(row, size: .accessibility5) >= expandedTextHeight)
        #expect(
            measured(row, size: .large)
                >= measured(AnyView(Text(values[0]).font(.body)), size: .large))
    }

    @Test(.timeLimit(.minutes(1))) func repeatedAnimationFramesBudget() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let first = renderer.image {
            UIColor.systemRed.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let last = renderer.image {
            UIColor.systemBlue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let image = try #require(
            UIImage.animatedImage(
                with: Array(repeating: first, count: 9_999) + [last], duration: 100))
        #expect(image.images?.count == 10_000)
        let pixels = MediaDisplayBudget.pixelBytes(image)
        let bytes = MediaDisplayBudget.decodedBytes(image)
        #expect(bytes >= pixels + 80_000)
        let owner = UUID()
        let insufficient = MediaDisplayBudget(maximumBytes: pixels)
        #expect(insufficient.retain(image, owner: owner) == false && insufficient.usedBytes == 0)
        let sufficient = MediaDisplayBudget(maximumBytes: bytes)
        #expect(sufficient.retain(image, owner: owner) && sufficient.usedBytes == bytes)
        sufficient.release(owner: owner)
        #expect(sufficient.usedBytes == 0)
    }

    @Test(.timeLimit(.minutes(1))) func defaultMediaStorageEnforcesQuotaOnce() async throws {
        let domain = "BIT101Tests.shared-media-quota"
        let files = PreferenceMemoryFiles()
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let client = HTTPClient(transport: TraceTransport(), observer: nil)
        let media = AppMedia.makeEnvironment(
            previewStorage: MediaPreviewStorage(files: files), defaults: defaults,
            imageHTTPClient: client, avatarHTTPClient: client)
        media.cacheLimitMB = 1
        let scans = files.metadataScanCount
        await media.enforceCurrentLimit()
        #expect(files.metadataScanCount == scans + media.cacheDirectories.count)
    }

    final class StreamingMessages: GalleryMessageServicing {
        var growing = true, unread = 5, identifiers = Array((1...6).reversed())
        var acknowledgementIDs: [Int]?
        var recoveryFailure: (any Error)?
        private var hasAcknowledged = false
        var cursors: [Int?] = []
        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts {
            if growing && !cursors.isEmpty {
                identifiers.insert((identifiers.first ?? 0) + 1, at: 0)
                unread += 1
            }
            return .init(comment: unread)
        }
        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage]
        {
            cursors.append(lastID)
            if lastID == nil {
                if let acknowledgementIDs { identifiers = acknowledgementIDs }
                unread = 0
                hasAcknowledged = true
            } else if hasAcknowledged, let recoveryFailure {
                throw recoveryFailure
            }
            let rows = identifiers.filter { $0 < (lastID ?? Int.max) }.prefix(2).map {
                """
                {\"from_user\":{},\"id\":\($0),\"link_obj\":\"\",\"obj\":\"\",\"text\":\"messag\
                e\",\"update_time\":\"\"}
                """
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(
                [GalleryMessage].self, from: Data(("[" + rows.joined(separator: ",") + "]").utf8))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func messageRecoveryBatchesPersistentWrites(interrupted: Bool) async throws {
        let domain = "BIT101Tests.message-recovery-writes"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let files = PreferenceMemoryFiles()
        let root = URL(fileURLWithPath: "/message-recovery-writes")
        let session = AppStorageSession(accountIdentifier: domain)
        let store = GalleryMessageReadStore(
            files: files, storageRoot: root, defaults: defaults, session: { session })
        let service = StreamingMessages()
        service.growing = false
        service.acknowledgementIDs = Array((1...2_000).reversed())
        if interrupted { service.recoveryFailure = URLError(.timedOut) }
        var saves = 0
        let observation = store.localSaves.sink { _ in saves += 1 }
        defer { withExtendedLifetime(observation) {} }
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        await model.refresh(type: .comment)
        if interrupted {
            #expect(store.pendingUnreadAfterID(for: .comment) == 6 && service.unread == 0)
            service.recoveryFailure = nil
            let reopened = GalleryMessageReadStore(
                files: files, storageRoot: root, defaults: defaults, session: { session })
            let retry = GalleryMessageViewModel(service: service, readStore: reopened)
            await retry.bootstrapIfNeeded()
            #expect(
                reopened.pendingUnreadAfterID(for: .comment) == nil
                    && reopened.unreadCount(for: .comment) == 1_999)
            #expect(
                reopened.isUnread(id: 7, for: .comment) && reopened.isUnread(id: 2, for: .comment))
        } else {
            #expect(
                model.state(for: .comment).status == .loaded
                    && store.pendingUnreadAfterID(for: .comment) == nil)
            #expect(store.unreadCount(for: .comment) == 1_999 && saves == 5)
        }
    }

    @Test(.timeLimit(.minutes(1))) func continuouslyGrowingMessagesRetainState() async throws {
        let domain = "BIT101Tests.streaming-messages"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = GalleryMessageReadStore(
            files: PreferenceMemoryFiles(),
            storageRoot: URL(fileURLWithPath: "/streaming-messages"),
            defaults: defaults,
            session: { AppStorageSession(accountIdentifier: "streaming-messages") })
        let service = StreamingMessages()
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        await model.refresh(type: .comment)
        #expect(service.cursors == [Int.max, Int.max] && service.unread == 7)
        #expect(model.alert?.title == "消息状态同步受阻" && store.unreadCount(for: .comment) == 0)
        #expect(store.pendingUnreadAfterID(for: .comment) == nil)
        service.growing = false
        model.alert = nil
        await model.refreshSelectedType()
        #expect(model.state(for: .comment).status == .loaded && model.alert == nil)
        #expect(service.unread == 0 && store.unreadCount(for: .comment) == 7)
    }

    final class ScoreCache: ScoreCaching {
        func recover(rows: [ScoreRow], for session: AppStorageSession) async -> Date? { nil }
        var changes: AnyPublisher<AppStorageSession, Never> { Empty().eraseToAnyPublisher() }
        var loads = 0
        var rows = [
            ScoreRow(
                index: 0, headers: ["课程名称", "成绩", "开课学期", "课程性质"],
                values: ["composition-score", "90", "fixture", "专业教育"])
        ]
        func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot? {
            loads += 1
            return ScoreCacheSnapshot(rows: rows, updatedAt: Date(), detailedUpdatedAt: Date())
        }
        func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
        func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
    }
    final class ScorePreferences: ScoreFilterPreferencesStoring {
        func reset() {}
        var changes: AnyPublisher<AppStorageSession, Never> { Empty().eraseToAnyPublisher() }
        var hasUnreadableSnapshot: Bool { false }
        func load() -> ScoreFilterPreferenceSnapshot? { nil }
        func save(
            selectedTerms: Set<String>, selectedCourseTypes: Set<String>, sortIndex: ScoreSortIndex,
            sortOrder: ScoreSortOrder
        ) -> Bool { true }
    }
    final class Scores: ScoreListServicing, TrustedTranscriptServicing {
        var schoolRequests = 0
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            schoolRequests += 1
            throw URLError(.notConnectedToInternet)
        }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge)
            async throws -> [ScoreRow]
        {
            schoolRequests += 1
            return []
        }
        func submitScoreCode(_ code: String, for challenge: BITLoginAuthenticationChallenge)
            async throws -> BITLoginAuthenticationChallenge
        {
            schoolRequests += 1
            return challenge
        }
        func fetchTrustedPages(onPage: TrustedTranscriptPageDelivery?) async throws
            -> TrustedTranscriptPages
        {
            schoolRequests += 1
            return .init([])
        }
        func submitTranscriptCode(_ code: String, for challenge: BITLoginAuthenticationChallenge)
            async throws -> BITLoginAuthenticationChallenge
        {
            schoolRequests += 1
            return challenge
        }
        func fetchTrustedPages(
            authenticatedBy challenge: BITLoginAuthenticationChallenge,
            onPage: TrustedTranscriptPageDelivery?
        ) async throws -> TrustedTranscriptPages {
            schoolRequests += 1
            return .init([])
        }
    }

    @Test(.timeLimit(.minutes(1))) func scoreFiltersInitializePreserveSelection() async throws {
        let suite = "BIT101.ScoreFilterInitialization"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppStorageSession(accountIdentifier: "composition-score")
        let preferences = ScoreFilterPreferenceStore(defaults: defaults, session: { session })
        let cache = ScoreCache()
        let rows = cache.rows
        cache.rows = []
        let course = ScoreCourseSummary(
            id: "pending", term: "fixture", name: "pending", number: "pending", type: "必修",
            teacher: "", classroom: "", campus: "", description: "", creditText: "3",
            scheduleText: "", weeksText: "", hourText: "")
        let model = ScoreViewModel(
            service: Scores(), cacheStore: cache, preferenceStore: preferences,
            currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in ["fixture": [course]] })
        await model.restoreCachedDataIfNeeded()
        model.setSortIndex(.score)
        #expect(model.selectedTerms == ["fixture"] && model.availableCourseTypes.isEmpty)
        #expect(model.selectedCourseTypes.isEmpty && preferences.load() == nil)
        cache.rows = rows
        await model.applySyncedScores()
        #expect(model.filteredRows == rows && model.selectedCourseTypes == ["专业教育"])
        #expect(preferences.load()?.sortIndex == ScoreSortIndex.score.rawValue)
        model.toggleAllCourseTypes()
        await model.applySyncedScores()
        #expect(model.filteredRows.isEmpty && preferences.load()?.selectedCourseTypes == [])
    }

    @Test(.timeLimit(.minutes(1)))
    func scoreEntryRestoresSelectedCache() async throws {
        let selected = ScoreCache()
        let service = Scores()
        let viewModel = ScoreViewModel(
            service: service, cacheStore: selected, preferenceStore: ScorePreferences(),
            currentScoreCacheSession: { AppStorageSession(accountIdentifier: "composition-score") },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] }
        )
        var notice: String?
        try await host(
            ScoreListPage(
                viewModel: viewModel, transcriptService: service, onSearchCourse: { _ in }
            )
            .environment(\.appDiagnosticAlert, { notice = $0.message })
        ) {
            try await waitForTestEvent { !(viewModel.filteredRows.isEmpty) }
            #expect(viewModel.filteredRows.first?.courseName == "composition-score")
            viewModel.alert = .informational(title: "成绩已是最新", message: "本次获取结果与本地成绩完全一致。")
            try await waitForTestEvent { notice != nil }
            #expect(notice == "本次获取结果与本地成绩完全一致。")
        }
        #expect(selected.loads == 1)
        #expect(service.schoolRequests == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func mountedTranscriptPageUsesService() async throws {
        let first = Scores()
        let second = Scores()
        let selectedMedia = media()
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: NavigationStack {
                TrustedTranscriptDestination(service: first).environment(selectedMedia)
            })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitForTestEvent { !(first.schoolRequests == 0) }
        controller.rootView = NavigationStack {
            TrustedTranscriptDestination(service: second).environment(selectedMedia)
        }
        try await waitForTestEvent { !(second.schoolRequests == 0) }
        #expect(first.schoolRequests == 1)
        #expect(second.schoolRequests == 1)
        #expect(first.transcriptServiceIdentity != second.transcriptServiceIdentity)
    }

    final class CourseList: CourseListServicing {
        var requests: [String] = []

        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            requests.append(search)
            return []
        }

        func waitForLookup() async throws {
            try await waitForTestEvent { requests.count >= 2 }
        }
    }

    struct OfflineTransport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            throw URLError(.notConnectedToInternet)
        }
    }

    func media() -> MediaEnvironment {
        let files = PreferenceMemoryFiles()
        let client = HTTPClient(transport: OfflineTransport(), observer: nil)
        return AppMedia.makeEnvironment(
            files: files, previewStorage: MediaPreviewStorage(files: files),
            defaults: AppFileDirectories.defaults,
            imageHTTPClient: client, avatarHTTPClient: client)
    }

    func dependencies(list: CourseList) -> CourseDependencies {
        let session = CommunitySession(
            httpClient: HTTPClient(transport: OfflineTransport(), observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                CommunityCredentials(
                    identity: CommunitySessionIdentity(accountIdentifier: "composition-test"),
                    cookie: "fixture")
            }, refresh: { _ in })
        return CourseDependencies(
            list: list, detail: CourseService(session: session),
            preferences: CommunityPreferences(
                snapshot: CommunityPreferenceSnapshot(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false), saveMakeupFilter: { _ in }), networkPath: .init(),
            loadCourseCredits: { [] })
    }

    @Test(.timeLimit(.minutes(1)))
    func courseEntryUsesConstructorComposition() async throws {
        let selected = CourseList()
        let surrounding = CourseList()
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: NavigationStack {
                CourseEvaluationDestination(
                    dependencies: dependencies(list: selected), media: media(),
                    profiles: CommunityProfileDestination { AnyView(Text("profile \($0)")) },
                    request: .lookup(courseName: "课程", courseNumber: "COURSE-1"))
            }.environment(dependencies(list: surrounding)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await selected.waitForLookup()
        #expect(Set(selected.requests) == ["课程", "COURSE-1"])
        #expect(surrounding.requests.isEmpty)
    }
    final class TraceTransport: HTTPTransport {
        var requests: [URLRequest] = []
        var response: ((URLRequest) throws -> Data)?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            if let response {
                let url = try #require(request.url)
                return (
                    try response(request),
                    try #require(
                        HTTPURLResponse(
                            url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                )
            }
            throw URLError(.notConnectedToInternet)
        }
        func waitForRequest(count: Int = 1) async throws {
            try await waitForTestEvent { requests.count >= count }
        }
    }

    func session(_ transport: TraceTransport) -> CommunitySession {
        CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                CommunityCredentials(
                    identity: CommunitySessionIdentity(accountIdentifier: "composition"),
                    cookie: "fixture")
            },
            refresh: { _ in })
    }

    func preferences() -> CommunityPreferences {
        CommunityPreferences(
            snapshot: CommunityPreferenceSnapshot(
                hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
                useWebView: false, hideMakeupOutliers: false), saveMakeupFilter: { _ in })
    }

    func gallery(_ transport: TraceTransport) -> GalleryDependencies {
        let session = session(transport)
        let preferences = preferences()
        let service = GalleryService(session: session, preferences: { preferences.snapshot })
        return GalleryDependencies(
            webCredentials: .init(
                cookie: { session.fakeCookie },
                changes: session.credentialsChanges.map { _ in () }.eraseToAnyPublisher()),
            currentIdentity: { session.currentCredentials.identity },
            feed: service, messageService: service, posterDetail: service, subscriptions: service,
            reporting: service, composer: service, images: service, preferences: preferences,
            messages: GalleryMessageReadStore(
                files: PreferenceMemoryFiles(),
                storageRoot: URL(fileURLWithPath: "/preference-sync"),
                defaults: AppFileDirectories.defaults,
                session: { AppStorageSession(accountIdentifier: "composition") }),
            drafts: ComposerDraftStore(
                files: PreferenceMemoryFiles(),
                applicationSupport: URL(fileURLWithPath: "/preference-sync"),
                session: { AppStorageSession(accountIdentifier: "composition") },
                prepareImageData: ComposerDraftImageCompressor.compress),
            networkPath: NetworkPathState(snapshot: NetworkPathSnapshot(status: .connected)))
    }

    func paper(_ transport: TraceTransport) -> PaperDependencies {
        let paperSession = session(transport)
        let service = PaperService(session: paperSession)
        return PaperDependencies(
            list: service, detail: service, composer: service,
            drafts: ComposerDraftStore(
                files: PreferenceMemoryFiles(),
                applicationSupport: URL(fileURLWithPath: "/paper-draft"),
                session: { AppStorageSession(accountIdentifier: "composition") },
                prepareImageData: { $0 }),
            networkPath: NetworkPathState(snapshot: NetworkPathSnapshot(status: .connected)),
            currentIdentity: { paperSession.currentCredentials.identity })
    }

    func mine(_ transport: TraceTransport) -> MineDependencies {
        let preferences = preferences()
        let service = MineService(
            session: session(transport), preferences: { preferences.snapshot })
        return MineDependencies(
            overview: service, profile: service, deletePoster: { _ in },
            networkPath: .init(snapshot: .init(status: .connected)))
    }

    func host<V: View>(
        _ view: V, navigation: Bool = true, operation: () async throws -> Void
    ) async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: Group {
                if navigation { NavigationStack { view } } else { view }
            })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        try await operation()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        window.layoutIfNeeded()
    }

    @Test(.timeLimit(.minutes(1)))
    func galleryRootRoutesExplicitPaperConsumer() async throws {
        var requestedPaperID: Int? = 42
        let galleryTransport = TraceTransport()
        let paperTransport = TraceTransport()
        let surroundingTransport = TraceTransport()
        let selectedMedia = media()
        var routedIDs: [Int] = []
        let paperRoute = CommunityPaperDestination(
            papers: { requestedID, onShowFeed in
                if let id = requestedID.wrappedValue { routedIDs.append(id) }
                return AnyView(
                    PaperRootView(
                        dependencies: paper(paperTransport), media: selectedMedia,
                        requestedPaperID: requestedID, onShowFeed: onShowFeed))
            }, detail: { AnyView(Text("paper \($0)")) })
        let view = GalleryRootView(
            dependencies: gallery(galleryTransport), media: selectedMedia,
            profiles: CommunityProfileDestination { AnyView(Text("profile \($0)")) },
            papers: paperRoute,
            courses: CommunityCourseDestination { AnyView(Text("course \($0)")) },
            requestedPaperID: Binding(get: { requestedPaperID }, set: { requestedPaperID = $0 })
        )
        .environment(gallery(surroundingTransport)).environment(media())
        try await host(view) { try await paperTransport.waitForRequest() }
        #expect(routedIDs.contains(42))
        #expect(surroundingTransport.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func galleryWebPrefTakesEffect() async throws {
        var requestedPaperID: Int? = 42
        let dependencies = gallery(TraceTransport())
        var paperAppearances = 0
        let papers = CommunityPaperDestination(
            papers: { _, _ in
                AnyView(Text("paper").onAppear { paperAppearances += 1 })
            }, detail: { _ in AnyView(Text("paper")) })
        let view = GalleryRootView(
            dependencies: dependencies, media: media(),
            profiles: CommunityProfileDestination { _ in AnyView(Text("profile")) }, papers: papers,
            courses: CommunityCourseDestination { _ in AnyView(Text("course")) },
            requestedPaperID: Binding(get: { requestedPaperID }, set: { requestedPaperID = $0 }))
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack { view })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func webViews(in view: UIView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
        }
        try await waitForTestEvent { paperAppearances > 0 }
        requestedPaperID = nil
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
        try await host(
            PaperRootView(dependencies: paper(selected), media: media())
                .environment(paper(surrounding)).environment(media())
        ) { try await selected.waitForRequest() }
        #expect(surrounding.requests.isEmpty)
    }

    final class PaperPreviewService: PaperListServicing {
        let summary = PaperSummary(
            id: 1, title: "页面返回验收", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        var pages: [Int] = []
        var previewRequests = 0
        var pending: CheckedContinuation<PaperPreviewMetadata, Never>?
        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws
            -> [PaperSummary]
        {
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

    @Observable final class TabRoute {
        var selection = 0
        @ObservationIgnored var otherAppeared = false
        @ObservationIgnored var paperDisappeared = false
    }

    struct PaperTabs: View {
        @Bindable var route: TabRoute
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
    func paperTabReturnRetriesCancelledList() async throws {
        let service = PaperPreviewService()
        defer {
            service.pending?.resume(
                returning: PaperPreviewMetadata(
                    authorName: "迟到的作者", avatarURL: nil, isAnonymous: false))
            service.pending = nil
        }
        let routes = TabRoute()
        let paperSession = session(TraceTransport())
        let details = PaperService(session: paperSession)
        let dependencies = PaperDependencies(
            list: service, detail: details, composer: details,
            drafts: ComposerDraftStore(
                files: PreferenceMemoryFiles(),
                applicationSupport: URL(fileURLWithPath: "/paper-draft"),
                session: { AppStorageSession(accountIdentifier: "composition") },
                prepareImageData: { $0 }),
            networkPath: NetworkPathState(snapshot: NetworkPathSnapshot(status: .connected)),
            currentIdentity: { paperSession.currentCredentials.identity })
        var phase = "首屏"
        do {
            try await host(
                PaperTabs(route: routes, dependencies: dependencies, media: media()),
                navigation: false
            ) {
                try await waitForTestEvent { !(service.pending == nil || service.pages.count < 2) }
                phase = "切出文章"
                routes.selection = 1
                try await waitForTestEvent { routes.otherAppeared && routes.paperDisappeared }
                phase = "返回文章"
                routes.selection = 0
                try await waitForTestEvent { !(service.previewRequests < 2) }
                service.pending?.resume(
                    returning: PaperPreviewMetadata(
                        authorName: "迟到的作者", avatarURL: nil, isAnonymous: false))
                service.pending = nil
            }
        } catch {
            Issue.record(
                """
                文章恢复阶段：\(phase)，页面请求：\(service.pages)，作者请求：\(service.previewRequests)，其他页：\
                \(routes.otherAppeared)，文章离开：\(routes.paperDisappeared)。
                """
            )
            throw error
        }
        #expect(service.previewRequests == 2 && service.pages == [0, 1])
    }

    final class GalleryFeed: GalleryFeedServicing {
        var pages: [Int] = []
        var pending: CheckedContinuation<GalleryPageBatch<CommunityPoster>, Never>?
        var suspend = false
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<
            CommunityPoster
        > {
            let page = page ?? 0
            pages.append(page)
            if suspend { return await withCheckedContinuation { pending = $0 } }
            let poster = CommunityPoster(
                anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0,
                createTime: "", editTime: "", id: page + 1, images: [], likeNum: 0, public: true,
                tags: [], text: "", title: "分页验收", updateTime: "",
                user: .placeholder(id: 1, nickname: "作者"))
            return .init(
                items: page < 2 ? [poster] : [], nextSourcePage: page + 1, canLoadMore: page < 2)
        }
        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            try await fetchFeed(kind: .recommend, page: sourcePage)
        }
        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            try await fetchFeed(kind: .bot, page: startPage)
        }
        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<
            CommunityPoster
        > { try await fetchFeed(kind: .newest, page: page) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func galleryOwnerExitRestoresPaginationRefresh(exhausted: Bool) async throws {
        let service = GalleryFeed()
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .newest)
        await model.loadMoreIfNeeded(
            for: .newest, currentPoster: model.state(for: .newest).posters.last)
        if exhausted {
            await model.loadMoreIfNeeded(
                for: .newest, currentPoster: model.state(for: .newest).posters.last)
        }
        let previous = model.state(for: .newest)
        service.suspend = true
        let refresh = model.enqueueRefresh(for: .newest)
        defer {
            refresh.cancel()
            service.pending?.resume(
                returning: .init(items: [], nextSourcePage: 1, canLoadMore: false))
            service.pending = nil
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
    func authedPaperReadsKeepTheirBusinessRoutes() async throws {
        let transport = TraceTransport()
        transport.response = { request in
            switch request.url?.path {
            case "/user/check": return Data("{}".utf8)
            case "/papers/17":
                return Data(
                    #"""
                    {"id":17,"title":"文章","intro":"","content":"","create_time":"","update_tim\#
                    e":"","update_user":{"id":1,"create_time":"","nickname":"作者","avatar":{"mi\#
                    d":"","url":"","low_url":""},"motto":"","identity":{"id":0,"color":"","tex\#
                    t":"","create_time":"","update_time":"","delete_time":null}},"anonymous":f\#
                    alse,"like_num":0,"comment_num":0,"public_edit":false,"like":false,"own":f\#
                    alse}
                    """#
                    .utf8)
            case "/reaction/comments": return Data("[]".utf8)
            default: throw URLError(.unsupportedURL)
            }
        }
        let service = PaperService(session: session(transport))
        _ = try await service.fetchPaper(id: 17)
        _ = try await service.fetchComments(paperID: 17, order: .newest, page: 0)
        _ = try await service.fetchComments(paperID: 17, order: .newest, page: 1)
        #expect(
            transport.requests.map { $0.url?.path } == [
                "/papers/17", "/reaction/comments", "/reaction/comments",
            ])
        let url = try #require(transport.requests.last?.url)
        let query = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(
            Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }) == [
                "obj": "paper17", "order": "new", "page": "1",
            ])
    }

    @Test(.timeLimit(.minutes(1)))
    func mineAnd() async throws {
        let selected = TraceTransport()
        let surrounding = TraceTransport()
        let poster = CommunityPosterDestination { _ in AnyView(Text("poster")) }
        let settings = CommunitySettingsDestinations(
            settingsEntries: [], settings: { _ in AnyView(Text("settings")) },
            suggestion: { AnyView(Text("suggestion")) })
        try await host(
            MineRootView(
                dependencies: mine(selected), media: media(), posters: poster, settings: settings,
                fallbackStudentID: "fixture", onLogout: {}
            ).environment(mine(surrounding))
        ) { try await selected.waitForRequest() }
        #expect(surrounding.requests.isEmpty)
        let profile = TraceTransport()
        try await host(
            UserProfileRootView(
                dependencies: mine(profile), media: media(), posters: poster, userID: 42
            )
            .environment(mine(surrounding))
        ) { try await profile.waitForRequest() }
        #expect(surrounding.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func profileFollowUsesInjectedCommunitySession() async throws {
        let transport = TraceTransport()
        var following = false
        transport.response = { request in
            #expect(request.value(forHTTPHeaderField: "fake-cookie") == "fixture")
            if request.url?.path == "/user/info/42" {
                #expect(request.httpMethod == "GET")
                return Data(
                    #"""
                    {"user":{"id":42,"createTime":"","nickname":"profile","avatar":{"mid":"","\#
                    url":"","lowUrl":""},"motto":"","identity":{"id":0,"color":"","text":"","c\#
                    reateTime":"","updateTime":"","deleteTime":null}},"followingNum":2,"follow\#
                    erNum":3,"following":false,"follower":false,"own":false}
                    """#
                    .utf8)
            }
            #expect(request.url?.path == "/user/follow/42")
            #expect(request.httpMethod == "POST")
            following.toggle()
            return Data(
                #"""
                {"following":\#(following),"follower":true,"followingNum":4,"followerNum":\#
                \#(following ? 5 : 4)}
                """#
                .utf8)
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
        #expect(
            transport.requests.count == 3 && model.userInfo?.following == false
                && model.userInfo?.followerNum == 4)
    }

    func replace<V: View>(
        _ first: V, with second: V, firstTransport: TraceTransport, secondTransport: TraceTransport,
        initialRequests: Int = 1
    ) async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack { first })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await firstTransport.waitForRequest(count: initialRequests)
        let firstCount = firstTransport.requests.count
        controller.rootView = NavigationStack { second }
        try await secondTransport.waitForRequest(count: initialRequests)
        #expect(firstTransport.requests.count == firstCount)
        #expect(secondTransport.requests.count > 0)
    }

}
