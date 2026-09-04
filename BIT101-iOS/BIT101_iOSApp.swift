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
/// 这里只负责复用页面状态，不在应用启动、回前台或切换账号时发起学校请求。
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
    /// 根据设置快照里的自动旋转选项，生成 UIKit 需要的方向掩码。
    ///
    /// iOS 最终认的是 `UIInterfaceOrientationMask`，而不是 SwiftUI 自己的某种抽象。
    /// 因此这里单独抽出一个转换函数，避免不同入口各自写一遍相同的条件判断。
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

    /// 将用户刚修改的自动旋转偏好立即同步给所有已连接的 window scene。
    ///
    /// 仅仅修改设置快照还不够；如果不主动调用 `requestGeometryUpdate`，
    /// 系统通常要等到下一次界面层级变化时才会重新评估方向能力。
    /// 这里遍历所有 scene 和 window，是为了保证主窗口、sheet 以及未来可能
    /// 出现的其它窗口场景都能收到新的方向约束。
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
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ScheduleReminderBackgroundRefresh.register()
        return true
    }

    /// 提供应用级的方向策略。
    ///
    /// SwiftUI App 生命周期下，大部分 UI 都由 SwiftUI 管，但方向能力的最终仲裁
    /// 仍然会回到 UIKit delegate。这里故意保持极简，只把请求转发给
    /// `AppOrientationController`，避免在 delegate 内部再持有一套重复状态。
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationController.currentMask()
    }
}

/// 课前提醒的后台刷新协调器。
///
/// 这条链路只是 best-effort：
/// - 由系统决定实际什么时候唤醒 app
/// - 唤醒后重新执行一遍日程提醒计算，尽量让灵动岛在后台也有机会启动
/// - 同时重新提交下一次刷新请求，维持后续链路
enum ScheduleReminderBackgroundRefresh {
    /// 后台刷新任务标识。
    ///
    /// 与 Info.plist 中的 `BGTaskSchedulerPermittedIdentifiers` 保持同源，避免切换 bundle id
    /// 或调试/正式包共存时出现 identifier 不一致。
    static var identifier: String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "BIT101-dev.BIT101-iOS"
        return "\(bundleIdentifier).schedule-refresh"
    }

    /// 在应用启动阶段注册后台刷新任务。
    ///
    /// Apple 要求所有 BGTask 都必须在启动序列结束前注册；因此这里放在
    /// `UIApplicationDelegate` 的 `didFinishLaunching` 里最稳妥。
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
    /// 一旦系统真的唤醒 app，这里就重新跑一遍提醒计算，并预排下一次后台刷新。
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

/// iOS 端应用入口。
///
/// 这里仅负责挂载根视图，并把全局主题设置注入到整个场景。
@main
struct BIT101_iOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// 全局设置单例，负责驱动主题模式、旋转等跨页面偏好。
    @StateObject private var settings = AppSettingsStore.shared
    /// 保留一个 UIKit delegate 入口，用于响应方向能力查询。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 把已有本地课表缓存同步到 Widget、Watch 和 Live Activity。
    ///
    /// 这条链路只读本地缓存，不访问学校/WebVPN；学校数据同步仍需用户显式操作。
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

    /// 根场景定义。
    ///
    /// 当前应用只有一个主窗口，主题模式直接由设置中心快照驱动。
    /// 另外，应用入口也是最适合放置“小组件/灵动岛与登录态、缓存变化保持同步”
    /// 的地方，因为这些副作用本质上都属于“全局应用状态发生变化”。
    var body: some Scene {
        WindowGroup {
            #if RELEASE_NETWORK_SMOKE
            // XCTest 会先启动测试宿主 App。冒烟模式不挂载正常业务 UI，避免登录校验、
            // 首页 `.task` 或未来新增的启动请求与顺序网络探针并发，污染耗时和结果。
            Color.clear
                .accessibilityIdentifier("release-network-smoke-host")
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
                    // 启动后先激活 WatchConnectivity，保证 watch 端发来的“重新同步”请求有人接。
                    WatchScheduleSyncManager.shared.activateIfNeeded()

                    // 启动时只导出本地缓存并刷新外部展示，不触发学校请求。
                    refreshScheduleExternalDisplays(trigger: "app_launch_task", syncWidgetSnapshot: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: .loginStorageDidChange)) { _ in
                    // 账号切换会让旧页面的请求和错误提示失去上下文，先清掉全局提示队列。
                    AppErrorPresenter.shared.reset()
                    // 只重置内存状态，不在切号时自动访问学校；下一次用户主动操作时再请求。
                    let schoolDataViewModels = SchoolDataViewModelStore.shared
                    schoolDataViewModels.scheduleViewModel.resetForCurrentAccount()
                    schoolDataViewModels.scoreViewModel.resetForCurrentAccount()
                    // 切换账号后，组件和灵动岛必须立即改读新账号的本地缓存。
                    refreshScheduleExternalDisplays(trigger: "login_storage_changed", syncWidgetSnapshot: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: .scheduleCacheDidChange)) { _ in
                    // 这里主要负责刷新 Live Activity。
                    // widget 快照本身已经在 `ScheduleCacheStore.save` 时同步导出了。
                    refreshScheduleExternalDisplays(trigger: "schedule_cache_changed", syncWidgetSnapshot: false)
                }
            #endif
        }
        #if !RELEASE_NETWORK_SMOKE
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // 回到前台时只重新导出本地快照与时间线，不触发学校请求。
                refreshScheduleExternalDisplays(trigger: "scene_active", syncWidgetSnapshot: true)
            }
        }
        #endif
    }
}
