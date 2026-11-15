import BackgroundTasks
import ClientCore
import Combine
import CommunityTransport
import DesignSystemKit
import ScheduleDomain
import ScheduleFeature
import ScheduleInfrastructure
import SchedulePorts
import ScheduleSync
import ScoreDomain
import ScoreInfrastructure
import ScorePorts
import SwiftUI
import UIKit
import os

final class AppDelegate: NSObject, UIApplicationDelegate {
    var restoreLoginSession: @MainActor () -> Void = {
        AppAccountSession.storage.retrySessionReadIfNeeded()
    }

    func applicationProtectedDataDidBecomeAvailable(_: UIApplication) {
        restoreLoginSession()
    }

    func application(
        _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppInterfaceOrientationPolicy.supportedOrientations(
            for: window?.windowScene?.traitCollection
                ?? UITraitCollection(userInterfaceIdiom: UIDevice.current.userInterfaceIdiom))
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if DEBUG
        if AppFileDirectories.isRunningNetworkSmoke || AppFileDirectories.isRunningICloudSmoke {
            application.isIdleTimerDisabled = true
            return true
        }
        if AppFileDirectories.isRunningIsolatedUnitTest {
            return true
        }
        if AppFileDirectories.isRunningUITest && !AppUITestBootstrap.usesProductionComposition {
            return true
        }
        #endif
        ScheduleReminderBackgroundRefresh.register()
        return true
    }

}

/// 课前提醒的后台刷新协调器。
///
/// 这条链路是 best-effort：系统决定实际唤醒时间；任务唤醒后重新计算日程提醒，
/// 尽量让灵动岛在后台有机会启动，并提交下一次刷新请求。
enum ScheduleReminderBackgroundRefresh {
    private static let logger = Logger(subsystem: "BIT101", category: "ScheduleBackgroundRefresh")
    /// 后台刷新任务标识，需与 Info.plist 中的 `BGTaskSchedulerPermittedIdentifiers` 一致。
    static var identifier: String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "BIT101-dev.BIT101-iOS"
        return "\(bundleIdentifier).schedule-refresh"
    }

    /// 在应用启动阶段注册后台刷新任务。
    ///
    /// AppDelegate 在 `didFinishLaunching` 中注册，启动回调通过主队列进入 MainActor。
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task: refreshTask)
        }
    }

    /// 根据下一次课前提醒界限，提交一条后台刷新请求。
    ///
    /// 同一 identifier 的新请求会替换先前提交的请求。
    @discardableResult
    static func schedule(
        earliestBeginDate: Date?,
        submit: (BGAppRefreshTaskRequest) throws -> Void = {
            try BGTaskScheduler.shared.submit($0)
        },
        cancel: () -> Void = {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: ScheduleReminderBackgroundRefresh.identifier)
        }
    ) -> Bool {
        guard let earliestBeginDate else {
            cancel()
            return true
        }

        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate

        do {
            try submit(request)
            return true
        } catch {
            let failure = error as NSError
            logger.error(
                """
                Background refresh submission failed domain=\(failure.domain, privacy: .public)\
                 code=\(failure.code) description=\
                \(failure.localizedDescription, privacy: .private)
                """
            )
            return false
        }
    }

    /// 后台刷新任务入口。
    ///
    /// 系统唤醒 app 后重新计算提醒，并预排下一次后台刷新。
    private static func handle(task: BGAppRefreshTask) {
        let operation = Task {
            AppAccountSession.storage.retrySessionReadIfNeeded()
            let identity = AppAccountSession.storage.communityCredentials.identity
            var completed = false
            defer {
                task.setTaskCompleted(success: completed)
            }
            guard !Task.isCancelled, AppAccountSession.storage.hasResolvedSession else { return }

            guard AppAccountSession.storage.hasCachedSession else {
                schedule(earliestBeginDate: nil)
                await ScheduleLiveActivityManager.shared.endAllActivities()
                completed =
                    !Task.isCancelled
                    && identity == AppAccountSession.storage.communityCredentials.identity
                return
            }

            completed = await refreshIfCurrent(
                isCurrent: {
                    AppAccountSession.storage.hasResolvedSession
                        && identity == AppAccountSession.storage.communityCredentials.identity
                },
                nextBeginDate: {
                    try await ScheduleLiveActivityManager.shared.backgroundRefreshDate()
                },
                schedule: { schedule(earliestBeginDate: $0) },
                refresh: {
                    await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(
                        trigger: "bg_app_refresh")
                })
        }

        task.expirationHandler = { @Sendable in
            operation.cancel()
        }
    }

    static func refreshIfCurrent(
        isCurrent: () -> Bool, nextBeginDate: () async throws -> Date?,
        schedule: (Date?) -> Bool, refresh: () async -> Void
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        let next: Date?
        do { next = try await nextBeginDate() } catch { return false }
        guard !Task.isCancelled, isCurrent() else { return false }
        let submitted = schedule(next)
        await refresh()
        return submitted && !Task.isCancelled && isCurrent()
    }
}

