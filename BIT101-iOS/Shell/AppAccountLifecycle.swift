import ScoreDomain
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
    let communityDestinations: CommunityDestinations
    let settings: AppSettingsStore
    let preferenceCloudSync: ExperimentalPreferenceCloudSync
    private var subscriptions = Set<AnyCancellable>()
    private var externalRefreshTask: Task<Void, Never>?
    private let externalDisplays: any AppExternalDisplayCoordinating
    private let currentSession: @MainActor () -> AppStorageSession

    init(
        scheduleViewModel: ScheduleViewModel = ScheduleServiceFactory.makeViewModel(),
        scoreViewModel: ScoreViewModel? = nil,
        community: AppCommunityDependencies? = nil,
        transcriptService: any TrustedTranscriptServicing = ScoreService(),
        preferenceCloudSync: ExperimentalPreferenceCloudSync,
        notifications: NotificationCenter = .default,
        externalDisplays: any AppExternalDisplayCoordinating = AppExternalDisplayCoordinator()
    ) {
        let settings = preferenceCloudSync.settings
        let stores = preferenceCloudSync.stores
        self.scheduleViewModel = scheduleViewModel
        if let scoreViewModel {
            self.scoreViewModel = scoreViewModel
        } else {
#if BIT101_UI_TESTING
            self.scoreViewModel = AppFileDirectories.isRunningUITest
                ? ScoreViewModel(service: UITestScoreService(), stores: stores, notificationCenter: notifications)
                : ScoreViewModel(service: ScoreService(), stores: stores, notificationCenter: notifications)
#else
            self.scoreViewModel = ScoreViewModel(service: ScoreService(), stores: stores, notificationCenter: notifications)
#endif
        }
        let community = community ?? AppCommunityDependencies(
            settings: settings, messages: stores.communityMessages, drafts: stores.composerDrafts
        )
        self.community = community
        self.transcriptService = transcriptService
        self.communityDestinations = .appDestinations(dependencies: community)
        self.settings = settings
        self.preferenceCloudSync = preferenceCloudSync
        self.externalDisplays = externalDisplays
        self.currentSession = stores.currentSession
        notifications.publisher(for: .loginStorageDidChange)
            .sink { [weak self] _ in self?.accountDidChange() }
            .store(in: &subscriptions)
        notifications.publisher(for: .scheduleCacheDidChange)
            .sink { [weak self] _ in
                self?.refreshExternalDisplays(trigger: "schedule_cache_changed", syncWidgetSnapshot: true)
            }
            .store(in: &subscriptions)
    }

    deinit { externalRefreshTask?.cancel() }

    func start() {
#if BIT101_UI_TESTING
        guard !AppFileDirectories.isRunningUITest else { return }
#endif
        externalDisplays.activate()
        refreshExternalDisplays(trigger: "app_launch_task", syncWidgetSnapshot: true)
    }

    func accountDidChange() {
        externalRefreshTask?.cancel()
        externalDisplays.resetAccountPresentation()
        preferenceCloudSync.reloadForCurrentAccount()
        settings.reloadForCurrentAccount()
        scheduleViewModel.resetForCurrentAccount()
        scoreViewModel.resetForCurrentAccount()
        refreshExternalDisplays(trigger: "login_storage_changed", syncWidgetSnapshot: true)
    }

    func sceneBecameActive() {
        refreshExternalDisplays(trigger: "scene_active", syncWidgetSnapshot: true)
    }

    private func refreshExternalDisplays(trigger: String, syncWidgetSnapshot: Bool) {
#if BIT101_UI_TESTING
        guard !AppFileDirectories.isRunningUITest else { return }
#endif
        externalRefreshTask?.cancel()
        let session = currentSession()
        externalRefreshTask = Task { [externalDisplays] in
            await externalDisplays.refresh(trigger: trigger, syncWidgetSnapshot: syncWidgetSnapshot, session: session)
        }
    }
}
