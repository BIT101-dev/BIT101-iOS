import TransportCore
import DesignSystemKit
import Foundation
import Combine
import Network

struct NetworkConnectionSnapshot: Equatable, Sendable {
    let summary: String
    let virtualNetworkLikely: Bool
}

@MainActor
protocol NetworkPathProviding: AnyObject {
    var snapshot: NetworkConnectionSnapshot { get }
}

@MainActor
final class NetworkMagicWarningCenter {
    static let shared = NetworkMagicWarningCenter()

    private let pathProvider: any NetworkPathProviding
    private let promptCoordinator: AppPromptCoordinator?
    private let errorPresenter: AppErrorPresenter?
    private let now: () -> Date
    private let cooldown: TimeInterval
    private var lastShownAtByScope: [String: Date] = [:]
    private var lastPathSummaryByScope: [String: String] = [:]
    private var activeWarningTask: Task<Void, Never>?

    init(
        pathProvider: (any NetworkPathProviding)? = nil,
        promptCoordinator: AppPromptCoordinator? = nil,
        now: @escaping () -> Date = Date.init,
        cooldown: TimeInterval = 10 * 60
    ) {
        self.pathProvider = pathProvider ?? NetworkConnectionDescription.shared
        self.promptCoordinator = promptCoordinator
        self.errorPresenter = AppErrorPresenter.shared
        self.now = now
        self.cooldown = cooldown
    }

    init(
        pathProvider: (any NetworkPathProviding)?,
        promptCoordinator: AppPromptCoordinator?,
        errorPresenter: AppErrorPresenter?,
        now: @escaping () -> Date = Date.init,
        cooldown: TimeInterval = 10 * 60
    ) {
        self.pathProvider = pathProvider ?? NetworkConnectionDescription.shared
        self.promptCoordinator = promptCoordinator
        self.errorPresenter = errorPresenter
        self.now = now
        self.cooldown = cooldown
    }

    func consider(url: URL?) async -> Bool {
        guard let host = url?.host?.lowercased(), !Self.isBIT101Host(host) else { return false }
        if let activeWarningTask {
            await activeWarningTask.value
        }
        let snapshot = pathProvider.snapshot
        guard snapshot.virtualNetworkLikely else { return false }

        let scope = Self.isSchoolHost(host) ? "school" : "external"
        let currentDate = now()
        let pathChanged = snapshot.summary != lastPathSummaryByScope[scope]
        let cooldownExpired = lastShownAtByScope[scope].map {
            currentDate.timeIntervalSince($0) >= cooldown
        } ?? true
        guard pathChanged || cooldownExpired else { return false }

        let prompt = AppPrompt(
            id: "network-magic-\(UUID().uuidString)",
            title: "检测到可能在使用魔法",
            message: "关闭食用效果更佳～",
            actions: [
                AppPromptAction(id: "dismiss", title: "知道了", isDefault: true) {}
            ]
        )
#if RELEASE_NETWORK_SMOKE
        lastPathSummaryByScope[scope] = snapshot.summary
        lastShownAtByScope[scope] = currentDate
        promptCoordinator?.enqueue(prompt)
#else
        if let promptCoordinator {
            guard promptCoordinator.isHostReady else { return false }
        } else if errorPresenter == nil {
            return false
        }
        lastPathSummaryByScope[scope] = snapshot.summary
        lastShownAtByScope[scope] = currentDate
        let dismissalTask = Task { @MainActor in
            if let promptCoordinator {
                await promptCoordinator.enqueueAndWait(prompt)
            } else if let errorPresenter {
                await errorPresenter.presentAndWait(AppAlert(
                    title: prompt.title,
                    message: prompt.message,
                    allowsDiagnostics: false,
                    showsRecoveryLinks: false
                ))
            }
        }
        activeWarningTask = dismissalTask
        await dismissalTask.value
        activeWarningTask = nil
#endif
        return true
    }

    static func isBIT101Host(_ host: String) -> Bool {
        host == "bit101.cn"
            || host.hasSuffix(".bit101.cn")
            || host == "aihelpme.dev"
            || host.hasSuffix(".aihelpme.dev")
            || host == "bit101.flwfdd.xyz"
            || host.hasSuffix(".bit101.flwfdd.xyz")
    }

    static func isSchoolHost(_ host: String) -> Bool {
        host == "bit.edu.cn" || host.hasSuffix(".bit.edu.cn")
    }
}

