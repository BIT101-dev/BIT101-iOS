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

/// 课表自动更新间隔设置。
///
/// `0` 表示关闭；其它值按自然日计算。该设置属于设备级偏好，而最近同步时间随课表
/// 缓存按账号隔离，因此切换账号不会串用另一位用户的更新时间。
enum ScheduleAutoRefreshPreferences {
    nonisolated static let intervalDaysKey = "schedule.auto-refresh.interval-days"
    nonisolated static let defaultIntervalDays = 7
    nonisolated static let availableIntervals = [0, 1, 3, 7, 14, 30]

    nonisolated static var intervalDays: Int {
        get {
            guard UserDefaults.standard.object(forKey: intervalDaysKey) != nil else {
                return defaultIntervalDays
            }
            return max(UserDefaults.standard.integer(forKey: intervalDaysKey), 0)
        }
        set {
            UserDefaults.standard.set(max(newValue, 0), forKey: intervalDaysKey)
        }
    }

    nonisolated static func title(for days: Int) -> String {
        days == 0 ? "关闭" : "每 \(days) 天"
    }
}

/// 登录后学校数据的统一前台预热协调器。
///
/// 不注册开机或系统后台任务，只在 App 启动、重新回到前台、切换账号时检查：
/// - 成绩：仅在第 16 周结束后的假期窗口内每天自动同步一次。
/// - DDL：保持每天首次进入时同步一次。
/// - 空教室：预热当前教学楼的数据，进入页面时可直接展示。
/// - 课表：仅达到用户设置的间隔后刷新；失败通过壳层统一提示。
@MainActor
final class SchoolDataRefreshCoordinator: ObservableObject {
    static let shared = SchoolDataRefreshCoordinator()

    let scheduleViewModel = ScheduleViewModel()
    let scoreViewModel = ScoreViewModel()
    @Published var alert: AppAlert?

    private let ddlAttemptKeyPrefix = "schedule.ddl.silent-refresh.last-attempt"
    private let courseAttemptKeyPrefix = "schedule.courses.auto-refresh.last-attempt"
    private let scoreAttemptKeyPrefix = "score.auto-refresh.last-attempt"
    private var activeTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var activeStudentID = ""

    private init() {}

    func refreshOnEntry(trigger: String) {
        #if RELEASE_NETWORK_SMOKE
        // 专用冒烟测试会自行顺序调用真实业务服务；避免 App 生命周期预热并发发起同一批请求。
        _ = trigger
        #else
        let studentID = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let fakeCookie = LoginStorage.shared.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !studentID.isEmpty, !fakeCookie.isEmpty else { return }

        if activeStudentID != studentID {
            activeTask?.cancel()
            activeTask = nil
            activeRunID = nil
            activeStudentID = studentID
            scheduleViewModel.resetForCurrentAccount()
            scoreViewModel.resetForCurrentAccount()
        }
        guard activeTask == nil else { return }

        let runID = UUID()
        activeRunID = runID
        activeTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if activeRunID == runID {
                    activeTask = nil
                    activeRunID = nil
                }
            }

            await scheduleViewModel.loadIfNeeded()

