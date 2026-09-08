import Foundation
import SwiftUI
import Combine

enum BIT101AppStore {
    nonisolated static let url = AppURL.required("https://apps.apple.com/cn/app/bit101/id6761147125")
}

/// App Store Lookup API 中与更新提醒有关的最小数据集。
struct AppStoreRelease: Codable, Equatable, Identifiable {
    let version: String
    let releaseNotes: String?
    let trackViewURL: URL?

    var id: String { version }

    var updateMessage: String {
        let notes = releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return notes.isEmpty ? "新版本已发布，建议前往 App Store 更新。" : notes
    }

    var appStoreURL: URL {
        if
            let trackViewURL,
            trackViewURL.host?.lowercased() == "apps.apple.com",
            trackViewURL.path.contains("id6761147125")
        {
            return trackViewURL
        }
        return BIT101AppStore.url
    }
}

private struct AppStoreLookupResponse: Decodable {
    struct Result: Decodable {
        let version: String
        let releaseNotes: String?
        let trackViewUrl: URL?
    }

    let results: [Result]
}

enum AppVersionComparison {
    /// App Store 公开版本号按数字段比较，`1.10` 按数值顺序位于 `1.9` 之后。
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        candidate.compare(installed, options: .numeric) == .orderedDescending
    }
}

/// App Store 更新检查器保存查询结果、忽略版本和展示冷却状态，并按 24 小时节流查询。
@MainActor
final class AppUpdateChecker {
    typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

    nonisolated static let queryInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let lastAttemptKey = "app.update-check.last-attempt"
    nonisolated static let cachedReleaseKey = "app.update-check.cached-release"
    nonisolated static let ignoredVersionKey = "app.update-check.ignored-version"
    nonisolated static let lastPresentedAtKey = "app.update-check.last-presented-at"
    nonisolated static let lastPresentedVersionKey = "app.update-check.last-presented-version"

    private static let lookupURL = AppURL.required("https://itunes.apple.com/lookup?id=6761147125&country=cn")

    private let defaults: UserDefaults
    private let now: () -> Date
    private let installedVersion: () -> String
    private let loadData: DataLoader

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        installedVersion: @escaping () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        },
        loadData: @escaping DataLoader = { request in
            let response = try await HTTPClient.shared.send(request, accepting: 100 ..< 600)
            return (response.data, response.response)
        }
    ) {
        self.defaults = defaults
        self.now = now
        self.installedVersion = installedVersion
        self.loadData = loadData

        #if DEBUG
        // 真机更新提醒 smoke 使用；显式传入启动环境变量时清除提醒门禁；Release 构建使用常规检查流程。
        if ProcessInfo.processInfo.environment["BIT101_UPDATE_PROMPT_SMOKE_RESET"] == "1" {
            [
                Self.lastAttemptKey,
                Self.cachedReleaseKey,
                Self.ignoredVersionKey,
                Self.lastPresentedAtKey,
                Self.lastPresentedVersionKey
            ].forEach(defaults.removeObject(forKey:))
        }
        #endif
    }

    /// 每次冷启动调用一次。联网查询与弹窗展示分别受 24 小时门禁控制。
    func releaseToPresentAtLaunch() async -> AppStoreRelease? {
        let currentDate = now()
        if let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date {
            let elapsed = currentDate.timeIntervalSince(lastAttempt)
            if elapsed >= 0, elapsed < Self.queryInterval {
                return eligibleRelease(from: cachedRelease())
            }
        }

        // 查询发起时立即记录时间，成功和失败结果都进入 24 小时查询门禁。
        defaults.set(currentDate, forKey: Self.lastAttemptKey)

        do {
            let release = try await fetchLatestRelease()
            if let encoded = try? JSONEncoder().encode(release) {
                defaults.set(encoded, forKey: Self.cachedReleaseKey)
            }
            return eligibleRelease(from: release)
        } catch {
            // 查询失败时启动流程继续；存在可信缓存时，流程继续使用缓存完成本地判断。
            return eligibleRelease(from: cachedRelease())
        }
    }

    func ignore(version: String) {
        defaults.set(version, forKey: Self.ignoredVersionKey)
    }

    /// 弹窗安排展示时立即记录时间和版本；各操作共用 24 小时展示冷却。
    func markPresented(version: String) {
        defaults.set(now(), forKey: Self.lastPresentedAtKey)
        defaults.set(version, forKey: Self.lastPresentedVersionKey)
    }

    private func fetchLatestRelease() async throws -> AppStoreRelease {
        // Apple Lookup CDN 可能按 User-Agent 返回已过期版本；每次受 24 小时门禁控制的
        // 查询追加唯一参数，配合缓存策略请求最新响应。
        var components = URLComponents(url: Self.lookupURL, resolvingAgainstBaseURL: false)
        let existingQueryItems = components?.queryItems ?? []
        components?.queryItems = existingQueryItems + [
            URLQueryItem(name: "requestTime", value: String(Int(now().timeIntervalSince1970)))
        ]
        guard let lookupURL = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(
            url: lookupURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await loadData(request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw URLError(.badServerResponse)
        }

        guard let result = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data).results.first else {
            throw URLError(.cannotParseResponse)
        }

        return AppStoreRelease(
            version: result.version,
            releaseNotes: result.releaseNotes,
            trackViewURL: result.trackViewUrl
        )
    }

    private func cachedRelease() -> AppStoreRelease? {
        guard let data = defaults.data(forKey: Self.cachedReleaseKey) else { return nil }
        return try? JSONDecoder().decode(AppStoreRelease.self, from: data)
    }

    private func eligibleRelease(from release: AppStoreRelease?) -> AppStoreRelease? {
        guard let release,
              AppVersionComparison.isNewer(release.version, than: installedVersion()),
              defaults.string(forKey: Self.ignoredVersionKey) != release.version,
              !wasRecentlyPresented(version: release.version)
        else {
            return nil
        }
        return release
    }

    private func wasRecentlyPresented(version: String) -> Bool {
        guard defaults.string(forKey: Self.lastPresentedVersionKey) == version,
              let presentedAt = defaults.object(forKey: Self.lastPresentedAtKey) as? Date
        else {
            return false
        }

        let elapsed = now().timeIntervalSince(presentedAt)
        return elapsed >= 0 && elapsed < Self.queryInterval
    }
}

