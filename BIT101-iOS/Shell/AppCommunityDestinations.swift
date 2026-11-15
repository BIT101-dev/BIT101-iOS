import Combine
import CommunityCore
import CommunityTransport
import CommunityUI
import CourseFeature
import GalleryFeature
import MediaKit
import MineFeature
import OSLog
import Observation
import PaperFeature
import ScheduleDomain
import ScheduleFeature
import ScorePorts
import StorageCore
import SwiftUI
import TransportCore
import WebKit

/// App-owned cross-feature composition; each module receives its consumed capabilities.
@MainActor
@Observable
final class AppCommunityDestinations {
    let media: MediaEnvironment
    let profiles: CommunityProfileDestination
    let posters: CommunityPosterDestination
    let papers: CommunityPaperDestination
    let courses: CommunityCourseDestination
    let settings: CommunitySettingsDestinations
    let settingsDependencies: SettingsDependencies

    init(
        dependencies: AppCommunityDependencies, schedule: ScheduleViewModel,
        scheduleCloudSync: ScheduleCloudSyncPresentation, media: MediaEnvironment,
        localData: AppLocalDataService, school: NetworkDiagnosisSchool,
        transcript: any TrustedTranscriptServicing, updates: AppUpdatePromptCoordinator,
        prompts: AppPromptCoordinator
    ) {
        self.media = media
        profiles = Self.profiles(dependencies: dependencies, media: media)
        posters = Self.posters(dependencies: dependencies, media: media)
        papers = CommunityPaperDestination(
            papers: { requestedID, onShowFeed in
                AnyView(
                    PaperRootView(
                        dependencies: dependencies.paper, media: media,
                        requestedPaperID: requestedID, onShowFeed: onShowFeed))
            },
            detail: { id in
                AnyView(
                    PaperDetailDestination(
                        dependencies: dependencies.paper, media: media, paperID: id))
            })
        courses = CommunityCourseDestination { id in
            AnyView(
                CourseEvaluationDestination(
                    dependencies: dependencies.course, media: media,
                    profiles: Self.profiles(dependencies: dependencies, media: media),
                    request: .init(courseID: id)))
        }
        let selectedSettings = SettingsDependencies(
            settings: dependencies.settingsStore, schedule: schedule,
            scheduleCloudSync: scheduleCloudSync,
            suggestion: dependencies.suggestion, media: media,
            localData: localData, updates: updates, prompts: prompts,
            account: SettingsAccountDependencies(
                service: SettingsNetworkService(
                    session: dependencies.session, checkLogin: dependencies.checkLogin),
                credentials: { dependencies.session.currentCredentials }
            ),
            networkDiagnosis: NetworkDiagnosisDependencies(
                identity: {
                    .init(
                        community: dependencies.session.currentCredentials.identity,
                        school: school.identity())
                },
                path: NetworkConnectionDescription(networkPath: dependencies.networkPath),
                httpClient: dependencies.session.httpClient,
                gallery: GalleryService(
                    session: dependencies.session,
                    preferences: { dependencies.preferences.snapshot }),
                paper: PaperService(session: dependencies.session), school: school,
                transcript: transcript
            )
        )
        settingsDependencies = selectedSettings
        settings = CommunitySettingsDestinations(
            settingsEntries: SettingsRoute.allCases.map {
                CommunitySettingsEntry(
                    id: $0.rawValue, title: $0.title, systemImage: $0.systemImage)
            },
            settings: { request in
                AnyView(
                    SettingsRootView(
                        initialRoute: SettingsRoute(rawValue: request.entry.id),
                        studentID: request.studentID, onLogout: request.onLogout,
                        dependencies: selectedSettings))
            },
            suggestion: { AnyView(DeveloperSuggestionPage(dependencies: dependencies.suggestion)) }
        )
    }

    private static func profiles(dependencies: AppCommunityDependencies, media: MediaEnvironment)
        -> CommunityProfileDestination
    {
        CommunityProfileDestination { userID in
            AnyView(
                UserProfileRootView(
                    dependencies: dependencies.mine, media: media,
                    posters: Self.posters(dependencies: dependencies, media: media), userID: userID)
            )
        }
    }

