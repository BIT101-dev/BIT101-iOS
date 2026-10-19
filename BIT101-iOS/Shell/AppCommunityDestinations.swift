import MediaKit
import ScorePorts
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

    init(dependencies: AppCommunityDependencies, schedule: ScheduleViewModel, scheduleCloudSync: ScheduleCloudSyncPresentation, media: MediaEnvironment, localData: AppLocalDataService, school: NetworkDiagnosisSchool, transcript: any TrustedTranscriptServicing, updates: AppUpdatePromptCoordinator, prompts: AppPromptCoordinator) {
        self.media = media
        profiles = Self.profiles(dependencies: dependencies, media: media)
        posters = Self.posters(dependencies: dependencies, media: media)
        papers = CommunityPaperDestination { requestedID, onShowFeed in
            AnyView(PaperRootView(dependencies: dependencies.paper, media: media,
                                 requestedPaperID: requestedID, onShowFeed: onShowFeed))
        }
        let selectedSettings = SettingsDependencies(
            settings: dependencies.settingsStore, schedule: schedule,
            scheduleCloudSync: scheduleCloudSync,
            suggestion: dependencies.suggestion, media: media,
            localData: localData, updates: updates, prompts: prompts,
            account: SettingsAccountDependencies(
                service: SettingsNetworkService(session: dependencies.session, checkLogin: dependencies.checkLogin),
                credentials: { dependencies.session.currentCredentials },
                updateSchoolCredentials: dependencies.updateSchoolCredentials
            ),
            networkDiagnosis: NetworkDiagnosisDependencies(
                identity: { .init(community: dependencies.session.currentCredentials.identity, school: school.identity()) },
                path: NetworkConnectionDescription(networkPath: dependencies.networkPath),
                httpClient: dependencies.session.httpClient,
                gallery: GalleryService(session: dependencies.session, preferences: { dependencies.preferences.snapshot }),
                paper: PaperService(session: dependencies.session), school: school, transcript: transcript
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
    init(storage: LoginStorage = AppAccountSession.storage, httpClient: HTTPClient? = nil,
         preferences: @escaping () -> CommunityPreferenceSnapshot = { AppCommunityDependencies.preferenceSnapshot }) {
        self.init(session: .appSession(storage: storage, httpClient: httpClient), preferences: preferences)
    }
}

extension CourseService {
    init(storage: LoginStorage = AppAccountSession.storage, httpClient: HTTPClient? = nil) {
        self.init(session: .appSession(storage: storage, httpClient: httpClient))
    }
}

extension PaperService {
    init(storage: LoginStorage = AppAccountSession.storage, httpClient: HTTPClient? = nil) {
        self.init(session: .appSession(storage: storage, httpClient: httpClient))
    }
}

extension MineService {
    init(storage: LoginStorage = AppAccountSession.storage, httpClient: HTTPClient? = nil,
         preferences: @escaping () -> CommunityPreferenceSnapshot = { AppCommunityDependencies.preferenceSnapshot }) {
        self.init(session: .appSession(storage: storage, httpClient: httpClient), preferences: preferences)
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
    let updateSchoolCredentials: () async throws -> Void
    let networkPath: NetworkPathState
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
        networkPath: NetworkPathState = AppNetworkPath.state,
        updateSchoolCredentials: @escaping () async throws -> Void = { throw LoginServiceError.schoolCredentialsRequired }
    ) {
        self.settingsStore = settings
        self.session = session
        self.checkLogin = checkLogin
        self.updateSchoolCredentials = updateSchoolCredentials
        self.networkPath = networkPath
        let preferences = CommunityPreferences(
            snapshot: Self.snapshot(for: settings),
            saveMakeupFilter: { settings.setHidesCourseHistoryMakeupOutliers($0) }
        )
        self.preferences = preferences
        suggestion = DeveloperSuggestionDependencies(drafts: drafts, submit: submitSuggestion, captureSubmissionOwner: {
            let owner = session.currentCredentials
            return { session.currentCredentials == owner }
        })
        let galleryService = GalleryService(session: session, preferences: { preferences.snapshot })
        gallery = GalleryDependencies(
            webCredentials: .init(cookie: { session.fakeCookie }, changes: session.credentialsChanges.map { _ in () }.eraseToAnyPublisher()),
            currentIdentity: { session.currentCredentials.identity },
            feed: galleryService, messageService: galleryService, posterDetail: galleryService, subscriptions: galleryService,
            reporting: galleryService, composer: galleryService, images: galleryService, preferences: preferences,
            messages: messages, drafts: drafts, networkPath: networkPath
        )
        let courseService = CourseService(session: session)
        course = CourseDependencies(list: courseService, detail: courseService, preferences: preferences, loadCourseCredits: loadCourseCredits)
        let paperService = PaperService(session: session)
        paper = PaperDependencies(list: paperService, detail: paperService, composer: paperService, networkPath: networkPath)
        let mineService = MineService(session: session, preferences: { preferences.snapshot })
        mine = MineDependencies(
            overview: mineService, profile: mineService,
            deletePoster: { try await galleryService.deletePoster(id: $0) }
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
            submitSuggestion: { try await FeedbackSubmissionClient.submit($0) }, loadCourseCredits: loadSchoolCourseCredits,
            updateSchoolCredentials: { try await AppAccountSession.storage.updateSchoolCredentials() }
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
@MainActor
enum AppLocalDataComposition {
#if BIT101_AUTOMATED_TESTING
    static let websiteDataStore = WKWebsiteDataStore.nonPersistent()
#else
    static let websiteDataStore = WKWebsiteDataStore.default()
#endif

    static func appService(settings: AppSettingsStore, media: MediaEnvironment) -> AppLocalDataService {
        let defaults = AppFileDirectories.defaults
        let domain = AppFileDirectories.defaultsDomain
        let webData = websiteDataStore
        return AppLocalDataService(files: AppFileDirectories.files, actions: AppLocalDataActions(
            hasPendingRecovery: { ReleaseNetworkSmokeReportStore.hasPendingCommunityWrites() },
            clearLogin: { AppAccountSession.storage.clearAllLocalData() },
            suspendStorageOperations: AppAccountStores.suspendStorageOperations,
            resumeStorageOperations: AppAccountStores.resumeStorageOperations,
            clearSchedule: { await ScheduleCacheStore.clear() },
            clearSharedSnapshot: { await ScheduleWidgetExporter.clearSharedSnapshot() },
            clearReports: { ReleaseNetworkSmokeReportStore.clearLocalArtifacts() },
            clearDiagnostics: { await NetworkDiagnosticStore.shared.clear() },
            clearPreferences: {
                AppAccountSession.storage.preservingLoginMarkers { defaults.removePersistentDomain(forName: domain) }
            },
            clearURLCache: { URLSessionTransport.clearSharedCache() },
            clearWebData: {
                await withCheckedContinuation { continuation in
                    webData.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                        continuation.resume()
                    }
                }
            },
            clearMedia: { await media.clearCaches() },
            resetSettings: { settings.resetToDefaults() }
        ), cacheDirectories: media.cacheDirectories)
    }
}
