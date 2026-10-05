import ScoreInfrastructure
import ScoreDomain
import ScheduleFeature
import DesignSystemKit
//
//  BIT101_iOSApp.swift
//  BIT101-iOS
//
//  Created by Harry Bit on 2026-03-24.
//

import SwiftUI
import BackgroundTasks
import UIKit
#if BIT101_UI_TESTING
import Combine
#endif

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
#if BIT101_UI_TESTING
        guard !AppFileDirectories.isRunningUITest else { return true }
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

    /// 根据下一次课前提醒边界，提交一条后台刷新请求。
    ///
    /// 同一 identifier 的新请求会替换先前提交的请求。
    static func schedule(earliestBeginDate: Date?) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard let earliestBeginDate else { return }

        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate

        try? BGTaskScheduler.shared.submit(request)
    }

    /// 后台刷新任务入口。
    ///
    /// 系统唤醒 app 后重新计算提醒，并预排下一次后台刷新。
    private static func handle(task: BGAppRefreshTask) {
        let operation = Task {
            defer {
                task.setTaskCompleted(success: !Task.isCancelled)
            }

            let fakeCookie = LoginStorage.shared.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fakeCookie.isEmpty else {
                schedule(earliestBeginDate: nil)
                await ScheduleLiveActivityManager.shared.endAllActivities()
                return
            }

            let nextBeginDate = await ScheduleLiveActivityManager.shared.preferredBackgroundRefreshBeginDate()
            schedule(earliestBeginDate: nextBeginDate)
            await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(trigger: "bg_app_refresh")
        }

        task.expirationHandler = { @Sendable in
            operation.cancel()
        }
    }
}

/// iOS 应用入口。
///
/// 挂载根视图，并协调课表缓存与外部展示同步。
@main
struct BIT101_iOSApp: App {
#if BIT101_UI_TESTING
    @StateObject private var uiTestScene: UITestSceneState
    private var lifecycle: AppAccountLifecycle { uiTestScene.lifecycle }
#else
    @StateObject private var lifecycle: AppAccountLifecycle
#endif
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
#if BIT101_UI_TESTING
        AppUITestBootstrap.prepareForLaunch()
        _uiTestScene = StateObject(wrappedValue: UITestSceneState(makeLifecycle: Self.makeLifecycle))
#else
        _lifecycle = StateObject(wrappedValue: Self.makeLifecycle())
#endif
    }

    private static func makeLifecycle() -> AppAccountLifecycle {
        let preferenceCloudSync: ExperimentalPreferenceCloudSync
#if BIT101_UI_TESTING
        preferenceCloudSync = ExperimentalPreferenceCloudSync(settings: .shared, stores: .shared, cloudStore: UITestPreferenceCloudStore())
#else
        preferenceCloudSync = ExperimentalPreferenceCloudSync.shared
#endif
        let productionScores = ScoreService()
        let scores: any ScoreListServicing
        let transcripts: any TrustedTranscriptServicing
#if BIT101_UI_TESTING
        scores = AppFileDirectories.isRunningUITest ? UITestScoreService() : productionScores
        transcripts = AppFileDirectories.isRunningUITest ? UITestScoreService() : productionScores
#else
        scores = productionScores
        transcripts = productionScores
#endif
        return AppAccountLifecycle(
            scheduleViewModel: ScheduleServiceFactory.makeViewModel(),
            community: .app(settings: preferenceCloudSync.settings, stores: preferenceCloudSync.stores),
            scoreService: scores, transcriptService: transcripts, preferenceCloudSync: preferenceCloudSync,
            notifications: .default,
            scheduleChanges: ScheduleCacheStore.changes, loadScheduleCourses: AppAccountStores.loadScheduleCourses,
            media: AppMedia.environment, localData: .appService(settings: preferenceCloudSync.settings, media: AppMedia.environment),
            externalDisplays: AppExternalDisplayCoordinator()
        )
    }

    /// 根场景定义。主题模式由设置快照驱动；登录态、课表缓存和场景状态变化时，
    /// 入口负责同步 Widget、Watch 和 Live Activity。
    var body: some Scene {
        WindowGroup {
            #if RELEASE_NETWORK_SMOKE
            // 冒烟模式挂载测试宿主，登录校验、首页 `.task` 和启动请求
            // 与顺序网络探针并发。
            Color.clear
                .accessibilityIdentifier("release-network-smoke-host")
                .task {
                    guard let smokeRequest = ReleaseNetworkSmokeLaunchRequest.readPendingFile() else { return }
                    _ = await ReleaseNetworkSmokeRunner().run(
                        scope: smokeRequest.scope,
                        runID: smokeRequest.runID,
                        capture: smokeRequest.capture,
                        term: smokeRequest.term
                    )
                }
                .onOpenURL { url in
                    guard let smokeRequest = ReleaseNetworkSmokeLaunchRequest(url: url) else { return }
                    Task {
                        _ = await ReleaseNetworkSmokeRunner().run(
                            scope: smokeRequest.scope,
                            runID: smokeRequest.runID,
                            capture: smokeRequest.capture,
                            term: smokeRequest.term
                        )
                    }
                }
            #else
            ContentView(transcriptService: lifecycle.transcriptService)
#if BIT101_UI_TESTING
                .uiTestExternalURLs()
#endif
                .environment(lifecycle.communityDestinations)
                .environment(lifecycle.community)
                .environment(lifecycle.communityDestinations.media)
                .environmentObject(lifecycle.scheduleViewModel)
                .environmentObject(lifecycle.scheduleViewModel.ddl)
                .environmentObject(lifecycle.scoreViewModel)
                .environmentObject(lifecycle.settings)
                .environmentObject(lifecycle.preferenceCloudSync)
                .appKeyboardDismissSupport()
                .appPromptHost()
#if BIT101_UI_TESTING
                .id(uiTestScene.revision)
                .environment(\.sizeCategory, uiTestScene.largeText ? .accessibilityLarge : .large)
                .preferredColorScheme(uiTestScene.colorScheme)
                .overlay(alignment: .topLeading) {
                    Color.clear.frame(width: AppDesignSystem.Size.Control.compact, height: AppDesignSystem.Size.Control.compact)
                        .accessibilityElement()
                        .accessibilityIdentifier("ui-test.scene")
                        .accessibilityValue(Text(verbatim: "\(ProcessInfo.processInfo.processIdentifier):\(uiTestScene.revision)"))
                        .allowsHitTesting(false)
                }
#endif
                .onOpenURL { url in
                    AppDeepLinkCoordinator.shared.receive(url)
                }
                .task { lifecycle.start() }
            #endif
        }
        #if !RELEASE_NETWORK_SMOKE
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
#if BIT101_UI_TESTING
                guard !AppFileDirectories.isRunningUITest else { return }
#endif
                // 回到前台时导出本地快照并刷新时间线；学校请求由用户显式操作触发。
                lifecycle.sceneBecameActive()
            }
        }
        #endif
    }
}

