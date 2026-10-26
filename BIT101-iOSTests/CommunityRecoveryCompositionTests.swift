@testable import BIT101_iOS
@testable import GalleryFeature
@testable import PaperFeature
@testable import CourseFeature
@testable import TransportCore
import ClientCore
import StorageCore
import Foundation
import Combine
import CommunityCore
import CommunityPersistence
import CommunityTransport
import CommunityUI
import MediaKit
import SwiftUI
import Testing
import UIKit
@testable import MineFeature

@MainActor
@Suite(.serialized)
struct CommunityRecoveryCompositionTests {
    private final class MineReads: MineOverviewServicing, UserProfileServicing {
        var offline = true, suspended = false
        var requests = 0, cancellations = 0, successes = 0
        func fetchMyInfo() async throws -> MineUserInfo {
            requests += 1
            if offline { throw URLError(.notConnectedToInternet) }
            if suspended {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancellations += 1; throw error }
            }
            successes += 1
            return .init(user: .placeholder(id: 1, nickname: "恢复后的用户"), followingNum: 0, followerNum: 0,
                following: false, follower: false, own: true)
        }
        func fetchUserInfo(id: Int) async throws -> MineUserInfo { try await fetchMyInfo() }
        func fetchMyPosters(page: Int) async throws -> [CommunityPoster] { [] }
        func fetchUserPosters(userID: Int, page: Int) async throws -> [CommunityPoster] { [] }
        func fetchFollowers(page: Int) async throws -> [CommunityUser] { [] }
        func fetchFollowings(page: Int) async throws -> [CommunityUser] { [] }
        func followUser(id: Int) async throws -> MineFollowResult { throw URLError(.unsupportedURL) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func mineRecoveryRestartsAfterItsConnectedRequestIsCancelled(profile: Bool) async throws {
        let service = MineReads(), path = NetworkPathState(snapshot: .init(status: .disconnected))
        let dependencies = MineDependencies(overview: service, profile: service, deletePoster: { _ in }, networkPath: path)
        let posters = CommunityPosterDestination { _ in AnyView(Text("帖子")) }
        let settings = CommunitySettingsDestinations(settingsEntries: [], settings: { _ in AnyView(Text("设置")) },
            suggestion: { AnyView(Text("反馈")) })
        let view: AnyView = profile
            ? AnyView(UserProfileRootView(dependencies: dependencies, media: media(), posters: posters, userID: 1))
            : AnyView(MineRootView(dependencies: dependencies, media: media(), posters: posters, settings: settings,
                fallbackStudentID: "fixture", onLogout: {}))
        let (window, _) = try window(NavigationStack { view })
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForTestEvent { service.requests == 1 }
        try await render()
        service.offline = false; service.suspended = true
        path.update(snapshot: .init(status: .connected))
        try await waitForTestEvent { service.requests == 2 }
        path.update(snapshot: .init(status: .disconnected))
        try await waitForTestEvent { service.cancellations == 1 }
        service.suspended = false
        path.update(snapshot: .init(status: .connected))
        try await waitForTestEvent { service.successes == 1 }
        #expect(service.requests == 3)
    }
    private final class CourseReads: CourseListServicing {
        var queries: [String] = []
        var offline = true
        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            queries.append(search)
            if offline { throw URLError(.notConnectedToInternet) }
            return []
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func courseSearchStaysAvailableThroughFailureAndConnectedRecovery() async throws {
        let path = NetworkPathState(snapshot: .init(status: .disconnected)), reads = CourseReads()
        let preferences = CommunityPreferences(snapshot: .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
            useWebView: false, hideMakeupOutliers: false), saveMakeupFilter: { _ in })
        let dependencies = CourseDependencies(list: reads, detail: CourseService(session: session()), preferences: preferences,
            networkPath: path, loadCourseCredits: { [] })
        let model = dependencies.makeListViewModel()
        model.searchText = "旧查询"
        let (window, controller) = try window(NavigationStack {
            CoursePageContent(viewModel: model, dependencies: dependencies, media: media(),
                profiles: CommunityProfileDestination(profile: { _ in AnyView(Text("个人主页")) }))
        })
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForTestEvent { if case .failed = model.state.status { true } else { false } }
        try await render()
        func fields(_ view: UIView) -> [UITextField] {
            var result = (view as? UITextField).map { [$0] } ?? []
            for child in view.subviews { result.append(contentsOf: fields(child)) }
            return result
        }
        #expect(fields(controller.view).contains { $0.text == "旧查询" })
        path.update(snapshot: .init(status: .requiresConnection))
        try await render()
        #expect(reads.queries == ["旧查询"])
        reads.offline = false
        path.update(snapshot: .init(status: .connected))
        try await waitForTestEvent { model.state.status == .loaded }
        #expect(reads.queries == ["旧查询", "旧查询"])
        model.searchText = "新查询"
        await model.submitSearch()
        #expect(reads.queries.last == "新查询")
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedRefreshRetainsItsRecoveryAfterContentWasLoaded() async {
        let reads = CourseReads(); reads.offline = false
        let model = CourseListViewModel(service: reads)
        await model.bootstrapIfNeeded()
        reads.offline = true
        await model.refresh()
        #expect(model.state.status == .loaded && model.alert != nil)
        reads.offline = false
        await model.retryAfterConnectivityRecovery()
        #expect(reads.queries.count == 3 && model.state.status == .loaded && model.alert == nil)
    }

    private final class PaperReads: PaperListServicing {
        var calls = 0, offline = true
        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
            calls += 1
            if offline { throw URLError(.notConnectedToInternet) }
            return []
        }
        func fetchPaper(id: Int) async throws -> PaperDetail { throw URLError(.unsupportedURL) }
        func fetchPreviewMetadata(id: Int) async throws -> PaperPreviewMetadata { throw URLError(.unsupportedURL) }
    }

    private final class Messages: GalleryMessageServicing {
        var failSummary = false, holdSummary = false, isSuspended = false, cancellations = 0
        var cursors: [Int?] = []
        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts {
            if failSummary { throw URLError(.notConnectedToInternet) }
            if holdSummary {
                isSuspended = true
                defer { isSuspended = false }
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancellations += 1; throw error }
            }
            return .init()
        }
        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
            cursors.append(lastID)
            return []
        }
    }

    private final class UnusedTransport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.unsupportedURL) }
    }

    private func session() -> CommunitySession {
        CommunitySession(httpClient: HTTPClient(transport: UnusedTransport(), observer: nil),
            baseURL: AppURL.required("https://example.invalid"), credentials: {
                .init(identity: .init(accountIdentifier: "composition-recovery"), cookie: "fixture")
            }, refresh: { _ in })
    }

    private func media() -> MediaEnvironment {
        let files = PreferenceMemoryFiles(), client = HTTPClient(transport: UnusedTransport(), observer: nil)
        return AppMedia.makeEnvironment(files: files, previewStorage: MediaPreviewStorage(files: files),
            imageHTTPClient: client, avatarHTTPClient: client)
    }

    private func window<V: View>(_ view: V) throws -> (UIWindow, UIHostingController<AnyView>) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), controller = UIHostingController(rootView: AnyView(view.environment(\.scenePhase, .active)))
        window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded()
        return (window, controller)
    }

    private func render() async throws {
        var rendered = false
        DispatchQueue.main.async {
            DispatchQueue.main.async { rendered = true }
        }
        try await waitForTestEvent { rendered }
    }

    @Test(.timeLimit(.minutes(1)))
    func paperRecoveryWaitsForTheConnectedTransitionAfterConnectionIsRequired() async throws {
        let path = NetworkPathState(snapshot: .init(status: .disconnected)), service = PaperReads()
        let paperSession = session()
        let details = PaperService(session: paperSession)
        let dependencies = PaperDependencies(list: service, detail: details, composer: details, drafts: ComposerDraftStore(files: PreferenceMemoryFiles(), applicationSupport: URL(fileURLWithPath: "/paper-draft"), session: { AppStorageSession(accountIdentifier: "composition-recovery") }, prepareImageData: { $0 }), networkPath: path, currentIdentity: { paperSession.currentCredentials.identity })
        let (window, _) = try window(PaperRootView(dependencies: dependencies, media: media()))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForTestEvent { service.calls == 1 }
        path.update(snapshot: .init(status: .requiresConnection))
        try await render()
        #expect(service.calls == 1)
        service.offline = false
        path.update(snapshot: .init(status: .connected))
        try await waitForTestEvent { service.calls == 2 }
        #expect(service.calls == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func messageRecoveryCancellationKeepsItsWindowRetryableAfterOwnerExit(changeType: Bool) async throws {
        let domain = "BIT101Tests.message-owner-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let files = PreferenceMemoryFiles(), account = AppStorageSession(accountIdentifier: domain)
        let readStore = GalleryMessageReadStore(files: files, storageRoot: URL(fileURLWithPath: "/message-owner-recovery"),
            defaults: defaults, session: { account })
        let service = Messages(), model = GalleryMessageViewModel(service: service, readStore: readStore)
        await model.refreshSelectedType()
        let path = NetworkPathState(snapshot: .init(status: .disconnected))
        let preferences = CommunityPreferences(snapshot: .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
            useWebView: false, hideMakeupOutliers: false), saveMakeupFilter: { _ in })
        let gallery = GalleryService(session: session(), preferences: { preferences.snapshot })
        let dependencies = GalleryDependencies(webCredentials: .init(cookie: { "fixture" }, changes: Empty().eraseToAnyPublisher()),
            currentIdentity: { .init(accountIdentifier: domain) }, feed: gallery, messageService: service, posterDetail: gallery,
            subscriptions: gallery, reporting: gallery, composer: gallery, images: gallery, preferences: preferences, messages: readStore,
            drafts: ComposerDraftStore(files: files, applicationSupport: URL(fileURLWithPath: "/message-owner-recovery"),
                session: { account }, prepareImageData: ComposerDraftImageCompressor.compress), networkPath: path)
        let view = GalleryMessagesView(papers: .init(papers: { _, _ in AnyView(Text("papers")) }, detail: { _ in AnyView(Text("paper")) }),
            courses: .init { _ in AnyView(Text("course")) }, viewModel: model)
            .environment(dependencies).environment(media()).environment(CommunityProfileDestination { _ in AnyView(Text("profile")) })
        let (window, controller) = try window(NavigationStack { view })
        defer { window.isHidden = true; window.rootViewController = nil; model.pendingOperations.cancel() }
        try await render()
        service.failSummary = true
        await model.refreshSelectedType(); model.alert = nil
        service.failSummary = false; service.holdSummary = true
        path.update(snapshot: .init(status: .connected))
        try await waitForTestEvent { service.isSuspended }
        if changeType { model.selectedType = .like }
        else { controller.rootView = AnyView(Text("closed")) }
        try await waitForTestEvent { service.cancellations > 0 }
        service.holdSummary = false
        controller.rootView = AnyView(Text("closed"))
        try await render()
        model.selectedType = .comment
        let previous = service.cursors.count
        await model.retrySelectedTypeIfNeeded()
        #expect(service.cursors.count > previous && model.state(for: .comment).status == .loaded)
        #expect(model.alert == nil && !service.cursors.contains(nil))
    }
}