            let initialPhase = AcademicTermPolicy.activityPhase(
                cache: scheduleViewModel.cache,
                on: Date()
            )
            async let classroomRefresh: Void = refreshClassroomIfNeeded(during: initialPhase)
            async let ddlRefresh: Void = refreshDDLIfNeeded(studentID: studentID, during: initialPhase)
            await refreshCoursesIfNeeded(during: initialPhase)
            await refreshScoresIfNeeded(studentID: studentID)
            _ = await (classroomRefresh, ddlRefresh)
            _ = trigger
        }
        #endif
    }

    private func refreshScoresIfNeeded(studentID: String) async {
        let now = Date()
        guard ScoreAutomaticRefreshPolicy.isWithinRefreshWindow(
            cache: scheduleViewModel.cache,
            now: now
        ) else { return }

        let key = "\(scoreAttemptKeyPrefix).\(studentID)"
        if let lastAttempt = UserDefaults.standard.object(forKey: key) as? Date,
           Calendar.current.isDate(lastAttempt, inSameDayAs: now)
        {
            return
        }
        // Record the attempt before starting authentication so repeated launches
        // cannot create duplicate server work or repeated SMS challenges.
        UserDefaults.standard.set(now, forKey: key)
        await scoreViewModel.bootstrapIfNeeded()
    }

    private func refreshClassroomIfNeeded(during phase: AcademicActivityPhase) async {
        guard phase != .vacation else { return }
        await scheduleViewModel.prepareClassroomIfNeeded(showErrors: false)
    }

    private func refreshDDLIfNeeded(studentID: String, during phase: AcademicActivityPhase) async {
        guard phase != .vacation else { return }
        let cache = scheduleViewModel.cache
        let hasLexueSyncHistory =
            !cache.lexueCalendarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            cache.ddlEvents.contains(where: { $0.group == "lexue" })
        guard hasLexueSyncHistory else { return }

        let key = "\(ddlAttemptKeyPrefix).\(studentID)"
        let calendar = Calendar.current
        if let lastAttempt = UserDefaults.standard.object(forKey: key) as? Date,
           calendar.isDate(lastAttempt, inSameDayAs: Date()) {
            return
        }
        UserDefaults.standard.set(Date(), forKey: key)
        _ = await scheduleViewModel.syncDDL(showSuccessNotice: false, showErrorNotice: false)
    }

    private func refreshCoursesIfNeeded(during phase: AcademicActivityPhase) async {
        let intervalDays = ScheduleAutoRefreshPreferences.intervalDays
        let cache = scheduleViewModel.cache
        let hasExistingSchedule = !cache.currentTerm.isEmpty || !cache.courses.isEmpty
        guard hasExistingSchedule else { return }

        let now = Date()
        let adjacentTerms = AcademicTermPolicy.adjacentTerms(on: now)
        let targetTerm: String
        let dueDate: Date

        if phase == .vacation, let nextTerm = adjacentTerms.dropFirst().first {
            targetTerm = nextTerm
            let snapshot = cache.termSchedulesByTerm[nextTerm]
            let nextStart = snapshot?.firstDay ?? AcademicTermPolicy.nextBoundary(after: now)
            let daysUntilStart = Calendar.current.dateComponents([.day], from: now, to: nextStart).day ?? 99
            // Weekly during the vacation, then daily in the final two weeks while
            // schools are most likely to publish or adjust the new timetable.
            let retryDays = daysUntilStart <= 14 ? 1 : 7
            dueDate = Calendar.current.date(
                byAdding: .day,
                value: retryDays,
                to: snapshot?.updatedAt ?? .distantPast
            ) ?? .distantPast
            if snapshot?.hasDisplayableData == true, now < nextStart {
                return
            }
        } else {
            targetTerm = AcademicTermPolicy.preferredCachedTerm(cache: cache, on: now)
            let targetSnapshot = cache.termSchedulesByTerm[targetTerm]
            let needsTermTransition = cache.currentTerm != targetTerm
                && targetSnapshot?.hasDisplayableData != true
            guard intervalDays > 0 || needsTermTransition else { return }
            let retryDays = needsTermTransition ? 1 : intervalDays
            let snapshotUpdatedAt = targetSnapshot?.updatedAt ?? cache.coursesUpdatedAt
            dueDate = Calendar.current.date(
                byAdding: .day,
                value: retryDays,
                to: snapshotUpdatedAt
            ) ?? .distantPast
        }
        guard now >= dueDate else { return }

        let studentID = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let attemptKey = "\(courseAttemptKeyPrefix).\(studentID)"
        if let lastAttempt = UserDefaults.standard.object(forKey: attemptKey) as? Date,
           Calendar.current.isDate(lastAttempt, inSameDayAs: now) {
            return
        }
        UserDefaults.standard.set(now, forKey: attemptKey)

        if let failure = await scheduleViewModel.autoRefreshCourses(terms: [targetTerm]) {
            alert = AppAlert(title: failure.title, message: failure.message)
        }
    }
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
    @StateObject private var schoolDataRefresh = SchoolDataRefreshCoordinator.shared
    /// 保留一个 UIKit delegate 入口，用于响应方向能力查询。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 统一触发“共享课表快照 + Live Activity 刷新”。
    ///
    /// 只有在启动和切号这两类场景里，主 app 才需要显式把课表缓存再导出一遍；
    /// 其它常规课表写回路径会在 `ScheduleCacheStore.save` 内部自己完成共享快照导出。
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

    private func refreshScheduleCloudSyncIfNeeded(trigger: String) {
        #if RELEASE_NETWORK_SMOKE
        _ = trigger
        #else
        #if canImport(CloudKit)
        Task {
            await ScheduleCloudSyncManager.shared.refreshFromCloudIfNeeded()
            await MainActor.run {
                ExperimentalPreferenceCloudSync.shared.refreshFromCloudIfNeeded()
            }
            _ = trigger
        }
        #endif
        #endif
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

                    // 启动时补做一次导出与提醒刷新，保证外部展示拿到的是当前账号的最新缓存。
                    refreshScheduleExternalDisplays(trigger: "app_launch_task", syncWidgetSnapshot: true)
                    refreshScheduleCloudSyncIfNeeded(trigger: "app_launch_task")
                    schoolDataRefresh.refreshOnEntry(trigger: "app_launch_task")
                }
                .onReceive(NotificationCenter.default.publisher(for: .loginStorageDidChange)) { _ in
                    // 切换账号后，组件和灵动岛必须立即改读新账号的缓存。
                    refreshScheduleExternalDisplays(trigger: "login_storage_changed", syncWidgetSnapshot: true)
                    refreshScheduleCloudSyncIfNeeded(trigger: "login_storage_changed")
                    schoolDataRefresh.refreshOnEntry(trigger: "login_storage_changed")
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
                // 应用重新回到前台时，同时补做一次 widget 快照导出与时间线刷新。
                // 否则即便用户主动打开 app，桌面/锁屏小组件也可能继续沿用后台停留期间的旧条目。
                refreshScheduleExternalDisplays(trigger: "scene_active", syncWidgetSnapshot: true)
                refreshScheduleCloudSyncIfNeeded(trigger: "scene_active")
                schoolDataRefresh.refreshOnEntry(trigger: "scene_active")
            }
        }
        #endif
    }
}

