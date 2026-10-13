import ScoreDomain
import ScorePorts
import CommunityTransport
import MediaKit
import ScoreInfrastructure
import ScheduleDomain
import CommunityUI
import ScheduleFeature
import ScoreFeature
import StorageCore
import Combine
import Foundation

/// 应用生命周期持有场景依赖，集中处理账号切换和外部日程展示。
@MainActor
final class AppAccountLifecycle: ObservableObject {
    let scheduleViewModel: ScheduleViewModel
    let scoreViewModel: ScoreViewModel
    let transcriptService: any TrustedTranscriptServicing
    let community: AppCommunityDependencies
    let communityDestinations: AppCommunityDestinations
    let settings: AppSettingsStore
    let localData: AppLocalDataService
    let preferenceCloudSync: ExperimentalPreferenceCloudSync
    let scheduleChanges: AnyPublisher<AppStorageSession, Never>
    let isNotificationPermissionDenied: @MainActor () async -> Bool
    private var subscriptions = Set<AnyCancellable>()
    private var externalRefreshTask: Task<Void, Never>?
    private var scheduleCloudRefreshTask: Task<Void, Never>?
    private let refreshScheduleCloud: @MainActor () async -> Void
    private let externalDisplays: any AppExternalDisplayCoordinating
    let prompts: AppPromptCoordinator
    let updates: AppUpdatePromptCoordinator
    private let currentIdentity: () -> CommunitySessionIdentity
    var accountIdentity: CommunitySessionIdentity { currentIdentity() }
    let currentSession: @MainActor () -> AppStorageSession

    func scheduleNotificationPromptAccount() async -> CommunitySessionIdentity? {
        await Self.scheduleNotificationPromptAccount(currentIdentity: { self.accountIdentity }, isDenied: isNotificationPermissionDenied)
    }

    static func scheduleNotificationPromptAccount(currentIdentity: @MainActor () -> CommunitySessionIdentity,
        isDenied: @MainActor () async -> Bool) async -> CommunitySessionIdentity? {
        let owner = currentIdentity()
        guard await isDenied(), !Task.isCancelled, owner == currentIdentity() else { return nil }
        return owner
    }

    init(
        scheduleViewModel: ScheduleViewModel,
        scoreViewModel: ScoreViewModel? = nil,
        community: AppCommunityDependencies,
        scoreService: any ScoreListServicing,
        transcriptService: any TrustedTranscriptServicing,
        diagnosisSchool: NetworkDiagnosisSchool,
        settings: AppSettingsStore,
        stores: AppAccountStores,
        preferenceCloudSync: ExperimentalPreferenceCloudSync,
        accountChanges: AnyPublisher<CommunitySessionIdentity, Never>,
        currentIdentity: @escaping () -> CommunitySessionIdentity,
        scheduleChanges: AnyPublisher<AppStorageSession, Never>,
        scheduleCloudSync: ScheduleCloudSyncPresentation,
        refreshScheduleCloud: @escaping @MainActor () async -> Void,
        isNotificationPermissionDenied: @escaping @MainActor () async -> Bool,
        loadScheduleCourses: @escaping @MainActor (AppStorageSession) async -> [String: [ScoreCourseSummary]],
        media: MediaEnvironment,
        localData: AppLocalDataService,
        externalDisplays: any AppExternalDisplayCoordinating,
        prompts: AppPromptCoordinator = .shared
    ) {
        self.scheduleViewModel = scheduleViewModel
        if let scoreViewModel {
            self.scoreViewModel = scoreViewModel
        } else {
            self.scoreViewModel = ScoreViewModel(service: scoreService, stores: stores,
                scheduleCoursesChanges: scheduleChanges, loadScheduleCourses: loadScheduleCourses)
        }
        self.community = community
        self.transcriptService = transcriptService
        let updates = AppUpdatePromptCoordinator(settings: settings)
        self.updates = updates
        self.communityDestinations = AppCommunityDestinations(dependencies: community, schedule: scheduleViewModel, scheduleCloudSync: scheduleCloudSync, media: media, localData: localData, school: diagnosisSchool, transcript: transcriptService, updates: updates, prompts: prompts)
        self.settings = settings
        self.localData = localData
        self.preferenceCloudSync = preferenceCloudSync
        self.refreshScheduleCloud = refreshScheduleCloud
        self.scheduleChanges = scheduleChanges
        self.isNotificationPermissionDenied = isNotificationPermissionDenied
        self.externalDisplays = externalDisplays
        self.prompts = prompts
        self.currentIdentity = currentIdentity
        self.currentSession = stores.currentSession
        accountChanges
            .sink { [weak self] identity in
                guard identity == currentIdentity() else { return }
                self?.accountDidChange()
            }
            .store(in: &subscriptions)
        scheduleChanges
            .sink { [weak self] session in
                guard let self, session == self.currentSession() else { return }
                self.refreshExternalDisplays(trigger: "schedule_cache_changed", syncWidgetSnapshot: true)
            }
            .store(in: &subscriptions)
    }

    deinit { externalRefreshTask?.cancel(); scheduleCloudRefreshTask?.cancel() }

    func start() {
#if BIT101_UI_TESTING
        guard AppUITestBootstrap.usesProductionComposition || !AppFileDirectories.isRunningUITest else { return }
#endif
        externalDisplays.activate()
        preferenceCloudSync.refreshFromCloudIfNeeded()
        refreshScheduleFromCloud()
        refreshExternalDisplays(trigger: "app_launch_task", syncWidgetSnapshot: true)
    }

    func accountDidChange() {
        externalRefreshTask?.cancel()
        prompts.accountDidChange(to: currentIdentity())
        externalDisplays.resetAccountPresentation()
        settings.reloadForCurrentAccount()
        preferenceCloudSync.reloadForCurrentAccount()
        scheduleViewModel.resetForCurrentAccount()
        scoreViewModel.resetForCurrentAccount()
        refreshScheduleFromCloud()
        refreshExternalDisplays(trigger: "login_storage_changed", syncWidgetSnapshot: true)
    }

    func sceneBecameActive() {
        preferenceCloudSync.refreshFromCloudIfNeeded()
        refreshScheduleFromCloud()
        refreshExternalDisplays(trigger: "scene_active", syncWidgetSnapshot: true)
    }

    private func refreshScheduleFromCloud() {
#if BIT101_UI_TESTING
        guard AppUITestBootstrap.usesProductionComposition || !AppFileDirectories.isRunningUITest else { return }
#endif
        scheduleCloudRefreshTask?.cancel()
        let session = currentSession()
        let identity = currentIdentity()
        scheduleCloudRefreshTask = Task { [refreshScheduleCloud, currentSession, currentIdentity] in
            guard !Task.isCancelled, session == currentSession(), identity == currentIdentity() else { return }
            await refreshScheduleCloud()
        }
    }

    private func refreshExternalDisplays(trigger: String, syncWidgetSnapshot: Bool) {
#if BIT101_UI_TESTING
        guard AppUITestBootstrap.usesProductionComposition || !AppFileDirectories.isRunningUITest else { return }
#endif
        externalRefreshTask?.cancel()
        let session = currentSession()
        externalRefreshTask = Task { [externalDisplays] in
            await externalDisplays.refresh(trigger: trigger, syncWidgetSnapshot: syncWidgetSnapshot, session: session)
        }
    }
}
