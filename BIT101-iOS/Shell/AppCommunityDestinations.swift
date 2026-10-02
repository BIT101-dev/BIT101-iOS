import MediaKit
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
import ScheduleFeature
import SwiftUI
import Observation
import WebKit

/// App-owned cross-feature composition; each module receives its consumed capabilities.
@MainActor
@Observable
final class AppCommunityDestinations {
    let media: MediaEnvironment
    let profiles: CommunityProfileDestination
    let posters: CommunityPosterDestination
    let papers: CommunityPaperDestination
    let settings: CommunitySettingsDestinations
    let settingsDependencies: SettingsDependencies

    init(dependencies: AppCommunityDependencies, schedule: ScheduleViewModel, media: MediaEnvironment, localData: AppLocalDataService) {
        self.media = media
        profiles = Self.profiles(dependencies: dependencies, media: media)
        posters = Self.posters(dependencies: dependencies, media: media)
        papers = CommunityPaperDestination { requestedID, onShowFeed in
            AnyView(PaperRootView(dependencies: dependencies.paper, media: media,
                                 requestedPaperID: requestedID, onShowFeed: onShowFeed))
        }
        let selectedSettings = SettingsDependencies(
            settings: dependencies.settingsStore, schedule: schedule,
            suggestion: dependencies.suggestion, media: media,
            localData: localData,
            account: SettingsAccountDependencies(
                service: SettingsNetworkService(session: dependencies.session, checkLogin: dependencies.checkLogin),
                credentials: { dependencies.session.currentCredentials }
            )
        )
        settingsDependencies = selectedSettings
        settings = CommunitySettingsDestinations(
            settingsEntries: SettingsRoute.allCases.map {
                CommunitySettingsEntry(id: $0.rawValue, title: $0.title, systemImage: $0.systemImage)
            },
            settings: { request in
                AnyView(SettingsRootView(initialRoute: SettingsRoute(rawValue: request.entry.id),
                    studentID: request.studentID, onLogout: request.onLogout, dependencies: selectedSettings))
            },
            suggestion: { AnyView(DeveloperSuggestionPage(dependencies: dependencies.suggestion)) }
        )
    }

    private static func profiles(dependencies: AppCommunityDependencies, media: MediaEnvironment) -> CommunityProfileDestination {
        CommunityProfileDestination { userID in
            AnyView(UserProfileRootView(dependencies: dependencies.mine, media: media,
                posters: Self.posters(dependencies: dependencies, media: media), userID: userID))
        }
    }

    private static func posters(dependencies: AppCommunityDependencies, media: MediaEnvironment) -> CommunityPosterDestination {
        CommunityPosterDestination { poster, onDeleted in
            AnyView(GalleryPosterDetailView(dependencies: dependencies.gallery, media: media,
                profiles: Self.profiles(dependencies: dependencies, media: media), poster: poster, onDeleted: onDeleted))
        }
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
    let settingsStore: AppSettingsStore
    let session: CommunitySession
    let checkLogin: () async throws -> Bool
    let gallery: GalleryDependencies
    let course: CourseDependencies
    let paper: PaperDependencies
    let mine: MineDependencies
    let suggestion: DeveloperSuggestionDependencies
    private var subscriptions = Set<AnyCancellable>()

    init(
        settings: AppSettingsStore,
        session: CommunitySession,
        checkLogin: @escaping () async throws -> Bool,
        messages: any GalleryMessageReadStoring,
        drafts: any GalleryComposerDraftStoring & DeveloperSuggestionDraftStoring,
        submitSuggestion: @escaping (DeveloperSuggestionPayload) async throws -> Void,
        loadCourseCredits: @escaping @MainActor () async -> [CommunityCourseCredit],
        networkPath: NetworkPathState = AppNetworkPath.state
    ) {
        self.settingsStore = settings
        self.session = session
        self.checkLogin = checkLogin
        let preferences = CommunityPreferences(
            snapshot: Self.snapshot(for: settings),
            saveMakeupFilter: { settings.setHidesCourseHistoryMakeupOutliers($0) }
        )
        self.preferences = preferences
        suggestion = DeveloperSuggestionDependencies(drafts: drafts, submit: submitSuggestion)
        let galleryService = GalleryService(session: session, preferences: { preferences.snapshot })
        gallery = GalleryDependencies(
            session: session, feed: galleryService, messageService: galleryService, posterDetail: galleryService,
            reporting: galleryService, composer: galleryService, images: galleryService, preferences: preferences,
            messages: messages, drafts: drafts, networkPath: networkPath
        )
        let courseService = CourseService(session: session)
        course = CourseDependencies(list: courseService, detail: courseService, preferences: preferences, loadCourseCredits: loadCourseCredits)
        let paperService = PaperService(session: session)
        paper = PaperDependencies(list: paperService, detail: paperService, composer: paperService, networkPath: networkPath)
        let mineService = MineService(session: session, preferences: { preferences.snapshot })
#if BIT101_UI_TESTING
        let offlineUITest = AppFileDirectories.isRunningUITest
            && AppUITestBootstrap.environment["BIT101_UI_TEST_CONTENT"] != "1"
#else
        let offlineUITest = false
#endif
        mine = MineDependencies(
            overview: mineService, profile: mineService,
            deletePoster: { try await galleryService.deletePoster(id: $0) },
            isRunningUITest: offlineUITest
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

    static func app(settings: AppSettingsStore, stores: AppAccountStores) -> AppCommunityDependencies {
        let login = LoginService.appRuntimeService()
        return AppCommunityDependencies(
            settings: settings, session: .appSession(), checkLogin: { try await login.checkLogin() != nil },
            messages: stores.communityMessages, drafts: stores.composerDrafts,
            submitSuggestion: { try await FeedbackSubmissionClient.submit($0) }, loadCourseCredits: loadSchoolCourseCredits
        )
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

/// 生产系统资源在 App 组装位置绑定，操作服务持有显式能力。
extension AppLocalDataService {
    static func appService(settings: AppSettingsStore, media: MediaEnvironment) -> AppLocalDataService {
#if BIT101_UI_TESTING
        return AppLocalDataService(files: AppFileDirectories.files, actions: AppLocalDataActions(
            clearLogin: { LoginStorage.resetUITestCredentials(); return true },
            clearSchedule: { await ScheduleCacheStore.clear() },
            clearSharedSnapshot: { true },
            clearReports: { true },
            clearPreferences: { AppFileDirectories.defaults.removePersistentDomain(forName: AppFileDirectories.defaultsDomain) },
            clearURLCache: {}, clearWebData: {},
            clearMedia: { await media.clearAvatars() }, resetSettings: { settings.resetToDefaults() }
        ))
#else
        let defaults = AppFileDirectories.defaults
        let domain = AppFileDirectories.defaultsDomain
        let webData = WKWebsiteDataStore.default()
        return AppLocalDataService(files: AppFileDirectories.files, actions: AppLocalDataActions(
            clearLogin: { LoginStorage.shared.clearAllLocalData() },
            clearSchedule: { await ScheduleCacheStore.clear() },
            clearSharedSnapshot: { await ScheduleWidgetExporter.clearSharedSnapshot() },
            clearReports: { ReleaseNetworkSmokeReportStore.clearLocalArtifacts() },
            clearPreferences: { defaults.removePersistentDomain(forName: domain) },
            clearURLCache: { URLSessionTransport.clearSharedCache() },
            clearWebData: {
                await withCheckedContinuation { continuation in
                    webData.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                        continuation.resume()
                    }
                }
            },
            clearMedia: { await media.clearAvatars() },
            resetSettings: { settings.resetToDefaults() }
        ))
#endif
    }
}