// MARK: - Release network smoke

#if DEBUG || RELEASE_NETWORK_SMOKE

/// 发布前网络冒烟的范围。
///
/// 这里与脚本入口保持同名同义，方便正式 App、测试宿主和命令行脚本复用同一套探针。
enum NetworkSmokeScope: String, Codable {
    case all
    case bit101
    case school
    case transcript
    case schedule

    func includes(_ name: String) -> Bool {
        switch self {
        case .all:
            return true
        case .bit101:
            return name == "BIT101 登录状态"
                || name.hasPrefix("话廊")
                || name.hasPrefix("社区")
                || name.hasPrefix("消息")
                || name.hasPrefix("用户")
                || name.hasPrefix("学业")
                || name.hasPrefix("文章")
                || name.hasPrefix("我的")
                || name.hasPrefix("App Store")
                || name.hasPrefix("紧急更新")
        case .school:
            return name == "BIT101 登录状态"
                || name.hasPrefix("切换学期")
                || name.hasPrefix("课表")
                || name.hasPrefix("空教室")
                || name.hasPrefix("乐学")
                || name.hasPrefix("成绩")
                || name.hasPrefix("可信成绩单")
        case .transcript:
            return name == "可信成绩单接口"
        case .schedule:
            return name == "BIT101 登录状态"
                || name == "当前学期"
                || name == "切换学期列表"
                || name == "课表、考试与首周同步"
        }
    }
}

/// 冒烟结果的持久化报告。
struct ReleaseNetworkSmokeReport: Codable {
    let runID: String
    let scope: NetworkSmokeScope
    let startedAt: Date
    let finishedAt: Date
    let passed: Bool
    let failures: [String]
    let authenticationBlockers: [String]

    var elapsed: TimeInterval {
        finishedAt.timeIntervalSince(startedAt)
    }

    var summaryLine: String {
        "NETWORK_SMOKE_SUMMARY run_id=\(runID) scope=\(scope.rawValue) passed=\(passed) failures=\(failures.count) auth_blocked=\(authenticationBlockers.count) elapsed=\(Self.duration(elapsed))"
    }

    var failureMessage: String {
        let failureSection = failures.isEmpty ? "" : "\n网络或业务失败：\n" + failures.joined(separator: "\n")
        let authenticationSection = authenticationBlockers.isEmpty ? "" : "\n需要人工认证，相关路径尚未完成验证：\n" + authenticationBlockers.joined(separator: "\n")
        return "发布前网络冒烟测试未完全通过：" + failureSection + authenticationSection
    }

    private static func duration(_ interval: TimeInterval) -> String {
        String(format: "%.2fs", interval)
    }
}

