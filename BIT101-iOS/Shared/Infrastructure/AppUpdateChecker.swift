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
        var request = URLRequest(
            url: Self.lookupURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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

/// 把查询状态收束在 App 根节点，避免登录页和登录后壳层各自重复请求。
@MainActor
final class AppUpdatePromptCoordinator: ObservableObject {
    static let shared = AppUpdatePromptCoordinator()

    @Published private(set) var release: AppStoreRelease?
    @Published var isShowingPrompt = false

    private let checker: AppUpdateChecker
    private var didCheckThisLaunch = false

    init(checker: AppUpdateChecker? = nil) {
        self.checker = checker ?? AppUpdateChecker()
    }

    func checkAtLaunch() async {
        guard !didCheckThisLaunch else { return }
        didCheckThisLaunch = true

        guard let release = await checker.releaseToPresentAtLaunch() else { return }
        self.release = release
        checker.markPresented(version: release.version)
        isShowingPrompt = true
    }

    func dismissPrompt() {
        isShowingPrompt = false
    }

    func ignorePresentedVersion() {
        guard let version = release?.version else { return }
        checker.ignore(version: version)
        isShowingPrompt = false
    }
}

private struct AppUpdatePromptModifier: ViewModifier {
    @Environment(\.openURL) private var openURL
    @StateObject private var coordinator = AppUpdatePromptCoordinator.shared

    func body(content: Content) -> some View {
        content
            .task {
                await coordinator.checkAtLaunch()
            }
            .alert(
                "发现新版本 \(coordinator.release?.version ?? "")",
                isPresented: $coordinator.isShowingPrompt
            ) {
                Button("前往 App Store") {
                    coordinator.dismissPrompt()
                    if let url = coordinator.release?.appStoreURL {
                        openURL(url)
                    }
                }
                .keyboardShortcut(.defaultAction)
                Button("本次忽略") {
                    coordinator.dismissPrompt()
                }
                Button("忽略此版本") {
                    coordinator.ignorePresentedVersion()
                }
            } message: {
                Text(coordinator.release?.updateMessage ?? "")
            }
    }
}

extension View {
    func appUpdatePrompt() -> some View {
        modifier(AppUpdatePromptModifier())
    }
}
