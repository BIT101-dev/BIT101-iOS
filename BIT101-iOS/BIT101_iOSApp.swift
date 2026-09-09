//
//  BIT101_iOSApp.swift
//  BIT101-iOS
//
//  Created by Harry Bit on 2026-03-24.
//

import SwiftUI
import Combine
import BackgroundTasks
import UIKit

/// 学业页面共享的状态对象。
///
/// 这里复用页面状态；应用启动、回前台或切换账号时，学校请求由用户主动操作触发。
/// 所有可能触发 WebVPN / 短信验证的学校请求都只能由用户进入对应页面后显式发起。
@MainActor
final class SchoolDataViewModelStore: ObservableObject {
    static let shared = SchoolDataViewModelStore()

    let scheduleViewModel = ScheduleViewModel()
    let scoreViewModel = ScoreViewModel()

    private init() {}
}

/// 统一管理应用允许的方向集合。
///
/// 项目默认只允许竖屏；当用户在设置里打开自动旋转时，再放开系统旋转。
enum AppOrientationController {
    /// 根据自动旋转设置生成 UIKit 使用的方向掩码。
    ///
    /// 各入口通过这个方法复用同一套方向规则。
    static func supportedMask(autoRotate: Bool) -> UIInterfaceOrientationMask {
        autoRotate ? .allButUpsideDown : .portrait
    }

    /// 读取当前持久化设置，给 `UIApplicationDelegate` 提供实时方向限制。
    ///
    /// 这个方法会在系统询问“当前窗口支持哪些方向”时被调用，所以不能依赖
    /// 某个特定的 SwiftUI 视图状态，只能从共享设置快照中读取一个稳定结果。
    static func currentMask() -> UIInterfaceOrientationMask {
        let snapshot = AppSettingsStore.loadSnapshotFromDefaults() ?? AppSettingsSnapshot()
        return supportedMask(autoRotate: snapshot.autoRotate)
    }

    /// 将用户刚修改的自动旋转偏好同步给所有已连接的 window scene。
    ///
    /// `requestGeometryUpdate` 会请求系统重新评估方向能力。遍历所有 scene 和 window，
    /// 让主窗口、sheet 以及其他窗口场景都收到新的方向约束。
    @MainActor
    static func applyPreference(autoRotate: Bool) {
        let mask = supportedMask(autoRotate: autoRotate)

        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            windowScene.requestGeometryUpdate(preferences) { _ in }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

/// 让 UIKit 在需要时回调当前允许的方向集合。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ScheduleReminderBackgroundRefresh.register()
        return true
    }

    /// 提供应用级方向限制，方向状态由 `AppOrientationController` 读取。
    func application(
        _: UIApplication,
        supportedInterfaceOrientationsFor _: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationController.currentMask()
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
    /// 重新提交同一 identifier 的请求时，系统会用新的请求替换旧请求。
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
            let nextBeginDate = ScheduleLiveActivityManager.shared.preferredBackgroundRefreshBeginDate()
            schedule(earliestBeginDate: nextBeginDate)
            await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(trigger: "bg_app_refresh")
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            operation.cancel()
        }
    }
}

/// iOS 应用入口。
///
/// 挂载根视图、注入主题，并协调应用级方向、课表缓存与外部展示同步。
@main
struct BIT101_iOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// 全局设置单例，负责驱动主题模式、旋转等跨页面偏好。
    @StateObject private var settings = AppSettingsStore.shared
    /// 通过 UIKit delegate 响应方向能力查询。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 把本地课表缓存同步到 Widget、Watch 和 Live Activity。
    ///
    /// 这条链路读取本地缓存并刷新外部展示；学校数据同步由用户显式操作触发。
    private func refreshScheduleExternalDisplays(trigger: String, syncWidgetSnapshot: Bool) {
        if syncWidgetSnapshot {
            ScheduleWidgetExporter.syncFromCurrentCache()
        }

        Task {
            let nextBeginDate = ScheduleLiveActivityManager.shared.preferredBackgroundRefreshBeginDate()
            ScheduleReminderBackgroundRefresh.schedule(earliestBeginDate: nextBeginDate)

            // 退出登录或登录失效后，直接结束现有提醒，避免旧 activity 继续挂在灵动岛上。
            let fakeCookie = LoginStorage.shared.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines)
            if fakeCookie.isEmpty {
                await ScheduleLiveActivityManager.shared.endAllActivities()
                return
            }

            await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(trigger: trigger)
        }
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
                .onOpenURL { url in
                    guard let smokeRequest = ReleaseNetworkSmokeLaunchRequest(url: url) else { return }
                    Task {
                        _ = await ReleaseNetworkSmokeRunner().run(
                            scope: smokeRequest.scope,
                            runID: smokeRequest.runID,
                            capture: smokeRequest.capture
                        )
                    }
                }
            #else
            ContentView()
                .appKeyboardDismissSupport()
                .appPromptHost()
                .onOpenURL { url in
                    AppDeepLinkCoordinator.shared.receive(url)
                }
                .preferredColorScheme(settings.themeMode.colorScheme)
                .onAppear {
                    // 首次挂载时，立即把当前旋转偏好下发给 UIKit。
                    AppOrientationController.applyPreference(autoRotate: settings.autoRotate)
                }
                .onChange(of: settings.autoRotate) { _, newValue in
                    // 设置页改动后，实时收紧或放开方向限制。
                    AppOrientationController.applyPreference(autoRotate: newValue)
                }
                .task {
                    // 先激活 WatchConnectivity，接收 watch 端发来的“重新同步”请求。
                    WatchScheduleSyncManager.shared.activateIfNeeded()

                    // 启动时导出本地缓存并刷新外部展示；学校请求由用户显式操作触发。
                    refreshScheduleExternalDisplays(trigger: "app_launch_task", syncWidgetSnapshot: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: .loginStorageDidChange)) { _ in
                    // 账号切换后清掉失去上下文的全局提示队列。
                    AppErrorPresenter.shared.reset()
                    // 只重置内存状态；学校请求仍由用户主动操作触发。
                    let schoolDataViewModels = SchoolDataViewModelStore.shared
                    schoolDataViewModels.scheduleViewModel.resetForCurrentAccount()
                    schoolDataViewModels.scoreViewModel.resetForCurrentAccount()
                    // 切换账号后，组件和灵动岛立即改读新账号的本地缓存。
                    refreshScheduleExternalDisplays(trigger: "login_storage_changed", syncWidgetSnapshot: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: .scheduleCacheDidChange)) { _ in
                    // 课表缓存变化时主要刷新 Live Activity；Widget 快照已在
                    // `ScheduleCacheStore.save` 时同步导出。
                    refreshScheduleExternalDisplays(trigger: "schedule_cache_changed", syncWidgetSnapshot: false)
                }
            #endif
        }
        #if !RELEASE_NETWORK_SMOKE
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // 回到前台时导出本地快照并刷新时间线；学校请求由用户显式操作触发。
                refreshScheduleExternalDisplays(trigger: "scene_active", syncWidgetSnapshot: true)
            }
        }
        #endif
    }
}
