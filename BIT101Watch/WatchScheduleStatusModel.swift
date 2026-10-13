import ScheduleContracts
import ScheduleSharedStore
import SwiftUI
import Combine

enum WatchScheduleRefreshState: Equatable {
    case idle
    case syncing
    case waiting
    case succeeded
    case failed
    case clearFailed

    var buttonTitle: String {
        self == .syncing ? "同步中…" : "重新同步"
    }

    var feedbackText: String? {
        switch self {
        case .succeeded:
            return "已同步"
        case .waiting:
            return "等待手机同步"
        case .failed:
            return "同步未完成"
        case .clearFailed:
            return "清理失败，请重试"
        case .idle, .syncing:
            return nil
        }
    }
}

/// 状态模型通过依赖闭包接入系统单例和时间来源，便于使用纯内存依赖测试。
@MainActor
struct WatchScheduleStatusDependencies {
    var now: @MainActor () -> Date
    var loadResolvedSnapshot: @MainActor (Date, Int) async -> ScheduleExternalResolvedSnapshot
    var clearSnapshot: @MainActor () async -> Bool
    var activateSync: @MainActor () -> Void
    var requestLatestSnapshot: @MainActor (
        @escaping @MainActor (Result<WatchScheduleSyncOutcome, WatchScheduleSyncError>) -> Void
    ) -> Void
    var waitForRefreshTimeout: @MainActor () async -> Void = {
        try? await Task.sleep(for: .seconds(4))
    }

#if os(watchOS)
    static let live = WatchScheduleStatusDependencies(
        now: Date.init,
        loadResolvedSnapshot: { now, limit in
            await ScheduleOccurrenceResolver.loadResolvedSnapshotAsync(store: PlatformScheduleSnapshotStorage.store, now: now, limit: limit)
        },
        clearSnapshot: WatchScheduleSyncManager.shared.clearSnapshot,
        activateSync: WatchScheduleSyncManager.shared.activateIfNeeded,
        requestLatestSnapshot: WatchScheduleSyncManager.shared.requestLatestSnapshotFromPhone
    )
#endif
}

/// watch 主页面状态模型协调共享快照、时间推进和镜像同步。
@MainActor
final class WatchScheduleStatusModel: ObservableObject {
    private static let maxVisibleOccurrences = 50
    private static let foregroundRefreshInterval: TimeInterval = 60

    @Published private(set) var snapshot: ScheduleExternalSnapshot?
    @Published private(set) var contentState: ScheduleExternalContentState = .missing
    @Published private(set) var nextOccurrence: ScheduleExternalOccurrence?
    @Published private(set) var upcomingOccurrences: [ScheduleExternalOccurrence] = []
    @Published private(set) var refreshState: WatchScheduleRefreshState = .idle
    @Published private(set) var referenceDate: Date

    private let dependencies: WatchScheduleStatusDependencies
    private var hasActivated = false
    private var refreshFeedbackTask: Task<Void, Never>?
    private var foregroundRefreshTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var snapshotGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0

#if os(watchOS)
    convenience init() {
        self.init(dependencies: .live)
    }
#endif

    init(dependencies: WatchScheduleStatusDependencies) {
        self.dependencies = dependencies
        self.referenceDate = dependencies.now()
    }

    deinit {
        refreshFeedbackTask?.cancel()
        foregroundRefreshTask?.cancel()
        snapshotTask?.cancel()
    }

    func activate() {
        guard !hasActivated else { return }
        hasActivated = true
        dependencies.activateSync()
        reload()
        startForegroundRefresh()
        requestLatestSnapshot(reportResult: false)
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            reload()
            startForegroundRefresh()
            if hasActivated { requestLatestSnapshot(reportResult: false) }
        case .inactive, .background:
            stopForegroundRefresh()
        @unknown default:
            break
        }
    }

    @discardableResult
    func reload(now: Date? = nil) -> Task<Void, Never> {
        let now = now ?? dependencies.now()
        referenceDate = now
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        snapshotTask?.cancel()
        let load = dependencies.loadResolvedSnapshot
        let operation = Task { @MainActor [weak self] in
            let resolved = await load(now, Self.maxVisibleOccurrences)
            guard !Task.isCancelled, let self, self.snapshotGeneration == generation else { return }
            self.snapshot = resolved.snapshot
            self.contentState = resolved.contentState
            self.nextOccurrence = resolved.nextOccurrence
            self.upcomingOccurrences = resolved.upcomingOccurrences
            self.snapshotTask = nil
        }
        snapshotTask = operation
        return operation
    }

    func requestRefresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshFeedbackTask?.cancel()
        refreshState = .syncing
        let waitForTimeout = dependencies.waitForRefreshTimeout
        refreshFeedbackTask = Task { @MainActor [weak self] in
            await waitForTimeout()
            guard !Task.isCancelled, let self, self.refreshGeneration == generation, self.refreshState == .syncing else { return }
            self.refreshState = .waiting
        }
        requestLatestSnapshot(reportResult: true)
        reload()
    }

    func handleSnapshotDidChange() {
        reload()
        guard acceptsRefreshResult else { return }
        finishRefresh(as: .succeeded)
    }

    @discardableResult
    func clearLocalData() -> Task<Void, Never> {
        snapshotGeneration &+= 1
        snapshotTask?.cancel()
        snapshotTask = nil
        refreshGeneration &+= 1
        refreshFeedbackTask?.cancel()
        refreshState = .idle
        referenceDate = dependencies.now()
        let generation = snapshotGeneration
        let clear = dependencies.clearSnapshot
        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let cleared = await clear()
            guard let self, !Task.isCancelled, self.snapshotGeneration == generation else { return }
            self.snapshotTask = nil
            guard cleared else {
                self.reload()
                self.refreshState = .clearFailed
                return
            }
            self.snapshot = nil
            self.contentState = .missing
            self.nextOccurrence = nil
            self.upcomingOccurrences = []
        }
        snapshotTask = task
        return task
    }

    var refreshButtonTitle: String { refreshState.buttonTitle }
    var refreshFeedbackText: String? { refreshState.feedbackText }
    var isRefreshing: Bool { refreshState == .syncing }
    private var acceptsRefreshResult: Bool { refreshState == .syncing || refreshState == .waiting }

    private func requestLatestSnapshot(reportResult: Bool) {
        let generation = refreshGeneration
        dependencies.requestLatestSnapshot { [weak self] result in
            guard reportResult, let self, self.refreshGeneration == generation, self.acceptsRefreshResult else { return }
            switch result {
            case .success(.received):
                self.reload()
                self.finishRefresh(as: .succeeded)
            case .success(.requested):
                self.reload()
            case .failure:
                self.finishRefresh(as: .failed)
            }
        }
    }

    private func finishRefresh(as state: WatchScheduleRefreshState) {
        let generation = refreshGeneration
        refreshFeedbackTask?.cancel()
        refreshState = state
        refreshFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self, self.refreshGeneration == generation else { return }
            self.refreshState = .idle
        }
    }

    private func startForegroundRefresh() {
        guard foregroundRefreshTask == nil else { return }
        foregroundRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.foregroundRefreshInterval))
                guard !Task.isCancelled, let self else { return }
                self.reload()
            }
        }
    }

    private func stopForegroundRefresh() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        snapshotGeneration &+= 1
        snapshotTask?.cancel()
        snapshotTask = nil
    }
}