/// 冒烟报告的本地落盘位置。
enum ReleaseNetworkSmokeReportStore {
    private static let directoryName = "NetworkSmoke"
    private static let filePrefix = "release-network-smoke"

    static func fileURL(runID: String) -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ScheduleSharedContainer.identifier
        ) else {
            return nil
        }

        return containerURL
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: "\(filePrefix)-\(runID).json")
    }

    static func write(_ report: ReleaseNetworkSmokeReport) throws {
        guard let fileURL = fileURL(runID: report.runID) else {
            throw ScheduleExternalSnapshotStoreError.sharedContainerUnavailable
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// `bit101://network-smoke/...` 触发参数。
struct ReleaseNetworkSmokeLaunchRequest {
    let scope: NetworkSmokeScope
    let runID: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == "bit101",
              url.host?.lowercased() == "network-smoke"
        else { return nil }

        let pathScope = url.pathComponents
            .filter { $0 != "/" }
            .first
            .flatMap(NetworkSmokeScope.init(rawValue:))
            ?? .all

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let runID = components?.queryItems?.first(where: { $0.name == "run" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        self.scope = pathScope
        if let runID, !runID.isEmpty {
            self.runID = runID
        } else {
            self.runID = UUID().uuidString
        }
    }
}

/// 发布前网络冒烟执行器。
///
/// 这份实现同时服务于：
/// - 真机上的正式 App：通过 `bit101://network-smoke/...` 在当前进程内复用会话执行；
/// - XCTest：保留一个直接调用入口，方便回归和未来 CI 复用同一组探针。
@MainActor
final class ReleaseNetworkSmokeRunner {
    private var failures: [String] = []
    private var authenticationBlockers: [String] = []

    func run(scope: NetworkSmokeScope, runID: String = UUID().uuidString) async -> ReleaseNetworkSmokeReport {
        failures = []
        authenticationBlockers = []
        let startedAt = Date()

        let loginStartedAt = Date()
        do {
            let loginResult = try await LoginService().checkLogin()
            guard let signedInStudentID = loginResult, !signedInStudentID.isEmpty else {
                recordFailure("BIT101 登录状态", "真机没有有效登录状态，无法执行发布前网络冒烟测试", scope: scope)
                return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
            }
            print("NETWORK_SMOKE_PASS name=BIT101 登录状态 elapsed=\(Self.duration(Date().timeIntervalSince(loginStartedAt)))")
            _ = signedInStudentID
        } catch {
            recordFailure("BIT101 登录状态", error.localizedDescription, scope: scope, elapsed: Date().timeIntervalSince(loginStartedAt))
            return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
        }

        let gallery = GalleryService()
        let posters = await probe("话廊最新列表", scope: scope) {
            try await gallery.fetchFeed(kind: .newest, page: nil)
        } ?? []
        if let poster = posters.first {
            _ = await probe("话廊帖子详情", scope: scope) {
                try await gallery.fetchPoster(id: poster.id)
            }
            _ = await probe("话廊帖子评论", scope: scope) {
                try await gallery.fetchComments(
                    objectID: "poster\(poster.id)",
                    order: .newest,
                    page: nil
                )
            }
            if let image = poster.images.first ?? Optional(poster.user.avatar) {
                _ = await probe("话廊图片下载", scope: scope) {
                    try await Self.download(urlString: image.lowUrl.isEmpty ? image.url : image.lowUrl)
                }
            }
            _ = await probe("话廊网页详情", scope: scope) {
                try await Self.fetchWebPage("https://open.aihelpme.dev/gallery/\(poster.id)")
            }
        } else {
            recordFailure("话廊最新列表", "服务器返回空列表，无法继续验证详情与图片", scope: scope)
        }
        _ = await probe("话廊推荐流", scope: scope) { try await gallery.fetchRecommendPage(sourcePage: 0) }
        _ = await probe("话廊机器人流", scope: scope) { try await gallery.fetchBotFeed(startPage: 0) }
        _ = await probe("社区举报类型", scope: scope) { try await gallery.fetchClaims() }
        _ = await probe("话廊搜索", scope: scope) {
            try await gallery.searchPosters(query: GallerySearchQuery(text: "BIT101"), page: 0)
        }
        _ = await probe("消息未读数", scope: scope) {
            try await gallery.fetchMessageUnreadCounts()
        }
        for messageType in GalleryMessageType.allCases {
            _ = await probe("消息列表-\(messageType.rawValue)", scope: scope) {
                try await gallery.fetchMessages(type: messageType, lastID: nil)
            }
        }

        let courses = CourseService()
        let courseRows = await probe("学业课程列表", scope: scope) {
            try await courses.fetchCourses(search: "", page: 0)
        } ?? []
        if let course = courseRows.first {
            _ = await probe("学业课程详情", scope: scope) {
                try await courses.fetchCourse(id: course.id)
            }
            _ = await probe("学业课程评论", scope: scope) {
                try await courses.fetchComments(courseID: course.id, page: nil)
            }
            _ = await probe("学业课程历史成绩", scope: scope) {
                try await courses.fetchCourseHistories(number: course.number)
            }
            _ = await probe("学业课程网页详情", scope: scope) {
                try await Self.fetchWebPage("https://open.aihelpme.dev/course/\(course.id)")
            }
        } else {
            recordFailure("学业课程列表", "服务器返回空列表，无法继续验证课程详情", scope: scope)
        }

        let papers = PaperService()
        let paperRows = await probe("文章列表", scope: scope) {
            try await papers.fetchPapers(search: nil, order: .newest, page: 0)
        } ?? []
        if let paper = paperRows.first {
            _ = await probe("文章详情", scope: scope) {
                try await papers.fetchPaper(id: paper.id)
            }
            _ = await probe("文章评论", scope: scope) {
                try await papers.fetchComments(paperID: paper.id, order: .newest, page: nil)
            }
        } else {
            recordFailure("文章列表", "服务器返回空列表，无法继续验证文章详情", scope: scope)
        }
        for order in PaperSortOrder.allCases {
            _ = await probe("文章列表-\(order.title)", scope: scope) {
                try await papers.fetchPapers(search: "BIT101", order: order, page: 0)
            }
        }

        let mine = MineService()
        let myInfo = await probe("我的资料", scope: scope) { try await mine.fetchMyInfo() }
        _ = await probe("我的关注", scope: scope) { try await mine.fetchFollowings(page: 0) }
        _ = await probe("我的粉丝", scope: scope) { try await mine.fetchFollowers(page: 0) }
        _ = await probe("我的帖子", scope: scope) { try await mine.fetchMyPosters(page: 0) }
        if let myInfo {
            _ = await probe("用户资料详情", scope: scope) { try await mine.fetchUserInfo(id: myInfo.user.id) }
            _ = await probe("用户帖子", scope: scope) { try await mine.fetchUserPosters(userID: myInfo.user.id, page: 0) }
        }

        // 可信成绩单最容易受当前会话状态影响，因此放在学校链路最前面，尽量贴近
        // 用户手动点“申请可信成绩单”时的行为。
        let scoreService = ScoreService()
        _ = await probe("可信成绩单接口", scope: scope) {
            try await scoreService.fetchTrustedTranscriptPages()
        }

        let schedule = ScheduleService()
        _ = await probe("当前学期", scope: scope) { try await schedule.fetchCurrentTermOnly() }
        let terms = await probe("切换学期列表", scope: scope) {
            try await schedule.fetchAvailableTerms()
        } ?? []
        if let term = terms.first {
            _ = await probe("课表、考试与首周同步", scope: scope) {
                try await schedule.syncCourses(term: term)
            }

            let campuses = await probe("空教室校区列表", scope: scope) {
                try await schedule.fetchCampuses()
            } ?? []
            if let campus = campuses.first {
                let buildings = await probe("空教室教学楼列表", scope: scope) {
                    try await schedule.fetchBuildings(campusCode: campus.code)
                } ?? []
                if let building = buildings.first {
                    _ = await probe("空教室占用数据", scope: scope) {
                        try await schedule.fetchClassrooms(buildingID: building.id, term: term)
                    }
                } else {
                    recordFailure("空教室教学楼列表", "服务器返回空列表", scope: scope)
                }
            } else {
                recordFailure("空教室校区列表", "服务器返回空列表", scope: scope)
            }
        } else {
            recordFailure("切换学期列表", "服务器返回空列表，无法继续验证课表与空教室", scope: scope)
        }

        let calendarURL = await probe("乐学日历订阅地址", scope: scope) {
            try await schedule.refreshLexueCalendarURL()
        }
        if let calendarURL {
            _ = await probe("乐学 DDL 下载", scope: scope) {
                try await schedule.syncDDLEvents(existingEvents: [], storedURL: calendarURL)
            }
        }

        // 成绩页与可信成绩单同样属于学校网络链路；短信二次验证时记录为
        // AUTH_BLOCKED，而不是误判为网络故障。
        let scoreChallenge = await probe("成绩认证接口", scope: scope) {
            try await scoreService.startScoreChallenge()
        }
        if let scoreChallenge {
            _ = await probe("成绩简略列表", scope: scope) {
                try await scoreService.fetchScores(detail: false, authenticatedBy: scoreChallenge)
            }
            _ = await probe("成绩详细列表", scope: scope) {
                try await scoreService.fetchScores(detail: true, authenticatedBy: scoreChallenge)
            }
        }

        _ = await probe("App Store 更新接口", scope: scope) {
            try await Self.fetchWebPage("https://itunes.apple.com/lookup?id=6761147125&country=cn")
        }
        _ = await probe("紧急更新配置接口", scope: scope) {
            try await Self.fetchWebPage(
                "https://update.aihelpme.dev/emergency-update.json"
            )
        }

        return await finishReport(runID: runID, scope: scope, startedAt: startedAt)
    }

    private func finishReport(runID: String, scope: NetworkSmokeScope, startedAt: Date) async -> ReleaseNetworkSmokeReport {
        let report = ReleaseNetworkSmokeReport(
            runID: runID,
            scope: scope,
            startedAt: startedAt,
            finishedAt: Date(),
            passed: failures.isEmpty && authenticationBlockers.isEmpty,
            failures: failures,
            authenticationBlockers: authenticationBlockers
        )
        print(report.summaryLine)
        if !report.passed {
            print(report.failureMessage)
        }
        try? ReleaseNetworkSmokeReportStore.write(report)
        return report
    }

    private func probe<Value>(
        _ name: String,
        scope: NetworkSmokeScope,
        operation: () async throws -> Value
    ) async -> Value? {
        guard scope.includes(name) else {
            print("NETWORK_SMOKE_SKIP name=\(name) scope=\(scope.rawValue)")
            return nil
        }
        let startedAt = Date()
        do {
            let value = try await operation()
            print("NETWORK_SMOKE_PASS name=\(name) elapsed=\(Self.duration(Date().timeIntervalSince(startedAt)))")
            return value
        } catch {
            let elapsed = Date().timeIntervalSince(startedAt)
            if Self.isAuthenticationBlocked(error) {
                recordAuthenticationBlocker(name, error.localizedDescription, scope: scope, elapsed: elapsed)
            } else {
                recordFailure(name, error.localizedDescription, scope: scope, elapsed: elapsed)
            }
            return nil
        }
    }

    private func recordFailure(_ name: String, _ message: String, scope: NetworkSmokeScope, elapsed: TimeInterval? = nil) {
        guard scope.includes(name) else { return }
        let timing = elapsed.map { " elapsed=\(Self.duration($0))" } ?? ""
        let line = "[\(name)] \(message)\(timing)"
        failures.append(line)
        print("NETWORK_SMOKE_FAIL \(line)")
    }

    private func recordAuthenticationBlocker(
        _ name: String,
        _ message: String,
        scope: NetworkSmokeScope,
        elapsed: TimeInterval
    ) {
        guard scope.includes(name) else { return }
        let line = "[\(name)] \(message) elapsed=\(Self.duration(elapsed))"
        authenticationBlockers.append(line)
        print("NETWORK_SMOKE_AUTH_BLOCKED \(line)")
    }

    private nonisolated static func isAuthenticationBlocked(_ error: Error) -> Bool {
        switch error {
        case ScheduleServiceError.secondFactorRequired,
             ScheduleServiceError.schoolSecondFactorRequired,
             ScoreServiceError.secondFactorRequired:
            return true
        default:
            return false
        }
    }

    private nonisolated static func download(urlString: String) async throws -> Int {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        return try await fetch(url).count
    }

    private nonisolated static func fetchWebPage(_ urlString: String) async throws -> Int {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        return try await fetch(url).count
    }

    private nonisolated static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("BIT101-iOS release network smoke", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 400).contains(httpResponse.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }
        return data
    }

    private nonisolated static func duration(_ interval: TimeInterval) -> String {
        String(format: "%.2fs", interval)
    }
}

#endif