#if BIT101_UI_TESTING
@MainActor
final class UITestSceneState: ObservableObject {
    @Published private(set) var lifecycle: AppAccountLifecycle
    @Published private(set) var revision = 0
    var largeText = false
    var colorScheme: ColorScheme?
    private let makeLifecycle: () -> AppAccountLifecycle
    private var control: UITestControlServer?

    init(makeLifecycle: @escaping () -> AppAccountLifecycle) {
        self.makeLifecycle = makeLifecycle
        lifecycle = makeLifecycle()
        largeText = AppUITestBootstrap.environment["BIT101_UI_TEST_LARGE_TEXT"] == "1"
        colorScheme = AppUITestBootstrap.environment["BIT101_UI_TEST_STYLE"].flatMap { $0 == "Dark" ? .dark : .light }
        _ = UITestAccessibilityActions.keyboardState()
        do {
            control = try UITestControlServer { [weak self] data, reply in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        let environment = try JSONDecoder().decode([String: String].self, from: data)
                        if environment["command"] == "coverage" {
                            reply(try UITestAccessibilityActions.coverage())
                            return
                        }
                        if environment["command"] == "record" {
                            UITestAccessibilityActions.invalidate()
                            UITestAccessibilityActions.record(environment["identifier"] ?? "")
                            reply(Data("recorded".utf8))
                            return
                        }
                        if ["query", "query-activate", "query-input", "query-reveal"].contains(environment["command"] ?? "") {
                            let response = try UITestAccessibilityActions.read(environment)
                            if ["activated", "control", "entered", "revealed"].contains(String(decoding: response, as: UTF8.self)) {
                                let frameRate = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
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
                        if environment["command"] == "keyboard-state" {
                            reply(Data(UITestAccessibilityActions.keyboardState().utf8))
                            return
                        }
                        self.configure(environment)
                        reply(Data("\(ProcessInfo.processInfo.processIdentifier):\(self.revision)".utf8))
                    } catch {
                        reply(Data("invalid scene configuration: \(error)".utf8))
                    }
                }
            }
        } catch {
            preconditionFailure("UI test control channel failed: \(error)")
        }
    }

    private func configure(_ environment: [String: String]) {
        UITestAccessibilityActions.invalidate()
        AppErrorPresenter.shared.reset()
        UITestSceneConfiguration.shared.replace(with: environment)
        largeText = environment["BIT101_UI_TEST_LARGE_TEXT"] == "1"
        colorScheme = environment["BIT101_UI_TEST_STYLE"].flatMap { $0 == "Dark" ? .dark : .light }
        AppUITestBootstrap.prepareForLaunch()
        AppSettingsStore.shared.reloadForCurrentAccount()
        lifecycle = makeLifecycle()
        revision += 1
    }

}

#endif
