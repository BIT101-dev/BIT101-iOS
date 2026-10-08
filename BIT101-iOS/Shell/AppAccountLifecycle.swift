import ScoreDomain
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
    private var subscriptions = Set<AnyCancellable>()
    private var externalRefreshTask: Task<Void, Never>?
    private let externalDisplays: any AppExternalDisplayCoordinating
    private let currentSession: @MainActor () -> AppStorageSession

    init(
        scheduleViewModel: ScheduleViewModel,
        scoreViewModel: ScoreViewModel? = nil,
        community: AppCommunityDependencies,
        scoreService: any ScoreListServicing,
        transcriptService: any TrustedTranscriptServicing,
        settings: AppSettingsStore,
        stores: AppAccountStores,
        preferenceCloudSync: ExperimentalPreferenceCloudSync,
        accountChanges: AnyPublisher<CommunitySessionIdentity, Never>,
        currentIdentity: @escaping () -> CommunitySessionIdentity,
        scheduleChanges: AnyPublisher<AppStorageSession, Never>,
        loadScheduleCourses: @escaping @MainActor (AppStorageSession) async -> [String: [ScoreCourseSummary]],
        media: MediaEnvironment,
        localData: AppLocalDataService,
        externalDisplays: any AppExternalDisplayCoordinating
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
        self.communityDestinations = AppCommunityDestinations(dependencies: community, schedule: scheduleViewModel, media: media, localData: localData)
        self.settings = settings
        self.localData = localData
        self.preferenceCloudSync = preferenceCloudSync
        self.externalDisplays = externalDisplays
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

    deinit { externalRefreshTask?.cancel() }

    func start() {
#if BIT101_UI_TESTING
        guard !AppFileDirectories.isRunningUITest else { return }
#endif
        externalDisplays.activate()
        preferenceCloudSync.refreshFromCloudIfNeeded()
        refreshExternalDisplays(trigger: "app_launch_task", syncWidgetSnapshot: true)
    }

    func accountDidChange() {
        externalRefreshTask?.cancel()
        externalDisplays.resetAccountPresentation()
        settings.reloadForCurrentAccount()
        preferenceCloudSync.reloadForCurrentAccount()
        scheduleViewModel.resetForCurrentAccount()
        scoreViewModel.resetForCurrentAccount()
        refreshExternalDisplays(trigger: "login_storage_changed", syncWidgetSnapshot: true)
    }

    func sceneBecameActive() {
        preferenceCloudSync.refreshFromCloudIfNeeded()
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