/// 单个原生弹窗里的一个操作。
struct AppPromptAction: Identifiable {
    let id: String
    let title: String
    let role: ButtonRole?
    let isDefault: Bool
    let handler: @MainActor () -> Void

    init(
        id: String,
        title: String,
        role: ButtonRole? = nil,
        isDefault: Bool = false,
        handler: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.role = role
        self.isDefault = isDefault
        self.handler = handler
    }
}

/// 应用级原生弹窗请求。启动弹窗统一由同一个协调器展示。
struct AppPrompt: Identifiable {
    let id: String
    let title: String
    let message: String
    let actions: [AppPromptAction]
    let onPresent: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    init(
        id: String,
        title: String,
        message: String,
        actions: [AppPromptAction],
        onPresent: @escaping @MainActor () -> Void = {},
        onDismiss: @escaping @MainActor () -> Void = {}
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.actions = actions
        self.onPresent = onPresent
        self.onDismiss = onDismiss
    }
}

/// 应用级弹窗队列。SwiftUI 在同一时刻展示一个 `.alert`。
@MainActor
final class AppPromptCoordinator: ObservableObject {
    static let shared = AppPromptCoordinator()

    @Published private(set) var activePrompt: AppPrompt?

    private var queue: [AppPrompt] = []
    private var queuedIDs: Set<String> = []
    private var handledIDs: Set<String> = []
    private var advanceTask: Task<Void, Never>?
    private let advanceDelay: Duration

    init(advanceDelay: Duration = .milliseconds(350)) {
        self.advanceDelay = advanceDelay
    }

    func enqueue(_ prompt: AppPrompt) {
        guard activePrompt?.id != prompt.id,
              !queuedIDs.contains(prompt.id),
              !handledIDs.contains(prompt.id)
        else { return }

        queuedIDs.insert(prompt.id)
        queue.append(prompt)
        presentNextIfPossible()
    }

    func perform(_ action: AppPromptAction) {
        action.handler()
        finishActivePrompt()
    }

    /// 系统手势或其它系统级关闭路径同样必须推进队列。
    func alertPresentationChanged(isPresented: Bool) {
        if !isPresented {
            finishActivePrompt()
        }
    }

    private func finishActivePrompt() {
        guard let activePrompt else { return }
        activePrompt.onDismiss()
        handledIDs.insert(activePrompt.id)
        self.activePrompt = nil

        // 测试或动画已关闭的宿主显式关闭退场等待时，队列立即推进；队列行为直接由当前调用决定。
        if advanceDelay == .zero {
            presentNextIfPossible()
            return
        }

        // 等待系统完成上一条 alert 的退场动画，再交付下一项。
        advanceTask?.cancel()
        advanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: advanceDelay)
            guard !Task.isCancelled else { return }
            presentNextIfPossible()
        }
    }

    private func presentNextIfPossible() {
        guard activePrompt == nil, !queue.isEmpty else { return }
        let prompt = queue.removeFirst()
        queuedIDs.remove(prompt.id)
        activePrompt = prompt
        // 这一项成为唯一活动弹窗后，组件记录展示状态。
        prompt.onPresent()
    }
}

