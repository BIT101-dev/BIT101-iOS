import Foundation
import SwiftUI
import Combine

enum BIT101AppStore {
    nonisolated static let url = URL(string: "https://apps.apple.com/cn/app/bit101/id6761147125")!
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
    /// App Store 公开版本号按数字段比较，避免把 `1.10` 错判为小于 `1.9`。
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        candidate.compare(installed, options: .numeric) == .orderedDescending
    }
}

/// 负责 24 小时查询节流、结果缓存以及“忽略本版本”持久化。
@MainActor
final class AppUpdateChecker {
    typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

    nonisolated static let queryInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let lastAttemptKey = "app.update-check.last-attempt"
    nonisolated static let cachedReleaseKey = "app.update-check.cached-release"
    nonisolated static let ignoredVersionKey = "app.update-check.ignored-version"
    nonisolated static let lastPresentedAtKey = "app.update-check.last-presented-at"
    nonisolated static let lastPresentedVersionKey = "app.update-check.last-presented-version"

    private static let lookupURL = URL(
        string: "https://itunes.apple.com/lookup?id=6761147125&country=cn"
    )!

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
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.defaults = defaults
        self.now = now
        self.installedVersion = installedVersion
        self.loadData = loadData

        #if DEBUG
        // 真机更新提醒 smoke 专用；仅显式传入启动环境变量时清除提醒门禁，Release 不包含。
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

        // 无论请求成功或失败都算一次查询，避免网络异常时每次启动反复请求 Apple。
        defaults.set(currentDate, forKey: Self.lastAttemptKey)

        do {
            let release = try await fetchLatestRelease()
            if let encoded = try? JSONEncoder().encode(release) {
                defaults.set(encoded, forKey: Self.cachedReleaseKey)
            }
            return eligibleRelease(from: release)
        } catch {
            // 查询失败不打断启动；若曾有可信缓存，仍可继续使用它进行纯本地判断。
            return eligibleRelease(from: cachedRelease())
        }
    }

    func ignore(version: String) {
        defaults.set(version, forKey: Self.ignoredVersionKey)
    }

    /// 在弹窗安排展示时立即记账，保证无论用户选择哪个按钮，24 小时内都不会再次出现。
    func markPresented(version: String) {
        defaults.set(now(), forKey: Self.lastPresentedAtKey)
        defaults.set(version, forKey: Self.lastPresentedVersionKey)
    }

    private func fetchLatestRelease() async throws -> AppStoreRelease {
        // Apple Lookup CDN 可能按 User-Agent 返回已过期版本；每次受 24 小时门禁控制的
        // 查询追加唯一参数，避免 CFNetwork 命中 CDN 中仍停留在上一版本的响应。
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

/// 应用级原生弹窗请求。所有启动弹窗只能经由同一个协调器展示。
struct AppPrompt: Identifiable {
    let id: String
    let title: String
    let message: String
    let actions: [AppPromptAction]
    let onPresent: @MainActor () -> Void

    init(
        id: String,
        title: String,
        message: String,
        actions: [AppPromptAction],
        onPresent: @escaping @MainActor () -> Void = {}
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.actions = actions
        self.onPresent = onPresent
    }
}

/// 应用唯一的弹窗队列，同一时刻只向 SwiftUI 提交一个 `.alert`。
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
        handledIDs.insert(activePrompt.id)
        self.activePrompt = nil

        // 测试或无动画宿主可以显式关闭退场等待；此时同步推进，避免把队列语义
        // 绑定到主线程任务何时获得调度。
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
        // 只有轮到这一项成为唯一活动弹窗时才记为已经展示。
        prompt.onPresent()
    }
}

/// 把查询状态收束在 App 根节点，避免登录页和登录后壳层各自重复请求。
@MainActor
final class AppUpdatePromptCoordinator {
    static let shared = AppUpdatePromptCoordinator()

    private let checker: AppUpdateChecker
    private var didCheckThisLaunch = false

    init(checker: AppUpdateChecker? = nil) {
        self.checker = checker ?? AppUpdateChecker()
    }

    func releaseToPresentAtLaunch() async -> AppStoreRelease? {
        guard !didCheckThisLaunch else { return nil }
        didCheckThisLaunch = true

        return await checker.releaseToPresentAtLaunch()
    }

    func markPresented(version: String) {
        checker.markPresented(version: version)
    }

    func ignore(version: String) {
        checker.ignore(version: version)
    }
}

private struct AppPromptHostModifier: ViewModifier {
    @Environment(\.openURL) private var openURL
    @StateObject private var promptCoordinator = AppPromptCoordinator.shared
    private let updateCoordinator = AppUpdatePromptCoordinator.shared

    func body(content: Content) -> some View {
        content
            .task {
                guard let release = await updateCoordinator.releaseToPresentAtLaunch() else { return }
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