/// iOS 应用入口。
///
/// 挂载根视图，并协调课表缓存与外部展示同步。
@main
struct BIT101_iOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    private enum LaunchMode {
        case icloudSmoke
        case networkSmoke
        case isolatedUnitTest
        case uiTest(UITestSceneState)
        case production(AppAccountLifecycle)
    }
    @State private var launchMode: LaunchMode
    @State private var networkSmokeSMS = ReleaseNetworkSmokeSMSPrompt()
    #else
    @State private var lifecycle: AppAccountLifecycle
    #endif

    init() {
        #if DEBUG
        if AppFileDirectories.isRunningICloudSmoke {
            _launchMode = State(initialValue: .icloudSmoke)
        } else if AppFileDirectories.isRunningNetworkSmoke {
            _launchMode = State(initialValue: .networkSmoke)
        } else if AppFileDirectories.isRunningIsolatedUnitTest {
            _launchMode = State(initialValue: .isolatedUnitTest)
        } else if AppFileDirectories.isRunningUITest {
            AppUITestBootstrap.prepareForLaunch()
            _launchMode = State(
                initialValue: .uiTest(UITestSceneState(makeLifecycle: Self.makeLifecycle)))
        } else {
            _launchMode = State(initialValue: .production(Self.makeLifecycle()))
        }
        #else
        _lifecycle = State(initialValue: Self.makeLifecycle())
        #endif
    }

    private static func makeLifecycle() -> AppAccountLifecycle {
        let settings = AppSettingsStore.shared
        let stores = AppAccountStores.shared
        let preferenceCloudSync: ExperimentalPreferenceCloudSync
        #if DEBUG
        if AppFileDirectories.isRunningUITest && !AppUITestBootstrap.usesProductionComposition {
            let cloud = AutomatedTestPreferenceCloudStore()
            preferenceCloudSync = ExperimentalPreferenceCloudSync(
                settings: settings, stores: stores, cloudStore: cloud,
                scoreEncryption: ScoreCacheSyncEncryption(
                    defaults: AppFileDirectories.defaults, credentials: cloud))
        } else {
            preferenceCloudSync = ExperimentalPreferenceCloudSync.shared
        }
        #else
        preferenceCloudSync = ExperimentalPreferenceCloudSync.shared
        #endif
        let productionScores = ScoreService()
        let scores: any ScoreListServicing
        let transcripts: any TrustedTranscriptServicing
        #if DEBUG
        let useUITestScores =
            AppFileDirectories.isRunningUITest && !AppUITestBootstrap.usesProductionComposition
        scores = useUITestScores ? UITestScoreService() : productionScores
        transcripts = useUITestScores ? UITestScoreService() : productionScores
        #else
        scores = productionScores
        transcripts = productionScores
        #endif
        let diagnosisSchool: NetworkDiagnosisSchool = {
            #if DEBUG
            if AppFileDirectories.isRunningUITest
                && !AppUITestBootstrap.usesProductionComposition
            {
                let service = UITestSchoolService()
                return NetworkDiagnosisSchool(
                    identity: { AppAccountSession.storage.schoolSessionIdentity },
                    currentTerm: service.fetchCurrentTermOnly,
                    syncCourses: { _ = try await service.syncCourses(term: $0) },
                    ddl: {
                        try await service.syncDDLEvents(
                            existingEvents: [], storedURL: "", schoolSMSCodeHandler: nil
                        )
                    })
            }
            #endif
            let service = ScheduleServiceFactory.make()
            return NetworkDiagnosisSchool(
                identity: { AppAccountSession.storage.schoolSessionIdentity },
                currentTerm: service.fetchCurrentTermOnly,
                syncCourses: { _ = try await service.syncCourses(term: $0) },
                ddl: {
                    let result = try await service.probeEclassEvents()
                    return DDLSyncPayload(
                        url: "", events: result.events, syncedGroups: ["eclass"],
                        warnings: result.failure.map { [$0.localizedDescription] } ?? [])
                })
        }()
        return AppAccountLifecycle(
            scheduleViewModel: makeScheduleViewModel(),
            community: .app(settings: settings, stores: stores),
            scoreService: scores, transcriptService: transcripts,
            diagnosisSchool: diagnosisSchool, settings: settings, stores: stores,
            preferenceCloudSync: preferenceCloudSync,
            accountChanges: AppAccountSession.storage.changes,
            currentIdentity: { AppAccountSession.storage.communityCredentials.identity },
            scheduleChanges: ScheduleCacheStore.changes, scheduleCloudSync: .shared,
            refreshScheduleCloud: {
                await ScheduleCloudSyncManager.shared.refreshFromCloudIfNeeded()
            },
            isNotificationPermissionDenied: {
                await ScheduleLiveActivityManager.shared.reminderAuthorization() == .denied
            },
            loadScheduleCourses: AppAccountStores.loadScheduleCourses,
            media: AppMedia.environment,
            localData: AppLocalDataComposition.appService(
                settings: settings, media: AppMedia.environment),
            externalDisplays: AppExternalDisplayCoordinator(
                currentSession: stores.currentSession,
                isSessionResolved: { AppAccountSession.storage.hasResolvedSession },
                isSignedIn: { AppAccountSession.storage.hasCachedSession },
                activateWatch: WatchScheduleSyncManager.shared.activateIfNeeded,
                resetPresentation: AppErrorPresenter.shared.reset,
                exportWidget: ScheduleWidgetExporter.syncFromCurrentCache,
                nextReminderRefresh: ScheduleLiveActivityManager.shared
                    .backgroundRefreshDate,
                scheduleBackgroundRefresh: {
                    _ = ScheduleReminderBackgroundRefresh.schedule(earliestBeginDate: $0)
                },
                endActivities: ScheduleLiveActivityManager.shared.endAllActivities,
                refreshActivities: {
                    await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(
                        trigger: $0)
                }
            )
        )
    }

    private static func makeScheduleViewModel() -> ScheduleViewModel {
        #if DEBUG
        if AppFileDirectories.isRunningUITest && !AppUITestBootstrap.usesProductionComposition {
            let actions = UITestSchedulePlatformActions(
                historyNeedsRecovery:
                    AppUITestBootstrap.environment[
                        "BIT101_UI_TEST_CALENDAR_HISTORY_RECOVERY"] == "1")
            return ScheduleServiceFactory.makeViewModel(
                platformActions: actions, didSave: { _, _, _ in })
        }
        #endif
        let effects = AppScheduleCacheEffects(
            currentSession: { AppAccountSession.currentSession },
            currentIdentity: { AppAccountSession.storage.communityCredentials.identity },
            pushCloud: { await ScheduleCloudSyncManager.shared.pushLatestCache() },
            reconcileCloud: {
                await ScheduleCloudSyncManager.shared.reconcileAfterEnabling()
            },
            requestReminderAuthorization: {
                _ = await ScheduleLiveActivityManager.shared.authorizeNotifications()
            },
            refreshReminder: {
                await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(
                    trigger: $0)
            },
            importCourses: {
                try await ScheduleSystemCalendarManager.shared.importCurrentTerm(from: $0, term: $1)
            },
            importDrafts: {
                try await ScheduleSystemCalendarManager.shared.importDrafts($0, term: $1)
            },
            deleteEntries: {
                try await ScheduleSystemCalendarManager.shared.deleteImportedEvents(
                    markerIDs: $0, term: $1)
            },
            deleteAllEntries: {
                try await ScheduleSystemCalendarManager.shared.deleteAllImportedEvents()
            },
            rebuildCalendarHistory: {
                try await ScheduleSystemCalendarManager.shared.rebuildImportHistory()
            }
        )
        return ScheduleServiceFactory.makeViewModel(
            platformActions: effects, didSave: effects.didSave)
    }

    /// 根场景定义。主题模式由设置快照驱动；登录态、课表缓存和场景状态变化时，
    /// 入口负责同步 Widget、Watch 和 Live Activity。
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            debugSceneRoot
            #else
            productionSceneRoot(lifecycle: lifecycle)
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            handleSceneBecameActive()
        }
    }

    private func productionSceneRoot(lifecycle: AppAccountLifecycle) -> some View {
        ContentView(
            transcriptService: lifecycle.transcriptService, localData: lifecycle.localData
        )
        .modifier(AppAccountEnvironment(lifecycle: lifecycle))
        .appKeyboardDismissSupport()
        .appPromptHost(updates: lifecycle.updates, prompts: lifecycle.prompts)
        .onOpenURL { url in
            AppDeepLinkCoordinator.shared.receive(url)
        }
        .task {
            lifecycle.start()
            AppRestoreReadiness.initializedScene()
            await AppFileDirectories.preparePersistentBackups()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)
        ) { _ in
            AppRestoreReadiness.recordIfReady()
        }
    }

    private func activateProductionScene(lifecycle: AppAccountLifecycle) {
        // 回到前台时导出本地快照并刷新时间线；学校请求由用户显式操作触发。
        appDelegate.restoreLoginSession()
        lifecycle.sceneBecameActive()
        AppRestoreReadiness.recordIfReady()
    }

    private func handleSceneBecameActive() {
        #if DEBUG
        switch launchMode {
        case .icloudSmoke, .networkSmoke, .isolatedUnitTest:
            break
        case .uiTest(let uiTestScene):
            guard AppUITestBootstrap.usesProductionComposition else { return }
            activateProductionScene(lifecycle: uiTestScene.lifecycle)
        case .production(let lifecycle):
            activateProductionScene(lifecycle: lifecycle)
        }
        #else
        activateProductionScene(lifecycle: lifecycle)
        #endif
    }

    #if DEBUG
    @ViewBuilder
    private var debugSceneRoot: some View {
        switch launchMode {
        case .icloudSmoke:
            Color.clear.accessibilityIdentifier("icloud-cross-device-smoke-host")
        case .networkSmoke:
            networkSmokeSceneRoot
        case .isolatedUnitTest:
            Color.clear.accessibilityIdentifier("behavior-test-host")
        case .uiTest(let uiTestScene):
            uiTestSceneRoot(uiTestScene)
        case .production(let lifecycle):
            productionSceneRoot(lifecycle: lifecycle)
        }
    }

    private var networkSmokeSceneRoot: some View {
        // 采样宿主通过当前登录会话执行网络采样，并承接短信验证码输入。
        Color.clear
            .accessibilityIdentifier("release-network-smoke-host")
            .task {
                do {
                    let smokeRequest = try ReleaseNetworkSmokeLaunchRequest.readPendingFile()
                    await runNetworkSmoke(smokeRequest)
                } catch {
                    let failure = error as NSError
                    FileHandle.standardOutput.write(
                        Data(
                            """
                            NETWORK_SMOKE_REQUEST_FAIL domain=\(failure.domain) code=\
                            \(failure.code)\n
                            """
                            .utf8))
                }
            }
            .onOpenURL { url in
                guard let smokeRequest = ReleaseNetworkSmokeLaunchRequest(url: url) else {
                    return
                }
                Task { await runNetworkSmoke(smokeRequest) }
            }
            .sheet(item: $networkSmokeSMS.request) { request in
                AppVerificationSheet(
                    maskedPhone: request.maskedPhone, isSubmitting: false,
                    errorMessage: nil, submitTitle: "验证并继续",
                    onCancel: networkSmokeSMS.cancel,
                    onSubmit: { networkSmokeSMS.submit($0) }
                )
                .interactiveDismissDisabled()
            }
    }

    private func runNetworkSmoke(_ smokeRequest: ReleaseNetworkSmokeLaunchRequest) async {
        _ = await ReleaseNetworkSmokeRunner().run(
            scope: smokeRequest.scope,
            runID: smokeRequest.runID,
            capture: smokeRequest.capture,
            term: smokeRequest.term,
            communityFollowTarget: smokeRequest.communityFollowTarget,
            communityExpectedAccount: smokeRequest.communityExpectedAccount,
            communityRecoveryConfirmation: smokeRequest.communityRecoveryConfirmation,
            fixtures: smokeRequest.fixtures,
            schoolSMSCodeHandler: smokeRequest.interactiveSMS == true
                ? networkSmokeSMS.requestCode : nil
        )
    }

    private func uiTestSceneRoot(_ uiTestScene: UITestSceneState) -> some View {
        let lifecycle = uiTestScene.lifecycle
        return ContentView(
            transcriptService: lifecycle.transcriptService, localData: lifecycle.localData
        )
        .uiTestExternalURLs()
        .modifier(AppAccountEnvironment(lifecycle: lifecycle))
        .appKeyboardDismissSupport()
        .environment(\.appInteractionEvidence) { identifier, action in
            UITestAccessibilityActions.recordCallback(identifier, action: action)
        }
        .appPromptHost(updates: lifecycle.updates, prompts: lifecycle.prompts)
        .id(uiTestScene.revision)
        .environment(\.sizeCategory, uiTestScene.largeText ? .accessibilityLarge : .large)
        .preferredColorScheme(uiTestScene.colorScheme)
        .overlay(alignment: .topLeading) {
            Color.clear.frame(
                width: AppDesignSystem.Size.Control.compact,
                height: AppDesignSystem.Size.Control.compact
            )
            .accessibilityElement()
            .accessibilityIdentifier("ui-test.scene")
            .accessibilityValue(
                Text(
                    verbatim:
                        """
                        \(ProcessInfo.processInfo.processIdentifier):\
                        \(uiTestScene.revision)
                        """
                )
            )
            .allowsHitTesting(false)
        }
        .onOpenURL { url in
            AppDeepLinkCoordinator.shared.receive(url)
        }
        .task {
            lifecycle.start()
            AppRestoreReadiness.initializedScene()
            await AppFileDirectories.preparePersistentBackups()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)
        ) { _ in
            AppRestoreReadiness.recordIfReady()
        }
    }
    #endif
}