    private static func posters(dependencies: AppCommunityDependencies, media: MediaEnvironment)
        -> CommunityPosterDestination
    {
        CommunityPosterDestination { request in
            AnyView(
                GalleryPosterDetailView(
                    dependencies: dependencies.gallery, media: media,
                    profiles: Self.profiles(dependencies: dependencies, media: media),
                    poster: request.poster,
                    onUpdated: request.onUpdated, onDeleted: request.onDeleted))
        }
    }
}

extension GalleryService {
    init(
        storage: LoginStorage = AppAccountSession.storage, httpClient: HTTPClient? = nil,
        preferences: @escaping () -> CommunityPreferenceSnapshot = {
            AppCommunityDependencies.preferenceSnapshot
        }
    ) {
        self.init(
            session: .appSession(storage: storage, httpClient: httpClient), preferences: preferences
        )
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
    init(
        storage: LoginStorage = AppAccountSession.storage, httpClient: HTTPClient? = nil,
        preferences: @escaping () -> CommunityPreferenceSnapshot = {
            AppCommunityDependencies.preferenceSnapshot
        }
    ) {
        self.init(
            session: .appSession(storage: storage, httpClient: httpClient), preferences: preferences
        )
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
    let networkPath: NetworkPathState
    let gallery: GalleryDependencies
    let course: CourseDependencies
    let paper: PaperDependencies
    let mine: MineDependencies
    let suggestion: DeveloperSuggestionDependencies
    init(
        settings: AppSettingsStore,
        session: CommunitySession,
        checkLogin: @escaping () async throws -> Bool,
        messages: any GalleryMessageReadStoring,
        drafts: any GalleryComposerDraftStoring & DeveloperSuggestionDraftStoring
            & PaperComposerDraftStoring & ComposerPublicationStoring,
        submitSuggestion: @escaping (DeveloperSuggestionPayload) async throws -> Void,
        loadCourseCredits: @escaping @MainActor () async -> [CommunityCourseCredit],
        networkPath: NetworkPathState = AppNetworkPath.state,
        webDataStoreProvider: ((CommunitySessionIdentity) -> WKWebsiteDataStore)? = nil
    ) {
        self.settingsStore = settings
        self.session = session
        self.checkLogin = checkLogin
        self.networkPath = networkPath
        let preferences = CommunityPreferences(
            source: { Self.snapshot(for: settings) },
            saveMakeupFilter: { settings.setHideMakeupOutliers($0) }
        )
        self.preferences = preferences
        suggestion = DeveloperSuggestionDependencies(
            drafts: drafts, submit: submitSuggestion,
            captureSubmissionOwner: {
                let owner = session.currentCredentials
                return { session.currentCredentials == owner }
            })
        let resourceUpdates = CommunityResourceUpdates(currentOwner: {
            session.currentCredentials.identity
        })
        let galleryService = GalleryService(
            session: session, preferences: { preferences.snapshot },
            resourceUpdates: resourceUpdates)
        gallery = GalleryDependencies(
            webCredentials: .init(
                cookie: { session.fakeCookie },
                changes: session.credentialsChanges.map { _ in () }.eraseToAnyPublisher()),
            currentIdentity: { session.currentCredentials.identity },
            feed: galleryService, messageService: galleryService, posterDetail: galleryService,
            subscriptions: galleryService,
            reporting: galleryService, composer: galleryService, images: galleryService,
            preferences: preferences,
            messages: messages, drafts: drafts, networkPath: networkPath,
            webDataStoreProvider: webDataStoreProvider
        )
        let courseService = CourseService(session: session, resourceUpdates: resourceUpdates)
        course = CourseDependencies(
            list: courseService, detail: courseService, preferences: preferences,
            networkPath: networkPath, loadCourseCredits: loadCourseCredits)
        let paperService = PaperService(session: session, resourceUpdates: resourceUpdates)
        paper = PaperDependencies(
            list: paperService, detail: paperService, composer: paperService, drafts: drafts,
            networkPath: networkPath, currentIdentity: { session.currentCredentials.identity },
            hasAuthenticationCredentials: { !session.fakeCookie.isEmpty },
            authenticationChanges: session.credentialsChanges.map { _ in () }.eraseToAnyPublisher())
        let mineService = MineService(
            session: session, preferences: { preferences.snapshot },
            resourceUpdates: resourceUpdates)
        mine = MineDependencies(
            overview: mineService, profile: mineService,
            deletePoster: { try await galleryService.deletePoster(id: $0) },
            networkPath: networkPath
        )
    }

    static func app(settings: AppSettingsStore, stores: AppAccountStores)
        -> AppCommunityDependencies
    {
        let login = LoginService.appRuntimeService()
        return AppCommunityDependencies(
            settings: settings, session: .appSession(),
            checkLogin: { try await login.checkLogin() != nil },
            messages: stores.communityMessages, drafts: stores.composerDrafts,
            submitSuggestion: { try await FeedbackSubmissionClient.submit($0) },
            loadCourseCredits: loadSchoolCourseCredits,
            webDataStoreProvider: AppLocalDataComposition.galleryWebDataStore
        )
    }

    private static func loadSchoolCourseCredits() async -> [CommunityCourseCredit] {
        let session = AppFileDirectories.currentSession
        let result = await ScheduleCacheStore.loadResultAsync(for: session)
        guard session == AppFileDirectories.currentSession, let cache = result.cacheIfReadable
        else { return [] }
        let records =
            cache.courses + (cache.cachedCoursesByTerm[cache.currentTerm] ?? [])
            + cache.termSchedulesByTerm.values.sorted { $0.updatedAt > $1.updatedAt }.flatMap(
                \.courses)
        return records.map {
            CommunityCourseCredit(number: $0.number, name: $0.name, credit: $0.credit)
        }
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

/// WebKit 持久缓存按账号复用，认证会话变化时清理旧存储。
@MainActor
final class AppCommunityWebStorage {
    private static let recordKey = "community.webStorage"
    private static let retiredKey = "community.retiredWebStorage"
    private static let logger = Logger(subsystem: "BIT101", category: "GalleryWebStorage")
    private let defaults: UserDefaults
    private let credentials: () -> CommunityCredentials
    private var observedIdentity: CommunitySessionIdentity
    private var cachedStore: WKWebsiteDataStore?
    private var subscription: AnyCancellable?
    private var cleanupTask: Task<Void, Never>?

    init(
        defaults: UserDefaults, credentials: @escaping () -> CommunityCredentials,
        changes: AnyPublisher<CommunityCredentials, Never>
    ) {
        self.defaults = defaults
        self.credentials = credentials
        observedIdentity = credentials().identity
        subscription = changes.sink { [weak self] value in
            guard let self else { return }
            if value.identity != self.observedIdentity || value.cookie.isEmpty {
                self.retireActiveStore()
            }
            self.observedIdentity = value.identity
        }
        if credentials().cookie.isEmpty { retireActiveStore() }
        scheduleCleanup()
    }

    func dataStore(for identity: CommunitySessionIdentity) -> WKWebsiteDataStore {
        guard identity == credentials().identity, !credentials().cookie.isEmpty else {
            return .nonPersistent()
        }
        if identity != observedIdentity {
            retireActiveStore()
            observedIdentity = identity
        }
        if let cachedStore { return cachedStore }
        let record = defaults.dictionary(forKey: Self.recordKey)
        let identifier: UUID
        if record?["account"] as? String == identity.accountIdentifier,
            let raw = record?["identifier"] as? String, let stored = UUID(uuidString: raw)
        {
            identifier = stored
        } else {
            retireActiveStore()
            identifier = UUID()
            defaults.set(
                ["account": identity.accountIdentifier, "identifier": identifier.uuidString],
                forKey: Self.recordKey)
        }
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        cachedStore = store
        scheduleCleanup()
        return store
    }

    func clear(allStores: Bool = false) async {
        retireActiveStore()
        if allStores {
            let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
            let retired = defaults.stringArray(forKey: Self.retiredKey) ?? []
            defaults.set(
                Array(Set(retired + identifiers.map(\.uuidString))), forKey: Self.retiredKey)
            scheduleCleanup()
        }
        await finishCleanup()
    }

    func finishCleanup() async { await cleanupTask?.value }

    private func retireActiveStore() {
        let record = defaults.dictionary(forKey: Self.recordKey)
        if let identifier = record?["identifier"] as? String {
            var retired = defaults.stringArray(forKey: Self.retiredKey) ?? []
            if !retired.contains(identifier) { retired.append(identifier) }
            defaults.set(retired, forKey: Self.retiredKey)
        }
        cachedStore = nil
        defaults.removeObject(forKey: Self.recordKey)
        scheduleCleanup()
    }

    private func scheduleCleanup() {
        guard !(defaults.stringArray(forKey: Self.retiredKey) ?? []).isEmpty else { return }
        let previous = cleanupTask
        cleanupTask = Task { [weak self] in
            await previous?.value
            await self?.removeRetiredStores()
        }
    }

    private func removeRetiredStores() async {
        for raw in defaults.stringArray(forKey: Self.retiredKey) ?? [] {
            guard let identifier = UUID(uuidString: raw) else { continue }
            var removed = false
            for attempt in 0..<5 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(50)) }
                await Task.yield()
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                    let remaining = (defaults.stringArray(forKey: Self.retiredKey) ?? [])
                        .filter { $0 != raw }
                    defaults.set(remaining, forKey: Self.retiredKey)
                    removed = true
                    break
                } catch {
                    if attempt == 4 {
                        Self.logger.debug(
                            "Web storage cleanup pending: \(error.localizedDescription)")
                    }
                }
            }
            if !removed {
                await clearRetiredData(for: identifier)
            }
        }
    }