@MainActor
final class NetworkConnectionDescription: NetworkPathProviding {
    static let shared = NetworkConnectionDescription()
    private let monitor = NWPathMonitor()
    private var value = "检测中"
    private var virtualNetworkLikely = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            var seenInterfaces = Set<String>()
            let interfaces = path.availableInterfaces
                .map(Self.label(for:))
                .filter { seenInterfaces.insert($0).inserted }
            let description: String
            if path.status != .satisfied {
                description = "未连接"
            } else if interfaces.isEmpty {
                description = "已连接"
            } else {
                description = "已连接 · " + interfaces.joined(separator: " + ")
            }
            Task { @MainActor [weak self] in
                self?.value = description
                self?.virtualNetworkLikely = path.usesInterfaceType(.other)
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.aihelpme.bit101.network-report"))
    }

    var current: String {
        snapshot.summary
    }

    var snapshot: NetworkConnectionSnapshot {
        let cached = makeSnapshot()
        let livePath = monitor.currentPath
        guard livePath.status != .requiresConnection else { return cached }
        return Self.snapshot(for: livePath)
    }

    private func makeSnapshot() -> NetworkConnectionSnapshot {
        NetworkConnectionSnapshot(summary: value, virtualNetworkLikely: virtualNetworkLikely)
    }

    private nonisolated static func snapshot(for path: NWPath) -> NetworkConnectionSnapshot {
        var seenInterfaces = Set<String>()
        let interfaces = path.availableInterfaces
            .map(label(for:))
            .filter { seenInterfaces.insert($0).inserted }
        let summary: String
        if path.status != .satisfied {
            summary = "未连接"
        } else if interfaces.isEmpty {
            summary = "已连接"
        } else {
            summary = "已连接 · " + interfaces.joined(separator: " + ")
        }
        return NetworkConnectionSnapshot(
            summary: summary,
            virtualNetworkLikely: path.usesInterfaceType(.other)
        )
    }

    private nonisolated static func label(for interface: NWInterface) -> String {
        switch interface.type {
        case .wifi: return "Wi‑Fi"
        case .cellular: return "蜂窝网络"
        case .wiredEthernet: return "有线网络"
        case .other: return "虚拟/未知接口"
        case .loopback: return "回环接口"
        @unknown default: return "其他接口"
        }
    }
}

struct NetworkDiagnosticRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let occurredAt: Date
    let method: String
    let url: String
    let statusCode: Int?
    let elapsedMilliseconds: Int
    let error: String?
    let responseHeaders: [String: String]
    let responseBody: String?
}

actor NetworkDiagnosticStore {
    static let shared = NetworkDiagnosticStore()
    private var records: [NetworkDiagnosticRecord] = []

    func record(request: URLRequest, data: Data?, response: URLResponse?, error: Error?, elapsed: TimeInterval) {
        guard request.url?.host?.lowercased() != "feedback.aihelpme.dev" else { return }
        let http = response as? HTTPURLResponse
        let headers = http?.allHeaderFields.reduce(into: [String: String]()) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        } ?? [:]
        let body = data.flatMap { data -> String? in
            let limited = data.prefix(256 * 1024)
            return String(data: limited, encoding: .utf8) ?? "[非文本响应，\(data.count) 字节]"
        }
        records.append(NetworkDiagnosticRecord(
            id: UUID(), occurredAt: Date(), method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "", statusCode: http?.statusCode,
            elapsedMilliseconds: Int(elapsed * 1_000), error: error?.localizedDescription,
            responseHeaders: headers, responseBody: body
        ))
        records = Array(records.suffix(20))
    }

    func recent() -> [NetworkDiagnosticRecord] { Array(records.suffix(10)) }

    /// 返回最近一次学校网页请求的安全外链；URL 移除用户信息、query 和 fragment，
    /// ticket、token 等一次性认证参数留在诊断记录中。网页入口限定为学校网页请求。
    func latestSchoolServicePageURL() -> URL? {
        let schoolHosts = Set([
            "sso.bit.edu.cn",
            "webvpn.bit.edu.cn",
            "jxzxehall.bit.edu.cn",
            "jxzxehallapp.bit.edu.cn"
        ])

        for record in records.reversed() {
            let bodyIndicatesFailure = record.responseBody?.localizedCaseInsensitiveContains("error") == true
                || record.responseBody?.localizedCaseInsensitiveContains("certificate") == true
            let failed = record.error != nil || (record.statusCode ?? 200) >= 400 || bodyIndicatesFailure
            guard failed else { continue }
            guard let url = URL(string: record.url),
                  let host = url.host?.lowercased(),
                  schoolHosts.contains(host)
            else { continue }

            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.user = nil
            components?.password = nil
            components?.query = nil
            components?.fragment = nil
            if let pageURL = components?.url {
                return HTTPSURLUpgrade.upgradedURL(from: pageURL)
            }
        }
        return nil
    }
}