/// App 根节点统一管理更新查询状态，登录页和登录后壳层共用同一条查询流程。
@MainActor
final class AppUpdatePromptCoordinator {
    static let shared = AppUpdatePromptCoordinator()

    private let checker: AppUpdateChecker
    private let emergencyChecker: EmergencyUpdateChecker
    private var didCheckThisLaunch = false

    init(
        checker: AppUpdateChecker? = nil,
        emergencyChecker: EmergencyUpdateChecker? = nil
    ) {
        self.checker = checker ?? AppUpdateChecker()
        self.emergencyChecker = emergencyChecker ?? EmergencyUpdateChecker()
    }

    enum LaunchNotice {
        case emergency(EmergencyUpdateNotice)
        case appStore(AppStoreRelease)
    }

    /// 两项检查并行启动；紧急检查产生通知时交付紧急弹窗，其他结果交付 App Store 弹窗。
    func noticeToPresentAtLaunch() async -> LaunchNotice? {
        guard !didCheckThisLaunch else { return nil }
        didCheckThisLaunch = true

        let storeTask = Task { await checker.releaseToPresentAtLaunch() }
        if let emergency = await emergencyChecker.noticeToPresentAtLaunch() {
            storeTask.cancel()
            return .emergency(emergency)
        }
        return await storeTask.value.map(LaunchNotice.appStore)
    }

    func markPresented(version: String) {
        checker.markPresented(version: version)
    }

    func ignore(version: String) {
        checker.ignore(version: version)
    }

    func ignoreEmergencyForToday(noticeID: String) {
        emergencyChecker.ignoreForToday(noticeID: noticeID)
    }
}

private struct AppPromptHostModifier: ViewModifier {
    @Environment(\.openURL) private var openURL
    @StateObject private var promptCoordinator = AppPromptCoordinator.shared
    private let updateCoordinator = AppUpdatePromptCoordinator.shared

    func body(content: Content) -> some View {
        content
            .task {
                guard let notice = await updateCoordinator.noticeToPresentAtLaunch() else { return }
                switch notice {
                case let .emergency(emergency):
                    promptCoordinator.enqueue(AppPrompt(
                        id: "emergency-update-\(emergency.noticeID)",
                        title: emergency.title,
                        message: emergency.message,
                        actions: [
                            AppPromptAction(
                                id: "open-store",
                                title: "立即更新",
                                isDefault: true
                            ) {
                                openURL(emergency.safeUpdateURL)
                            },
                            AppPromptAction(id: "ignore-today", title: "今日忽略") {
                                updateCoordinator.ignoreEmergencyForToday(noticeID: emergency.noticeID)
                            }
                        ]
                    ))
                case let .appStore(release):
                    promptCoordinator.enqueue(AppPrompt(
                        id: "app-update-\(release.version)",
                        title: "发现新版本 \(release.version)",
                        message: release.updateMessage,
                        actions: [
                            AppPromptAction(
                                id: "open-store",
                                title: "前往 App Store",
                                isDefault: true
                            ) {
                                openURL(release.appStoreURL)
                            },
                            AppPromptAction(id: "dismiss", title: "本次忽略") {},
                            AppPromptAction(id: "ignore-version", title: "忽略此版本") {
                                updateCoordinator.ignore(version: release.version)
                            }
                        ],
                        onPresent: {
                            updateCoordinator.markPresented(version: release.version)
                        }
                    ))
                }
            }
            .alert(
                promptCoordinator.activePrompt?.title ?? "",
                isPresented: Binding(
                    get: { promptCoordinator.activePrompt != nil },
                    set: { promptCoordinator.alertPresentationChanged(isPresented: $0) }
                ),
                presenting: promptCoordinator.activePrompt
            ) {
                prompt in
                ForEach(prompt.actions) { action in
                    if action.isDefault {
                        Button(action.title, role: action.role) {
                            promptCoordinator.perform(action)
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button(action.title, role: action.role) {
                            promptCoordinator.perform(action)
                        }
                    }
                }
            } message: { prompt in
                Text(prompt.message)
            }
    }
}

extension View {
    func appPromptHost() -> some View {
        modifier(AppPromptHostModifier())
    }
}