    private func clearRetiredData(for identifier: UUID) async {
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        await store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

@MainActor
enum AppLocalDataComposition {
    #if DEBUG
    static let websiteDataStore: WKWebsiteDataStore =
        (AppFileDirectories.isRunningIsolatedUnitTest || AppFileDirectories.isRunningUITest)
        ? .nonPersistent() : .default()
    private static let communityWebStorage: AppCommunityWebStorage? =
        (AppFileDirectories.isRunningIsolatedUnitTest || AppFileDirectories.isRunningUITest)
        ? nil
        : AppCommunityWebStorage(
            defaults: AppFileDirectories.defaults,
            credentials: { AppAccountSession.storage.communityCredentials },
            changes: AppAccountSession.storage.credentialsChanges)
    #else
    static let websiteDataStore = WKWebsiteDataStore.default()
    private static let communityWebStorage = AppCommunityWebStorage(
        defaults: AppFileDirectories.defaults,
        credentials: { AppAccountSession.storage.communityCredentials },
        changes: AppAccountSession.storage.credentialsChanges)
    #endif

    static var galleryWebDataStore: (CommunitySessionIdentity) -> WKWebsiteDataStore {
        #if DEBUG
        guard let storage = communityWebStorage else { return { _ in websiteDataStore } }
        return { storage.dataStore(for: $0) }
        #else
        let storage = communityWebStorage
        return { storage.dataStore(for: $0) }
        #endif
    }

    static func appService(
        settings: AppSettingsStore, media: MediaEnvironment,
        webDataStore: @escaping () -> WKWebsiteDataStore = {
            AppLocalDataComposition.websiteDataStore
        }
    )
        -> AppLocalDataService
    {
        let defaults = AppFileDirectories.defaults
        let domain = AppFileDirectories.defaultsDomain
        return AppLocalDataService(
            files: AppFileDirectories.files,
            actions: AppLocalDataActions(
                hasPendingRecovery: {
                    #if DEBUG
                    ReleaseNetworkSmokeReportStore.hasPendingCommunityWrites()
                    #else
                    false
                    #endif
                },
                clearLogin: { AppAccountSession.storage.clearAllLocalData() },
                suspendStorageOperations: AppAccountStores.suspendStorageOperations,
                resumeStorageOperations: AppAccountStores.resumeStorageOperations,
                clearSchedule: { await ScheduleCacheStore.clear() },
                clearSharedSnapshot: { await ScheduleWidgetExporter.clearSharedSnapshot() },
                clearReports: {
                    #if DEBUG
                    ReleaseNetworkSmokeReportStore.clearLocalArtifacts()
                    #else
                    true
                    #endif
                },
                clearDiagnostics: { await NetworkDiagnosticStore.shared.clear() },
                clearPreferences: {
                    AppAccountSession.storage.preservingLoginMarkers {
                        defaults.removePersistentDomain(forName: domain)
                    }
                },
                clearURLCache: { URLSessionTransport.clearSharedCache() },
                clearWebData: {
                    let webData = webDataStore()
                    #if DEBUG
                    if let communityWebStorage {
                        await communityWebStorage.clear(allStores: true)
                    }
                    #else
                    await communityWebStorage.clear(allStores: true)
                    #endif
                    await withCheckedContinuation { continuation in
                        webData.removeData(
                            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                            modifiedSince: .distantPast
                        ) {
                            continuation.resume()
                        }
                    }
                },
                clearMedia: { await media.clearCaches() },
                resetSettings: { settings.resetToDefaults() }
            ), cacheDirectories: media.cacheDirectories)
    }
}