#if DEBUG
@MainActor
@Observable final class UITestSceneState {
    private(set) var lifecycle: AppAccountLifecycle
    private(set) var revision = 0
    @ObservationIgnored var largeText = false
    @ObservationIgnored var colorScheme: ColorScheme?
    private let makeLifecycle: () -> AppAccountLifecycle
    @ObservationIgnored private var control: UITestControlServer?

    init(makeLifecycle: @escaping () -> AppAccountLifecycle) {
        self.makeLifecycle = makeLifecycle
        lifecycle = makeLifecycle()
        largeText = AppUITestBootstrap.environment["BIT101_UI_TEST_LARGE_TEXT"] == "1"
        colorScheme = AppUITestBootstrap.environment["BIT101_UI_TEST_STYLE"].flatMap {
            $0 == "Dark" ? .dark : .light
        }
        _ = UITestAccessibilityActions.keyboardState()
        do {
            control = try UITestControlServer { [weak self] data, reply in
                Task { @MainActor in
                    guard let self else { return }
                    await self.handleControl(data, reply: reply)
                }
            }
        } catch {
            preconditionFailure("UI test control channel failed: \(error)")
        }
    }

    private func handleControl(
        _ data: Data, reply: @escaping @Sendable (Data) -> Void
    ) async {
        do {
            let environment = try JSONDecoder().decode(
                [String: String].self, from: data)
            if environment["command"] == "observe" {
                reply(Data(UITestAccessibilityActions.observe().utf8))
                return
            }
            if environment["command"] == "coverage" {
                reply(try UITestAccessibilityActions.coverage())
                return
            }
            if environment["command"] == "window-layout" {
                reply(try UITestAccessibilityActions.windowLayout())
                return
            }
            if environment["command"] == "map-camera" {
                reply(try UITestAccessibilityActions.mapCamera())
                return
            }
            if environment["command"] == "preview-page" {
                reply(
                    try UITestAccessibilityActions.previewPage(
                        details: environment["details"] == "1"))
                return
            }
            if environment["command"] == "identity" {
                reply(Data(UITestAccessibilityActions.identity(environment).utf8))
                return
            }
            if environment["command"] == "native-observe" {
                reply(
                    Data(
                        UITestAccessibilityActions.nativeIdentity(environment).utf8)
                )
                return
            }
            if ["scroll-inventory", "scroll-check", "scroll-restore"].contains(
                environment["command"] ?? "")
            {
                reply(try UITestAccessibilityActions.scroll(environment))
                return
            }
            if environment["command"] == "record" {
                UITestAccessibilityActions.invalidate()
                let recorded = UITestAccessibilityActions.record(
                    environment["identifier"] ?? "",
                    label: environment["label"] ?? "",
                    type: Int(environment["type"] ?? "") ?? 0,
                    scope: environment["scope"], instance: environment["instance"],
                    action: environment["action"] ?? "tap")
                reply(Data((recorded ? "recorded" : "unobserved").utf8))
                return
            }
            if environment["command"] == "callback" {
                UITestAccessibilityActions.recordCallback(
                    environment["identifier"] ?? "",
                    action: environment["action"] ?? "tap")
                reply(Data("recorded".utf8))
                return
            }
            if environment["command"] == "state" {
                UITestAccessibilityActions.checkDisabled(
                    environment["identifier"] ?? "",
                    label: environment["label"] ?? "",
                    type: Int(environment["type"] ?? "") ?? 0,
                    scope: environment["scope"], instance: environment["instance"])
                reply(Data("checked".utf8))
                return
            }
            if environment["command"] == "occlusion" {
                reply(Data(UITestAccessibilityActions.occlude(environment).utf8))
                return
            }
            if [
                "query", "query-activate", "query-input", "query-reveal",
                "query-accessibility-action",
            ].contains(environment["command"] ?? "") {
                let response = try UITestAccessibilityActions.read(environment)
                if ["activated", "control", "entered", "revealed", "performed"]
                    .contains(String(decoding: response, as: UTF8.self))
                {
                    let frameRate =
                        UIApplication.shared.connectedScenes.compactMap {
                            $0 as? UIWindowScene
                        }
                        .first?.screen.maximumFramesPerSecond ?? 60
                    try await Task.sleep(for: .seconds(2 / Double(frameRate)))
                }
                reply(response)
                return
            }
            if environment["command"] == "activate" {
                UITestAccessibilityActions.invalidate()
                reply(Data(UITestAccessibilityActions.activate(environment).utf8))
                return
            }
            if environment["command"] == "resolve" {
                reply(try UITestAccessibilityActions.resolve(environment))
                return
            }
            if environment["command"] == "input" {
                UITestAccessibilityActions.invalidate()
                reply(Data(UITestAccessibilityActions.input(environment).utf8))
                return
            }
            if environment["command"] == "finish-input" {
                UITestAccessibilityActions.invalidate()
                reply(Data(UITestAccessibilityActions.finishInput().utf8))
                return
            }
            if environment["command"] == "select-input" {
                reply(Data(UITestAccessibilityActions.selectInput().utf8))
                return
            }
            if environment["command"] == "consume-opened-url" {
                reply(
                    Data((UITestAccessibilityActions.openedExternalURL ?? "").utf8))
                UITestAccessibilityActions.openedExternalURL = nil
                return
            }
            if environment["command"] == "safe-area" {
                reply(try UITestAccessibilityActions.safeAreaFrame())
                return
            }
            if environment["command"] == "keyboard-state" {
                reply(
                    Data(
                        UITestAccessibilityActions.keyboardState(
                            returnTitle: environment["return-title"]
                        ).utf8))
                return
            }
            if let command = environment["command"],
                [
                    "request-state", "release-request", "fail-request",
                    "hold-request",
                ].contains(command)
            {
                guard let key = environment["key"], !key.isEmpty else {
                    throw CocoaError(.coderInvalidValue)
                }
                let query = Dictionary(
                    uniqueKeysWithValues: environment.filter {
                        $0.key.hasPrefix("query.")
                    }
                    .map { (String($0.key.dropFirst("query.".count)), $0.value) })
                if command == "hold-request" {
                    AppUITestBootstrap.completedRequests.remove(key)
                    AppUITestBootstrap.holdingRequests[key] = query
                    reply(Data("queued".utf8))
                } else if command == "fail-request" {
                    AppUITestBootstrap.failingRequests[key] = query
                    if environment["persistent"] == "1" {
                        AppUITestBootstrap.persistentFailures.insert(key)
                    } else {
                        AppUITestBootstrap.persistentFailures.remove(key)
                    }
                    reply(Data("queued".utf8))
                } else if command == "release-request" {
                    AppUITestBootstrap.releaseRequest(key)
                    reply(Data("released".utf8))
                } else {
                    reply(Data(Self.requestState(for: key).utf8))
                }
                return
            }
            self.configure(environment)
            reply(
                Data(
                    "\(ProcessInfo.processInfo.processIdentifier):\(self.revision)"
                        .utf8))
        } catch {
            reply(Data("invalid scene configuration: \(error)".utf8))
        }
    }

    private func configure(_ environment: [String: String]) {
        UITestAccessibilityActions.invalidate()
        UITestAccessibilityActions.openedExternalURL = nil
        AppErrorPresenter.shared.reset()
        UITestSceneConfiguration.shared.replace(with: environment)
        largeText = environment["BIT101_UI_TEST_LARGE_TEXT"] == "1"
        colorScheme = environment["BIT101_UI_TEST_STYLE"].flatMap {
            $0 == "Dark" ? .dark : .light
        }
        AppUITestBootstrap.prepareForLaunch()
        AppSettingsStore.shared.reloadForCurrentAccount()
        lifecycle = makeLifecycle()
        revision += 1
    }

    private static func requestState(for key: String) -> String {
        if AppUITestBootstrap.pendingRequests[key] != nil {
            return "pending"
        }
        if AppUITestBootstrap.holdingRequests[key] != nil {
            return "queued"
        }
        if AppUITestBootstrap.completedRequests.contains(key) {
            return "completed"
        }
        return "idle"
    }
}

#endif
