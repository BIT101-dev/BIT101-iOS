import ScheduleFeature
//
//  BIT101_iOSApp.swift
//  BIT101-iOS
//
//  Created by Harry Bit on 2026-03-24.
//

import SwiftUI
import BackgroundTasks
import UIKit

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
    /// Apple 要求所有 BGTask 在启动序列结束前注册；AppDelegate 在 `didFinishLaunching` 中调用。
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
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

        task.expirationHandler = {
            operation.cancel()
        }
    }
}

/// iOS 应用入口。
///
/// 挂载根视图，并协调课表缓存与外部展示同步。
@main
struct BIT101_iOSApp: App {
    @StateObject private var lifecycle: AppAccountLifecycle
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
#if BIT101_UI_TESTING
        AppUITestBootstrap.prepareForLaunch()
#endif
        let preferenceCloudSync = ExperimentalPreferenceCloudSync.shared
        ScheduleCacheStore.effects = AppScheduleCacheEffects()
        AppPreferenceCacheEffects.configure(sync: preferenceCloudSync)
        _lifecycle = StateObject(wrappedValue: AppAccountLifecycle(preferenceCloudSync: preferenceCloudSync))
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
                .environment(lifecycle.communityDestinations)
                .environment(lifecycle.community)
                .environment(lifecycle.community.gallery)
                .environment(lifecycle.community.course)
                .environment(lifecycle.community.paper)
                .environment(lifecycle.community.mine)
                .environment(AppMedia.environment)
                .environmentObject(lifecycle.scheduleViewModel)
                .environmentObject(lifecycle.scheduleViewModel.ddl)
                .environmentObject(lifecycle.scoreViewModel)
                .environmentObject(lifecycle.settings)
                .environmentObject(lifecycle.preferenceCloudSync)
                .appKeyboardDismissSupport()
                .appPromptHost()
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
