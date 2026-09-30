import CommunityCore
import CourseFeature
import PaperFeature
import MineFeature
import GalleryFeature
import CommunityUI
import StorageCore
import CommunityTransport
import TransportCore
import Combine
import ScheduleDomain
import SwiftUI
import Observation

extension CommunityDestinations {
    static func appDestinations(dependencies: AppCommunityDependencies) -> CommunityDestinations {
        CommunityDestinations(
            settingsEntries: SettingsRoute.allCases.map {
                CommunitySettingsEntry(id: $0.rawValue, title: $0.title, systemImage: $0.systemImage)
            },
            settings: { request in
                AnyView(SettingsRootView(initialRoute: SettingsRoute(rawValue: request.entry.id), studentID: request.studentID, onLogout: request.onLogout))
            },
            suggestion: { AnyView(DeveloperSuggestionPage()) },
            profile: { AnyView(UserProfileRootView(dependencies: dependencies.mine, userID: $0)) },
            poster: { AnyView(GalleryPosterDetailView(dependencies: dependencies.gallery, poster: $0, onDeleted: $1)) },
            papers: { requestedID, onShowFeed in AnyView(PaperRootView(dependencies: dependencies.paper, requestedPaperID: requestedID, onShowFeed: onShowFeed)) }
        )
    }
}

extension GalleryService {
    init(storage: LoginStorage = .shared, httpClient: HTTPClient = .community) {
        self.init(session: .appSession(storage: storage, httpClient: httpClient), preferences: { AppCommunityDependencies.preferenceSnapshot })
    }
}

extension CourseService {
    init(storage: LoginStorage = .shared, httpClient: HTTPClient = .community) {
        self.init(session: .appSession(storage: storage, httpClient: httpClient))
    }
}

extension PaperService {
    init(storage: LoginStorage = .shared, httpClient: HTTPClient = .community) {
        self.init(session: .appSession(storage: storage, httpClient: httpClient))
    }
}

extension MineService {
    init(storage: LoginStorage = .shared, httpClient: HTTPClient = .community) {
        self.init(session: .appSession(storage: storage, httpClient: httpClient), preferences: { AppCommunityDependencies.preferenceSnapshot })
    }
}


/// 应用生命周期持有社区依赖，设置与学校课程转换为场景快照。
@MainActor
@Observable
final class AppCommunityDependencies {
    let preferences: CommunityPreferences
    let gallery: GalleryDependencies
    let course: CourseDependencies
    let paper: PaperDependencies
    let mine: MineDependencies
    private var subscriptions = Set<AnyCancellable>()

    init(
        settings: AppSettingsStore = .shared,
        session: CommunitySession = .appSession(),
        messages: GalleryMessageReadStore = AppAccountStores.shared.communityMessages,
        drafts: ComposerDraftStore = AppAccountStores.shared.composerDrafts,
        loadCourseCredits: @escaping @MainActor () async -> [CommunityCourseCredit] = AppCommunityDependencies.loadSchoolCourseCredits
    ) {
        let preferences = CommunityPreferences(
            snapshot: Self.snapshot(for: settings),
            saveMakeupFilter: { settings.setHidesCourseHistoryMakeupOutliers($0) }
        )
        self.preferences = preferences
        let galleryService = GalleryService(session: session, preferences: { preferences.snapshot })
        gallery = GalleryDependencies(
            session: session, feed: galleryService, messageService: galleryService, posterDetail: galleryService,
            reporting: galleryService, composer: galleryService, images: galleryService, preferences: preferences,
            messages: messages, drafts: drafts
        )
        let courseService = CourseService(session: session)
        course = CourseDependencies(list: courseService, detail: courseService, preferences: preferences, loadCourseCredits: loadCourseCredits)
        let paperService = PaperService(session: session)
        paper = PaperDependencies(list: paperService, detail: paperService, composer: paperService)
        let mineService = MineService(session: session, preferences: { preferences.snapshot })
        mine = MineDependencies(
            overview: mineService, profile: mineService,
            deletePoster: { try await galleryService.deletePoster(id: $0) },
            isRunningUITest: AppFileDirectories.isRunningUITest
        )
        settings.$snapshot.combineLatest(settings.$hidesCourseHistoryMakeupOutliers)
            .sink { snapshot, hideMakeup in
                preferences.apply(CommunityPreferenceSnapshot(
                    hideBots: snapshot.galleryHideBotPosterInSearch,
                    hiddenUserIDs: snapshot.galleryHiddenUserIDs,
                    hideAnonymous: snapshot.galleryHideAnonymousContent,
                    useWebView: snapshot.galleryUseWebView,
                    hideMakeupOutliers: hideMakeup
                ))
            }
            .store(in: &subscriptions)
    }

    private static func loadSchoolCourseCredits() async -> [CommunityCourseCredit] {
        let session = AppFileDirectories.currentSession
        let result = await ScheduleCacheStore.loadResultAsync(for: session)
        guard session == AppFileDirectories.currentSession, let cache = result.cacheIfReadable else { return [] }
        let records = cache.courses + (cache.cachedCoursesByTerm[cache.currentTerm] ?? [])
            + cache.termSchedulesByTerm.values.sorted { $0.updatedAt > $1.updatedAt }.flatMap(\.courses)
        return records.map { CommunityCourseCredit(number: $0.number, name: $0.name, credit: $0.credit) }
    }

    static var preferenceSnapshot: CommunityPreferenceSnapshot { snapshot(for: .shared) }

    private static func snapshot(for settings: AppSettingsStore) -> CommunityPreferenceSnapshot {
        CommunityPreferenceSnapshot(
            hideBots: settings.galleryHideBotPosterInSearch,
            hiddenUserIDs: settings.galleryHiddenUserIDs,
            hideAnonymous: settings.galleryHideAnonymousContent,
            useWebView: settings.galleryUseWebView,
            hideMakeupOutliers: settings.hidesCourseHistoryMakeupOutliers
        )
    }
}
